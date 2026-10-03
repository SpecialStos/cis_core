-- =============================================================================
--  cis_core -- the operator-facing half: boot report, console commands
--
--  WHAT THIS IS FOR
--
--  Support is ~70% of this company's cost base, and the roadmap's own estimate
--  puts a single avoidable ticket class -- "the install is wrong and nothing
--  said so" -- at roughly EUR 83,000 over 24 months. A support thread costs an
--  operator their evening and us a slot; a boot line costs nothing.
--
--  So: everything this resource can detect about a broken install, it says out
--  loud at boot, in one block, with the fix attached. `cis_core_doctor` is the
--  same report on demand, for the operator who joined a server that is already
--  running and has no boot log.
--
--  THE TWO RULES THAT SHAPE THIS FILE
--
--    1. NO SECRETS, EVER. Not a webhook URL, not a connection string, not an
--       identifier, not a config value. Names, booleans, counts and reasons
--       only. A diagnostic command that dumps config puts every secret on an
--       operator's screen and into their client log, and a support thread that
--       quotes one has leaked it.
--
--    2. EVERY LINE THAT SAYS SOMETHING IS WRONG ALSO SAYS THE FIX. A report
--       that only says "no database provider" has moved the problem; one that
--       says "start oxmysql, or set Config.Framework.Database.Type" has ended
--       it.
-- =============================================================================

CisDoctor = {}

-- One report line. `state` is what an operator needs to see, `fix` is what
-- they need to do, and a line with a nil fix is not printed at all -- because
-- there is nothing to print.
--
-- The severity word is fixed by how the reader can act on it, not chosen per
-- call site, so a report reads consistently:
--
--   MISSING -- something this resource needs is not there
--   DEGRADED -- it is there but not doing what the config asked for
--   SET     -- something an operator should know about a decision they made
local function line(out, severity, subject, state, fix)
    out[#out + 1] = {
        severity = severity,
        subject = subject,
        state = state,
        fix = fix,
    }
end

-- ------------------------------------------------------------- environment

