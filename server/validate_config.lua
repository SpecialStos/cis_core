-- =============================================================================
--  cis_core -- boot-time configuration validator  (SERVER SIDE ONLY)
--
--  WHAT THIS IS FOR
--
--  A config file is the one piece of this platform an operator writes by hand,
--  and a typo in it has no symptom. `Config.Framework.Typ = 'QBCORE'` is not an
--  error; it is a key nothing reads and a framework that was never selected.
--  `Config.Framework.Inventory = 'ox_inventoryr'` is not an error; it is an
--  inventory that is silently not the one you think it is. `CallbackTimeout =
--  100` is not an error; it is every callback on a busy server timing out and a
--  support thread about it three weeks later.
--
--  Every one of those is the same failure -- a wrong value that looks like a
--  right one -- and every one of them is caught here, at boot, in one block,
--  with the fix printed next to it. The roadmap's own number for this is ~70%
--  of the cost base, and this file is the largest single thing in cis_core that
--  pays for itself.
--
--  THE RULES THIS FILE FOLLOWS
--
--    1. IT NEVER RAISES. Every path is checked for type before it is read, and
--       a config value that is the wrong type is reported rather than indexed.
--       The alternative is the worst version of this feature: a validator that
--       crashes on the malformed config it exists to explain.
--
--    2. IT NEVER BLOCKS A BOOT. A broken config is a report, not a refusal. The
--       resource is a platform service; refusing to serve it turns a typo into
--       an outage, and the operator learns about the typo from the outage rather
--       than from the sentence that would have told them.
--
--    3. EVERY PROBLEM CARRIES ITS FIX. A diagnostic without a fix is a riddle,
--       and the fix is the only part the operator can act on.
--
--    4. IT IS PURE. No globals are read, no natives are called, no exports are
--       touched. That is what makes it testable under fengari with no FiveM
--       server, which is the only place a test like this can run on every push.
-- =============================================================================

CisConfig = {}

-- The values this resource actually branches on, named once. A value that is
-- not in one of these sets is not "unusual", it is a different code path: every
-- branch below the read falls through to its last `else`, which on this
-- resource is standalone mode or the framework's own item table. Both look
-- like working software, which is the entire problem.
local FRAMEWORK_TYPES = {
    AUTO = true, ESX = true, ['ESX-LEGACY'] = true,
    QBCORE = true, QBOX = true, NONE = true,
}

local INVENTORY_TYPES = {
    ['ox_inventory'] = true, ['qb-inventory'] = true, ['qs-inventory'] = true,
    ['codem-inventory'] = true, typical = true,
}

local TARGET_TYPES = { ox_target = true, ['qb-target'] = true }

local DATABASE_TYPES = {
    AUTO = true, oxmysql = true, ['mysql-connector'] = true,
    ghmattimysql = true, mongodb = true,
}

local AIMING_TYPES = { default = true, configFlag = true }

-- The keys each table is allowed to carry. Used for the unknown-key check,
-- which is the one that catches a typo: a key nothing reads is invisible
-- without one, because Lua accepts the assignment and says nothing.
local KNOWN_KEYS = {
    [''] = {
        'CheckVersion', 'VersionCheckUrl', 'CallbackTimeout', 'UpdateInterval',
        'AimingCheckType', 'Framework', 'Sync', 'Printing',
    },
    ['UpdateInterval'] = { 'Player', 'Weapon', 'Vehicle', 'VehicleProperties' },
    ['Framework'] = { 'Type', 'Inventory', 'Zones', 'Target', 'Database', 'Custom' },
    ['Framework.Zones'] = { 'Enabled' },
    ['Framework.Target'] = { 'Enabled', 'Type', 'Debug' },
    ['Framework.Database'] = { 'Type', 'Collection', 'Timeout' },
    ['Sync'] = { 'Enabled' },
    ['Printing'] = { 'Debug', 'UseDiscordLogs' },
}

local KNOWN_SECURITY_KEYS = {
    EventPrefix = true, Debug = true, AuthorizedResources = true, DropPlayer = true,
}

-- ------------------------------------------------------------------- plumbing

local function add(bucket, code, path, message, fix)
    bucket[#bucket + 1] = {
        code = code,
        path = path,
        message = message,
        fix = fix,
    }
end

local function typeName(v)
    return type(v)
end

-- Levenshtein, bounded. Only ever used to suggest a key that was probably
-- meant, and only over short identifiers, so the cost is irrelevant and the
-- benefit is a fix line that names the right key instead of saying "unknown".
local function editDistance(a, b)
    local la, lb = #a, #b
    if math.abs(la - lb) > 3 then
        return 99
    end
    local prev, cur = {}, {}
    for j = 0, lb do
        prev[j] = j
    end
    for i = 1, la do
        cur[0] = i
        for j = 1, lb do
            local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            local best = prev[j - 1] + 1
            if prev[j] + 1 < best then best = prev[j] + 1 end
            if cur[j - 1] + 1 < best then best = cur[j - 1] + 1 end
            if prev[j - 1] + cost < best then best = prev[j - 1] + cost end
            cur[j] = best
        end
        prev, cur = cur, prev
    end
    return prev[lb]
end

-- The closest key by case-insensitive match first, then by edit distance. The
-- distance threshold scales with the length so a short key is not matched to an
-- unrelated long one; without that, `Debug` "matches" `AimingCheckType` and the
-- suggestion is worse than no suggestion.
local function suggestKey(name, candidates)
    if type(name) ~= 'string' then
        return nil
    end
    local lower = name:lower()
    for _, c in ipairs(candidates) do
        if c:lower() == lower then
            return c
        end
    end
    local best, bestScore
    for _, c in ipairs(candidates) do
        local d = editDistance(lower, c:lower())
        local limit = math.max(2, math.floor(#c / 4) + 1)
        if d <= limit and (not bestScore or d < bestScore) then
            best, bestScore = c, d
        end
    end
    return best
end

local function describe(value)
    local t = type(value)
    if t == 'string' then
        return ('%q'):format(value)
    end
    if t == 'number' or t == 'boolean' then
        return tostring(value)
    end
    return t
end

-- One key's rules. `root` is the whole table and `path` is dotted, so a schema
-- entry is a single line and adding a key to this file is the only edit a new
-- setting needs.
--
-- `severity` is deliberate and not uniform:
--
--   error    -- the value is one this resource does not accept. It will be
--               ignored and the documented fallback will run instead.
--   warning  -- the value is accepted, and it will do something the operator
--               probably did not intend.
--   info     -- correct, but worth knowing at boot.
local function check(report, root, rootName, path, spec)
    local full = (rootName == '' ) and path or (rootName .. '.' .. path)
    local sev = spec.severity or 'error'
    local value, found = nil, false
    local brokenPath, brokenValue

    if path == '' then
        value, found = root, true
    else
        -- The walk has to distinguish "the key is absent" from "something on the
        -- way to it is not a table", and the difference is the whole check.
        --
        -- Treated as absent, `Config.Framework.Target = 'ox_target'` validates
        -- clean: the walk cannot descend into a string, gives up, and the
        -- absence of `Target.Enabled` below it is indistinguishable from an
        -- operator who never wrote one. So a correct config and a broken one
        -- produced the same report -- and the broken one is precisely the case
        -- this file exists to catch.
        local parts = {}
        for part in path:gmatch('[^%.]+') do
            parts[#parts + 1] = part
        end
        local node = root
        for i, part in ipairs(parts) do
            if type(node) ~= 'table' then
                -- nil on the way down is ABSENCE, not breakage: an operator
                -- who never wrote `Config.Framework` is not the same mistake as
                -- one who wrote `Config.Framework = 'QBOX'`. Only a value that
                -- exists and is not a table blocks the walk.
                if node ~= nil then
                    brokenPath = table.concat(parts, '.', 1, i - 1)
                    brokenValue = node
                end
                break
            end
            node = node[part]
        end
        if not brokenPath then
            value, found = node, node ~= nil
        end
    end

    if brokenPath then
        local where = (rootName == '') and brokenPath or (rootName .. '.' .. brokenPath)
        add(report[sev], 'CFG_TYPE', where,
            ('is %s, and %s cannot be read through it'):format(typeName(brokenValue), full),
            ('%s has to be a table for %s to exist -- a value here is read as a table and silently ignored')
                :format(where, full))
        return
    end

    if not found then
        -- Absent is not a problem. Every key here has a default, and the whole
        -- point of shipping a config with defaults is that a partial one works.
        return
    end

    local bucket = report[sev]

    if spec.type and type(value) ~= spec.type then
        add(bucket, 'CFG_TYPE', full,
            ('is %s, and this key must be %s'):format(typeName(value), spec.type),
            ('set %s = %s'):format(full, spec.example or describe(spec.type == 'number' and 0 or spec.type == 'boolean' and true or 'string')))
        return
    end

    if spec.oneof then
        if not spec.oneof[value] then
            local near = nil
            if type(value) == 'string' then
                near = suggestKey(value, spec.names)
            end
            local fix
            if near then
                fix = ('%s is %s, which this resource does not accept; did you mean %s?'):format(
                    full, describe(value), ('%s.%s'):format(rootName, near))
            else
                fix = ('%s must be one of: %s'):format(full, table.concat(spec.names, ', '))
            end
            add(bucket, 'CFG_VALUE', full, ('is %s, which is not a value this resource accepts'):format(describe(value)), fix)
        end
        return
    end

    if spec.min or spec.max then
        if (spec.min and value < spec.min) or (spec.max and value > spec.max) then
            local bounds = {}
            if spec.min then bounds[#bounds + 1] = ('at least %s'):format(spec.min) end
            if spec.max then bounds[#bounds + 1] = ('at most %s'):format(spec.max) end
            local isTime = full:find('Timeout') ~= nil or full:find('Interval') ~= nil
            local why = spec.why
            if isTime and not why then
                why = 'a value outside this range turns a real answer into a missing one'
            end
            add(bucket, 'CFG_RANGE', full, ('is %s, and the accepted range is %s'):format(describe(value), table.concat(bounds, ' and ')),
                why or ('set %s to a value in that range'):format(full))
            return
        end
    end

    if spec.check then
        local ok, message, fix = spec.check(value)
        if not ok then
            add(bucket, spec.code or 'CFG_CUSTOM', full, message, fix)
        end
    end
end

-- Key order out of a set-like table, so a suggestion is deterministic rather
-- than whatever the hash iteration happened to produce this boot. A diagnostic
-- that names a different "did you mean" on two boots of the same config is a
-- diagnostic nobody trusts.
--
-- Declared HERE, above its callers, and not below them: a local declared after
-- a function that references it is not in scope when that function is
-- compiled, so the reference silently becomes a GLOBAL. It would have worked on
-- every boot that happened to have a global of that name and returned nil on
-- every boot that did not.
local function vim_keys(set)
    local out = {}
    for k in pairs(set) do
        out[#out + 1] = k
    end
    table.sort(out)
    return out
end

-- Every dotted path this resource reads, derived from KNOWN_KEYS so it cannot
-- drift from them. Used only to turn "unknown key" into "this key, here".
--
-- Declared above its caller for the same reason as everything else here: a
-- local declared after a function that references it resolves to a GLOBAL.
local function suggestPath(key)
    local best, bestScore
    for prefix, names in pairs(KNOWN_KEYS) do
        for _, name in ipairs(names) do
            local path = prefix == '' and name or (prefix .. '.' .. name)
            local leaf = path:match('([^%.]+)$')
            if leaf:lower() == key:lower() then
                return path
            end
            local d = editDistance(key:lower(), leaf:lower())
            local limit = math.max(2, math.floor(#leaf / 4) + 1)
            if d <= limit and (not bestScore or d < bestScore) then
                best, bestScore = path, d
            end
        end
    end
    return best
end

-- Keys nothing reads. The one check here with a genuinely useful fix, because
-- "unknown key" and "typo" are the same event and an operator who typos a key
-- has no other way to find out.
local function unknownKeys(report, table_, label, allowed)
    if type(table_) ~= 'table' or not allowed then
        return
    end
    -- `allowed` is a LIST, and the test below is a hash lookup. Indexing an
    -- array by string key answers nil for every key, which made this function
    -- report every legitimate key as unknown -- 20 warnings on a correct
    -- install, none of them actionable, and the whole report learned to be
    -- noise. The set is built here rather than stored as a set so the table
    -- above reads the way the key list does.
    local known = {}
    for _, name in ipairs(allowed) do
        known[name] = true
    end

    for key in pairs(table_) do
        if type(key) == 'string' and not known[key] then
            -- Suggested across the WHOLE config, not just this table. An
            -- operator who wrote `Config.Zones` is not one edit from
            -- `Config.Framework.Zones` -- they are one table away, and a
            -- suggestion that only searched the table they were in would have
            -- to fall back to "remove it", which is not the fix.
            local where = suggestPath(key)
            local fix
            if where then
                fix = ('this key lives at Config.%s -- did you mean that?'):format(where)
            else
                local near = suggestKey(key, allowed)
                if near then
                    fix = ('did you mean Config.%s.%s?'):format(label:gsub('^Config%.?', ''), near)
                else
                    fix = ('remove it, or move it to the resource that reads it -- %s is not read by cis_core')
                        :format(('%s.%s'):format(label, key))
                end
            end
            add(report.warning, 'CFG_UNKNOWN', ('%s.%s'):format(label, key),
                'is not a key this resource reads, so it is ignored',
                fix)
        end
    end
end


-- ---------------------------------------------------------------- the checks

-- Every value below is read by name somewhere in this resource. That is the
-- test for inclusion: a key nobody reads does not get validated, because a
-- validator over keys nobody reads is documentation pretending to be a check.
local function validateConfig(config, report)
    if type(config) ~= 'table' then
        add(report.error, 'CFG_ROOT', 'Config',
            ('is %s, and every setting in it is read by name'):format(typeName(config)),
            'make sure configs/master_config.lua is loaded before anything that reads Config')
        return
    end

    check(report, config, 'Config', 'CheckVersion', {
        type = 'boolean',
        severity = 'warning',
    })
    check(report, config, 'Config', 'VersionCheckUrl', { type = 'string' })
    check(report, config, 'Config', 'CallbackTimeout', {
        type = 'number', min = 500, max = 120000,
        why = 'below 500ms a slow client or a heavy framework turns every callback into a timeout, '
            .. 'and a nil that means "too early" is indistinguishable from a nil that means "no such thing"',
    })
    check(report, config, 'Config', 'AimingCheckType', {
        type = 'string', oneof = AIMING_TYPES,
        names = { 'default', 'configFlag' },
    })

    check(report, config, 'Config', 'UpdateInterval.Player', { type = 'number', min = 100, max = 60000 })
    check(report, config, 'Config', 'UpdateInterval.Weapon', { type = 'number', min = 100, max = 60000 })
    check(report, config, 'Config', 'UpdateInterval.Vehicle', { type = 'number', min = 100, max = 60000 })
    check(report, config, 'Config', 'UpdateInterval.VehicleProperties', { type = 'number', min = 100, max = 60000 })

    check(report, config, 'Config', 'Framework.Type', {
        type = 'string', oneof = FRAMEWORK_TYPES,
        names = { 'AUTO', 'ESX', 'ESX-LEGACY', 'QBCORE', 'QBOX', 'NONE' },
    })
    check(report, config, 'Config', 'Framework.Inventory', {
        type = 'string', oneof = INVENTORY_TYPES,
        names = { 'ox_inventory', 'qb-inventory', 'qs-inventory', 'codem-inventory', 'typical' },
    })
    check(report, config, 'Config', 'Framework.Zones.Enabled', { type = 'boolean' })
    check(report, config, 'Config', 'Framework.Target.Enabled', { type = 'boolean' })
    check(report, config, 'Config', 'Framework.Target.Type', {
        type = 'string', oneof = TARGET_TYPES,
        names = { 'ox_target', 'qb-target' },
    })
    check(report, config, 'Config', 'Framework.Target.Debug', {
        type = 'boolean', severity = 'warning',
    })
    check(report, config, 'Config', 'Framework.Database.Type', {
        type = 'string', oneof = DATABASE_TYPES,
        names = { 'AUTO', 'oxmysql', 'mysql-connector', 'ghmattimysql', 'mongodb' },
    })
    check(report, config, 'Config', 'Framework.Database.Collection', { type = 'string' })
    check(report, config, 'Config', 'Framework.Database.Timeout', {
        type = 'number', min = 1000, max = 120000,
        why = 'below 1000ms a busy server reports a slow query as a missing one, and raising it only makes a '
            .. 'stalled query hang for longer',
    })

    check(report, config, 'Config', 'Sync.Enabled', { type = 'boolean' })
    check(report, config, 'Config', 'Printing.Debug', { type = 'boolean', severity = 'warning' })
    check(report, config, 'Config', 'Printing.UseDiscordLogs', { type = 'boolean', severity = 'warning' })

    -- A custom adapter that names no resource is a custom adapter that cannot
    -- be reached. This is checked rather than documented because the failure
    -- is silent: detection falls back to the known frameworks, and the
    -- operator's framework is simply not on the list.
    if type(config.Framework) == 'table' and config.Framework.Custom ~= nil then
        local custom = config.Framework.Custom
        if type(custom) ~= 'table' then
            add(report.error, 'CFG_TYPE', 'Config.Framework.Custom',
                ('is %s, and a custom adapter must be a table'):format(typeName(custom)),
                'see DOCUMENTATION.md 2.5 for the shape')
        elseif type(custom.resource) ~= 'string' or custom.resource == '' then
            add(report.error, 'CFG_CUSTOM', 'Config.Framework.Custom.resource',
                'is missing, and detection has no way to reach a framework it was not told the name of',
                'set Config.Framework.Custom.resource = \'my_framework\'')
        end
    end

    unknownKeys(report, config, 'Config', KNOWN_KEYS[''])
    unknownKeys(report, config.UpdateInterval, 'Config.UpdateInterval', KNOWN_KEYS['UpdateInterval'])
    unknownKeys(report, config.Framework, 'Config.Framework', KNOWN_KEYS['Framework'])
    unknownKeys(report, type(config.Framework) == 'table' and config.Framework.Zones or nil,
        'Config.Framework.Zones', KNOWN_KEYS['Framework.Zones'])
    unknownKeys(report, type(config.Framework) == 'table' and config.Framework.Target or nil,
        'Config.Framework.Target', KNOWN_KEYS['Framework.Target'])
    unknownKeys(report, type(config.Framework) == 'table' and config.Framework.Database or nil,
        'Config.Framework.Database', KNOWN_KEYS['Framework.Database'])
    unknownKeys(report, config.Sync, 'Config.Sync', KNOWN_KEYS['Sync'])
    unknownKeys(report, config.Printing, 'Config.Printing', KNOWN_KEYS['Printing'])
end

local function validateSecurity(security, report)
    if type(security) ~= 'table' then
        add(report.error, 'CFG_ROOT', 'Security',
            ('is %s, and the authorised-resource list lives in it'):format(typeName(security)),
            'make sure configs/security_config.lua is loaded before the boot thread runs')
        return
    end

    check(report, security, 'Security', 'EventPrefix', { type = 'string' })
    check(report, security, 'Security', 'Debug', { type = 'boolean', severity = 'warning' })

    -- The prefix is compiled into cis_libs's own files as a fallback. Changing
    -- it here moves every event name and nothing else moves with it, and the
    -- failure is silence: a consumer's trigger is not refused, it simply never
    -- arrives. So it is reported every boot it is not the default.
    local prefix = security.EventPrefix
    if type(prefix) == 'string' and prefix ~= 'cis_libs' then
        add(report.warning, 'CFG_PREFIX', 'Security.EventPrefix',
            ('is %q, and cis_libs publishes its events under "cis_libs"'):format(prefix),
            'every event name moves with it, and any companion resource that triggers those names directly '
                .. 'must change in the same edit; the trigger is not refused, it just never arrives')
    end

    local list = security.AuthorizedResources
    if list == nil then
        add(report.warning, 'CFG_AUTH_MISSING', 'Security.AuthorizedResources',
            'is not set, which this resource reads as an empty list',
            'an empty list means NOBODY: every mutating call from another resource is refused, with the fix '
                .. 'printed. List the resources you own if you have any.')
    elseif type(list) ~= 'table' then
        add(report.error, 'CFG_TYPE', 'Security.AuthorizedResources',
            ('is %s, and it must be a table of resource names'):format(typeName(list)),
            'write Security.AuthorizedResources = { \'cis_keys\' }')
    else
        local seen = {}
        for i = 1, #list do
            local entry = list[i]
            if type(entry) ~= 'string' or entry == '' then
                add(report.error, 'CFG_AUTH_ENTRY', ('Security.AuthorizedResources[%d]'):format(i),
                    ('is %s, and every entry must be a resource name'):format(describe(entry)),
                    'use the folder name of the resource on disk, for example \'cis_keys\'')
            elseif seen[entry] then
                add(report.info, 'CFG_AUTH_DUPLICATE', ('Security.AuthorizedResources[%d]'):format(i),
                    ('is %q, which is already in the list'):format(entry),
                    'harmless, but remove the duplicate')
                seen[entry] = nil
            else
                seen[entry] = true
            end
        end
        for key in pairs(list) do
            if type(key) ~= 'number' or key < 1 or key > #list or key % 1 ~= 0 then
                add(report.warning, 'CFG_AUTH_SHAPE', 'Security.AuthorizedResources',
                    ('has the key %s, which is not a list index'):format(describe(key)),
                    'write it as an array literal -- { \'cis_keys\', \'cis_housing\' } -- so every entry is read')
            end
        end
    end

    -- DropPlayer is a boolean OR a function. A function cannot be sent across
    -- the exports boundary, so it arrives as nil and the platform uses its own
    -- handler; that is why server/initialize.lua registers the capability as
    -- well. What is worth reporting is the two values that mean something
    -- different from what an operator expects.
    local drop = security.DropPlayer
    if drop ~= nil and type(drop) ~= 'boolean' and type(drop) ~= 'function' then
        add(report.error, 'CFG_TYPE', 'Security.DropPlayer',
            ('is %s, and must be true, false, or a function(src, reason)'):format(typeName(drop)),
            'use false to log only, true to drop with the shipped message, or assign your own function')
    end

    for key in pairs(security) do
        if type(key) == 'string' and not KNOWN_SECURITY_KEYS[key] then
            local near = suggestKey(key, vim_keys(KNOWN_SECURITY_KEYS))
            add(report.warning, 'CFG_UNKNOWN', ('Security.%s'):format(key),
                'is not a key this resource reads, so it is ignored',
                near and ('did you mean Security.%s?'):format(near)
                    or 'remove it, or move it to the resource that reads it')
        end
    end
end

local function validateDiscord(discord, report)
    if discord == nil then
        return
    end
    if type(discord) ~= 'table' then
        add(report.error, 'CFG_ROOT', 'DiscordConfig',
            ('is %s, and every webhook lives in it'):format(typeName(discord)),
            'make sure configs/discordLogs_config.lua is loaded before the boot thread runs')
        return
    end

    -- The one that matters. Enabling logging before pasting real webhooks is
    -- refused downstream by a CHANGE-ME check, which is safe but SILENT -- the
    -- operator turns logging on, sees nothing, and files a ticket. Saying so at
    -- boot costs one line and answers it before the ticket exists.
    if type(discord.DiscordLogsLinks) == 'table' then
        local links = discord.DiscordLogsLinks
        local placeholders = 0
        local total = 0
        for _, name in ipairs({ 'MasterLogs', 'CheatingLogs', 'ErrorLogs' }) do
            local url = links[name]
            if type(url) == 'string' and url ~= '' then
                total = total + 1
                if url:find('CHANGE-ME', 1, true) then
                    placeholders = placeholders + 1
                end
            end
        end
        if total > 0 and placeholders == total then
            add(report.info, 'CFG_DISCORD_PLACEHOLDER', 'DiscordConfig.DiscordLogsLinks',
                ('still holds the CHANGE-ME placeholder on all %d channels, and the queue refuses it'):format(total),
                'nothing will be sent until you paste a real webhook URL; if you turned UseDiscordLogs on and see '
                    .. 'no messages, this is why')
        elseif placeholders > 0 then
            add(report.info, 'CFG_DISCORD_PARTIAL', 'DiscordConfig.DiscordLogsLinks',
                ('has %d of %d channels still on the placeholder'):format(placeholders, total),
                'only the channels with a real URL will receive anything')
        end
    end
end

-- ------------------------------------------------------------------- the call

--- Validate every table this resource reads at boot.
---
--- @param config    table|nil  the `Config` global from configs/master_config.lua
--- @param security  table|nil  the `Security` global from configs/security_config.lua
--- @param discord   table|nil  the `DiscordConfig` global, optional
--- @return boolean ok, table report
---
--- `ok` is false when there is at least one ERROR. It does not mean "do not
--- boot" -- see rule 2. It means "an operator is going to file a ticket about
--- this", and the report is what they should be handed.
function CisConfig.validate(config, security, discord)
    local report = { error = {}, warning = {}, info = {} }

    -- The whole body is wrapped. A validator that raises on a malformed config
    -- is the one failure this file exists to prevent, so the guard is not
    -- paranoia about a hypothetical -- it is the feature. A raise here is
    -- reported as an error rather than swallowed, because it means this file has
    -- a bug, and silence about that is how the next one ships.
    local ok, raised = pcall(function()
        validateConfig(config, report)
        validateSecurity(security, report)
        validateDiscord(discord, report)
    end)
    if not ok then
        add(report.error, 'CFG_VALIDATOR', 'cis_core',
            ('the configuration validator itself raised: %s'):format(tostring(raised)),
            'this is a bug in cis_core, not in your config -- please report it')
    end

    report.counts = {
        errors = #report.error,
        warnings = #report.warning,
        info = #report.info,
    }
    return report.counts.errors == 0, report
end

--- The one-line summary a console print wants.
function CisConfig.summary(report)
    local c = report.counts
    if c.errors == 0 and c.warnings == 0 then
        return ('configuration OK (%d note%s)'):format(c.info, c.info == 1 and '' or 's')
    end
    local parts = {}
    if c.errors > 0 then
        parts[#parts + 1] = ('%d error%s'):format(c.errors, c.errors == 1 and '' or 's')
    end
    if c.warnings > 0 then
        parts[#parts + 1] = ('%d warning%s'):format(c.warnings, c.warnings == 1 and '' or 's')
    end
    if c.info > 0 then
        parts[#parts + 1] = ('%d note%s'):format(c.info, c.info == 1 and '' or 's')
    end
    return ('configuration: %s'):format(table.concat(parts, ', '))
end

return CisConfig