--- Everything this resource can see about the server it booted into.
---
--- Deliberately built from RESOURCE NAMES and BOOLEANS. There is no code path
--- in this function that can put a config value into the result, which is a
--- stronger guarantee than reviewing each line for it later.
function CisDoctor.environment()
    local env = {}

    -- ---------------------------------------------------------------- cis_libs
    local state = GetResourceState('cis_libs')
    if state ~= 'started' then
        line(env, 'MISSING', 'cis_libs', ('resource state is %q'):format(state),
            'add `ensure cis_libs` BEFORE `ensure cis_core` to your server.cfg -- cis_core is built on it')
    else
        -- The library's own self-check, not just its resource state. cis_libs
        -- detects problems at boot -- a missing dependency, a refused
        -- capability, a config key nothing reads -- and answers them with a fix.
        -- Reading the state alone is what makes a doctor report "everything is
        -- fine" on an install that has been refusing calls for an hour.
        local ok, self = pcall(function()
            return exports['cis_libs']:GetSelfCheck()
        end)
        if ok and type(self) == 'table' then
            if self.ok then
                line(env, 'SET', 'cis_libs', 'started, self-check clean', nil)
            end
            for _, problem in ipairs(self.problems or {}) do
                line(env, 'MISSING', 'cis_libs', ('%s: %s'):format(
                    tostring(problem.code), tostring(problem.message)),
                    problem.fix and tostring(problem.fix) or 'see `cis_doctor` in cis_libs for the library-side view')
            end
        else
            line(env, 'SET', 'cis_libs', 'started, but GetSelfCheck did not answer',
                'run `cis_debug` in the console for the library-side view')
        end
    end

    -- -------------------------------------------------------------- framework
    -- The CONFIGURED name is unreliable here, and reading it alone was a
    -- reporting bug rather than a cosmetic one: framework_server.lua REWRITES
    -- Config.Framework.Type to what it actually detected, and it does that from
    -- a thread. So a report that read the config could print "AUTO" on one boot
    -- and "QBOX" on the next with nothing having changed, and an operator
    -- comparing two reports would conclude the framework is unstable.
    --
    -- The detection result is read directly instead, and falls back to the
    -- config only when detection has not finished. That is the honest ordering:
    -- the answer, and then the guess.
    local detected = CisFramework and CisFramework.detected
    local configured = Config and Config.Framework and Config.Framework.Type or 'unknown'

    local caps = {}
    local okCaps, result = pcall(function()
        return exports['cis_libs']:GetCapabilities()
    end)
    if okCaps and type(result) == 'table' then
        caps = result
    end

    local owner = caps.framework
    owner = type(owner) == 'table' and owner.owner or owner
    local name = (type(detected) == 'table' and detected.name) or configured
    local how = (type(detected) == 'table') and 'detected' or 'configured'

    if name == 'NONE' then
        line(env, 'SET', 'framework', ('NONE (standalone, %s)'):format(how),
            'player lookups return a table with no name and no job, and every money and item helper returns its '
                .. 'no-framework answer -- that is a mode, not a failure, but nothing that reads a job will work')
    elseif owner == nil then
        line(env, 'DEGRADED', 'framework', ('no provider registered; the config says %q'):format(tostring(configured)),
            'the framework this config names is not started, so every player lookup returns nil -- start it, '
                .. 'or set Config.Framework.Type = "AUTO" to detect what IS running')
    else
        line(env, 'SET', 'framework', ('%s (%s, capability held by %s)'):format(
            tostring(name), how, tostring(owner)),
            (type(detected) == 'table' and detected.name ~= configured)
                and ('the config says %q but detection found %q; detection won, and the config was rewritten to match')
                    :format(tostring(configured), tostring(detected.name))
                or nil)
    end

    -- -------------------------------------------------------------- inventory
    local invName = Config and Config.Framework and Config.Framework.Inventory or 'typical'
    if invName == 'typical' then
        line(env, 'SET', 'inventory', "typical (the framework's own item table)", nil)
    elseif GetResourceState(invName) == 'started' then
        line(env, 'SET', 'inventory', ('%s is started'):format(invName), nil)
    else
        line(env, 'DEGRADED', 'inventory', ('%s is configured but not started'):format(invName),
            ('start %s, or set Config.Framework.Inventory = "typical" -- counts will fall back to the framework\'s '
                .. 'own table, which on a stock framework is usually empty, so "HasItem always says no"'):format(invName))
    end

    -- ------------------------------------------------------------------ slots
    -- A slot nothing holds is not necessarily a fault -- cis_bridge is optional
    -- and a standalone server wants neither a target nor a database. It is
    -- reported because "which optional pieces are installed" is the first
    -- question of every support thread and there is otherwise no way to answer
    -- it without six console commands.
    for _, slot in ipairs({ 'database', 'target', 'inventory', 'framework', 'doorsClient', 'discord' }) do
        local owner = caps[slot]
        owner = type(owner) == 'table' and owner.owner or owner
        if owner then
            line(env, 'SET', ('slot %s'):format(slot), ('held by %s'):format(tostring(owner)), nil)
        else
            line(env, 'SET', ('slot %s'):format(slot), 'empty',
                ('nothing has registered %s -- that is expected on a standalone install; it only matters if a '
                    .. 'resource you installed needs it (cis_bridge provides database, target and inventory adapters)')
                    :format(slot))
        end
    end

    -- -------------------------------------------------- the allow-list
    -- An authorised resource that is not installed grants nothing today. It is
    -- reported anyway, and the reason is the residual risk stated in
    -- configs/security_config.lua: the grant is attached to a NAME, so a stale
    -- entry becomes live the day a different resource is installed under that
    -- name. That is not a hypothetical on a server where the operator renames
    -- things while moving between frameworks, and "I did not know that name was
    -- still on the list" is not an answer anyone can give after the fact.
    --
    -- The inverse is reported too, and it is the one that actually breaks
    -- something: a resource the operator INSTALLED that is missing from the
    -- list. Its mutating calls are being refused right now.
    local authorised = type(Security) == 'table' and Security.AuthorizedResources or nil
    if type(authorised) == 'table' then
        local started, missing = {}, {}
        for _, name in ipairs(authorised) do
            if type(name) == 'string' then
                if GetResourceState(name) == 'started' then
                    started[#started + 1] = name
                else
                    missing[#missing + 1] = name
                end
            end
        end
        if #authorised == 0 then
            line(env, 'DEGRADED', 'allow-list', 'empty -- NOBODY is authorised',
                'every mutating call from another resource is refused, with the fix printed -- that is the '
                    .. 'intended meaning of an empty list, not a bug; add the resources you own')
        else
            table.sort(started)
            line(env, 'SET', 'allow-list', ('%d authorised, %d started'):format(#authorised, #started),
                started[1] and ('running: %s'):format(table.concat(started, ', ')) or nil)
            if #missing > 0 then
                table.sort(missing)
                line(env, 'SET', 'allow-list', ('%d authorised but not installed'):format(#missing),
                    ('%s -- nothing is granted today, but a grant is attached to a NAME: delete the entries you '
                        .. 'do not have so a different resource installed later cannot inherit them')
                        :format(table.concat(missing, ', ')))
            end
        end
    end

    -- ------------------------------------------------------------ migrations
    local applied = CisMigrationsApplied or {}
    local count = 0
    for _ in pairs(applied) do
        count = count + 1
    end
    line(env, 'SET', 'migrations', ('%d recorded as applied'):format(count),
        count == 0 and 'no product has called exports["cis_core"]:Migrate() yet -- that is expected until you install one'
            or nil)

    ------------------------------------------------------- event authority
    -- Zero on a healthy server, ever. Anything above zero means a client sent
    -- an event naming a source that was not its own -- which is the signature
    -- of a cheat menu, and something an operator should never have to ask the
    -- meaning of.
    local spoofed = CisAuthority and CisAuthority.spoofed or 0
    local anonymous = CisAuthority and CisAuthority.anonymous or 0
    if spoofed == 0 then
        line(env, 'SET', 'event authority',
            ('clean -- no client named a source that was not its own%s'):format(
                anonymous > 0 and (' (%d client-sent event(s) carried no source, which is answered with the '
                    .. 'sender and is not a forgery)'):format(anonymous) or ''),
            nil)
    else
        -- NOT `MISSING`. That severity means "something this resource needs is
        -- not there", and a refused forgery is a detected ATTACK -- the one
        -- state in this report that is not an install fault. It borrows the
        -- wrong word and reads as a missing dependency.
        line(env, 'DEGRADED', 'event authority',
            ('%d forged event source(s) refused'):format(spoofed),
            [[a client sent an event naming somebody else's source. Each one was refused and the network
            source was used instead. Nothing was granted, but it is worth knowing which resource or cheat
            produced it -- the console line printed on the first one names the event]])
    end

    ----------------------------------------------------------- the state store
    -- Called as a MODULE function, not through `exports['cis_core']`. Asking a
    -- resource for one of its own exports is the self trap documented in
    -- server/migrations.lua, and `GetInvokingResource()` inside that call is
    -- not a thing worth depending on. The pcall is still there: on a server with
    -- no driver this answers `available = false` with a reason, and on a server
    -- where the store never started it must not take the whole doctor with it.
    local okState, state = pcall(function()
        return CisState.summary()
    end)
    if not okState or type(state) ~= 'table' then
        line(env, 'SET', 'state store', 'did not answer',
            'run `cis_core_doctor` again; if it persists, cis_core is not fully started')
    elseif state.available then
        local n = #state.namespaces
        local detail = 'no product has written state yet'
        if n > 0 then
            local parts = {}
            for _, ns in ipairs(state.namespaces) do
                parts[#parts + 1] = ('%s (%d)'):format(ns.owner, ns.keys)
            end
            detail = table.concat(parts, ', ')
        end
        line(env, 'SET', 'state store', ('available, %d namespace(s)'):format(n), detail)
    else
        line(env, 'DEGRADED', 'state store', 'unavailable',
            tostring(state.reason) .. ' -- every state export answers false until it is fixed')
    end

    return env
end

-- ------------------------------------------------------------------- render

--- Print a report. Console only -- the caller has already checked who it is.
function CisDoctor.printReport(title, lines)
    print(('='):rep(72))
    print(('cis_core: %s'):format(title))
    print(('='):rep(72))
    for _, l in ipairs(lines) do
        print(('  [%-8s] %-22s %s'):format(l.severity, l.subject, l.state))
        if l.fix then
            print(('  %-11s -> %s'):format('', l.fix))
        end
    end
    print(('='):rep(72))
end

--- The boot block: the environment plus every configuration problem.
---
--- Errors and warnings are printed here, at boot, where the operator is already
--- looking at the console. Notes are not -- they are correct-as-shipped and
--- printing them every boot trains people to skim past the whole block, which
--- is the one thing this block cannot afford.
function CisDoctor.bootReport()
    local ok, report = CisConfig.validate(Config, Security, DiscordConfig)

    print(('cis_core: %s'):format(CisConfig.summary(report)))

    for _, bucket in ipairs({ 'error', 'warning' }) do
        for _, p in ipairs(report[bucket]) do
            print(('  %s %s %s'):format(bucket:upper(), p.path, p.message))
            print(('    fix: %s'):format(p.fix))
        end
    end

    -- Not a hard stop, ever. A platform service that refuses to serve because
    -- one optional piece is missing turns a config typo into an outage, and the
    -- operator learns the cause from the outage instead of from the line above
    -- that just told them. The one thing that IS fatal -- cis_libs missing --
    -- is reported by environment() and the boot thread above already returned.
    if not ok then
        print('  cis_core: carrying on anyway. Every setting above falls back to its documented default.')
    end

    return report
end

-- ------------------------------------------------------------------ exports

--- The same report as data, for a support thread and for `cis_libs` to show
--- next to its own diagnostics.
---
--- The shape is deliberately flat and printable: a table of strings and
--- booleans, no nesting a human has to walk. When someone pastes this into
--- Discord it has to be readable.
exports('GetDoctorReport', function()
    local lines = CisDoctor.environment()
    local ok, report = CisConfig.validate(Config, Security, DiscordConfig)
    return {
        version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0),
        environment = lines,
        config = {
            ok = ok,
            errors = report.error,
            warnings = report.warning,
            info = report.info,
        },
    }
end)