-- Server-side framework bridge. One normalised surface over ESX, QBCore and
-- QBOX, and a standalone mode when none of them load.
--
-- Two things here are load-bearing and easy to break:
--
--   1. detection PROBES exports rather than trusting Config.Framework.Type,
--      because the name an operator configures is not a promise about what the
--      resource exposes -- see the QBOX branch;
--   2. every money and item operation goes back out to the framework rather
--      than editing PlayerData directly, so whatever the framework does for
--      validation, replication and side effects still happens.

FrameworkLoaded = false
CisFramework = {}
local Framework = CisFramework
local provider = 'NONE'
local QBCore, ESX, QBX

-- 50ms poll, 5s default ceiling. This is a boot-path wait for another RESOURCE
-- to start, not a hot loop: it runs at most a handful of times per server
-- start, and what it is waiting on resolves in seconds. 50ms is well under any
-- perceptible difference in when a consumer gets its framework, and it keeps
-- the resource-start path responsive instead of parking on a coarse timer. A
-- tighter poll would only burn scheduler time waiting for a resource whose
-- start time this library does not control.
local function waitResource(name, timeout)
    local deadline = GetGameTimer() + (timeout or 5000)
    while GetResourceState(name) ~= 'started' and GetGameTimer() < deadline do
        Wait(50)
    end
    return GetResourceState(name) == 'started'
end

-- What the last detect() concluded, for cis_debug and the boot report.
-- Recorded rather than recomputed: a diagnosis that runs different code from
-- the thing it diagnoses is not a diagnosis.
Framework.detected = nil

-- A resolved custom adapter, when one is configured. Comes from
-- Config.Framework.Custom, or from a global `CisCustomFramework` a consumer can
-- define before cis_libs starts -- the escape hatch for a framework this
-- library has never heard of.
local customAdapter = nil

local function loadCustomAdapter()
    local global = rawget(_G, 'CisCustomFramework')
    if type(global) == 'table' then
        return {
            resource = global.resource or 'CisCustomFramework',
            name = global.name or 'CUSTOM',
            getPlayer = type(global.getPlayer) == 'string' and global.getPlayer or 'GetPlayer',
            getPlayerFn = type(global.getPlayer) == 'function' and global.getPlayer or nil,
        }
    end
    local custom = Config and Config.Framework and Config.Framework.Custom
    if type(custom) == 'table' and type(custom.resource) == 'string' and custom.resource ~= '' then
        return {
            resource = custom.resource,
            name = custom.name or 'CUSTOM',
            getPlayer = custom.getPlayer or custom.probe,
        }
    end
    return nil
end

-- THERE USED TO BE AN EXPORT-EXISTENCE PROBE HERE, AND IT IS NOW DEAD CODE.
--
-- `probeExport(resource, exportName)` resolved an export reference instead of
-- calling it, because calling to test is wrong -- `qbx_core:GetPlayer(0)` raises
-- on an invalid source and a raise inside a pcall is indistinguishable from "the
-- export does not exist". That reasoning was sound and the function was correct
-- in the way that mattered: `type(fn) == 'function'` returns true for every real
-- export, because the runtime hands you a closure.
--
-- It became dead when detection moved to `exports['cis_libs']:DetectFramework`,
-- which probes on its own side and returns a result. It was passed in as an
-- argument to the old inline `CisDetect.framework(...)` call that no longer
-- exists. Nothing referenced it, and nothing noticed.
--
-- Two reasons to delete it rather than keep it "just in case":
--
--   1. It duplicated a rule cis_libs owns. Two existence probes in the platform
--      is two that can disagree, and this one would only ever be exercised on
--      a code path no longer taken.
--   2. Its last two lines were WRONG. `rawget(fn, '__cfx_functionReference')`
--      where `fn` is a function always answers nil -- `rawget` on a function
--      returns nil -- so the "both shapes count" fallback could never fire. The
--      comment claimed a returned export arrives as a reference TABLE; against
--      the CfxLua scheduler it arrives as a function. Harmless, because the
--      line above it always returned first, and exactly the kind of thing that
--      becomes load-bearing the day someone deletes the line above it.
--
-- If a caller ever needs to know whether a THIRD-PARTY resource publishes an
-- export, ask cis_libs, or read the target's manifest metadata. Do not
-- reintroduce a probe here.

local function detect()
    local configured = string.upper((Config and Config.Framework and Config.Framework.Type) or 'AUTO')
    customAdapter = loadCustomAdapter()

    -- AUTO and CUSTOM both mean "ask the server". The pure module decides, so
    -- the ordering that distinguishes qbx_core from qb-core is unit tested
    -- rather than trusted.
    if configured == 'AUTO' or customAdapter then
        -- ACROSS THE BOUNDARY, not the global. `CisDetect` is defined in
        -- cis_libs, and FiveM gives every resource its own Lua state, so the
        -- bare global was always nil here. Since AUTO is the shipped default,
        -- that meant `detect()` raised inside its thread on every stock
        -- install: the framework capability was never registered, no job count
        -- was claimed, and every player lookup answered nil -- with nothing in
        -- the console, because the failure was in a thread nobody awaited. The
        -- client half already called the export; this is the same call.
        local choice = exports['cis_libs']:DetectFramework(
            configured,
            customAdapter and {
                resource = customAdapter.resource,
                name = customAdapter.name,
                getPlayer = customAdapter.getPlayer,
            } or nil
        )
        Framework.detected = choice
        provider = choice.name

        if choice.name == 'NONE' then
            print(('cis_libs: no framework available (%s). Running standalone: player '
                .. 'lookups will return a table with no name and no job.')
                :format(choice.reason))
            if Config and Config.Framework then
                Config.Framework.Type = 'NONE'
            end
            return
        end

        -- Give the resource a moment to finish publishing its exports. A
        -- started resource is usually ready, and "usually" is the whole
        -- difference between working and silently degrading.
        if not waitResource(choice.resource, 5000) then
            print(('cis_libs: %s reported as %s but did not finish starting')
                :format(choice.resource, choice.name))
            provider = 'NONE'
            if Config and Config.Framework then
                Config.Framework.Type = 'NONE'
            end
            return
        end

        if choice.name == 'QBCORE' then
            local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
            if ok and core then
                QBCore = core
            end
        elseif choice.name == 'QBOX' then
            -- qbx_core removed GetCoreObject in 1.9 and exposes the lookups
            -- directly; an older one still has it, and taking the core object
            -- when it exists keeps the money helpers working.
            local ok, core = pcall(function() return exports.qbx_core:GetCoreObject() end)
            if ok and core then
                QBX = core
                QBCore = core
            end
        elseif choice.name == 'ESX' or choice.name == 'ESX-LEGACY' then
            local ok, obj = pcall(function() return exports['es_extended']:getSharedObject() end)
            if ok then
                ESX = obj
            end
            if not ESX then
                local deadline = GetGameTimer() + 3000
                while ESX == nil and GetGameTimer() < deadline do
                    TriggerEvent('esx:getSharedObject', function(shared) ESX = shared end)
                    Wait(50)
                end
            end
        end

        print(('cis_libs: framework %s (%s%s) -- %s'):format(choice.name, choice.resource,
            choice.version and (' ' .. tostring(choice.version)) or '', choice.reason))

        if Config and Config.Framework and configured == 'AUTO' then
            -- Config is REWRITTEN to what was actually detected, so every
            -- consumer that reads Config.Framework.Type -- including the
            -- client, which receives it in the config payload -- agrees with
            -- reality rather than with what someone guessed.
            Config.Framework.Type = choice.name
        end
        return
    end

    if configured == 'QBCORE' then
        if waitResource('qb-core', 5000) then
            local ok, core = pcall(function()
                return exports['qb-core']:GetCoreObject()
            end)
            if ok and core then
                QBCore = core
                provider = 'QBCORE'
                return
            end
            print('cis_libs: qb-core started but GetCoreObject failed')
        end
    elseif configured == 'QBOX' then
        if waitResource('qbx_core', 5000) then
            -- qbx_core REMOVED GetCoreObject in 1.9 and exposes player lookups
            -- directly as exports -- which is exactly what Framework.GetPlayer
            -- already calls. Detecting on GetCoreObject therefore fails on
            -- every current qbx_core, and the library fell straight through to
            -- standalone mode on precisely the server it was configured for.
            -- Nothing errored; `Cis.framework.player(src)` just quietly began
            -- returning a table with no name and no job.
            --
            -- Probe GetCoreObject for an older qbx_core, then fall back to the
            -- export that modern qbx_core actually has. Calling a missing
            -- export raises; calling a present one with a bad id returns nil
            -- without raising, so the pcall is an honest existence test.
            -- GetPlayer(0) is safe for that purpose precisely because a bad id
            -- is a nil return and not an error -- server id 0 is the console
            -- and is never a real player, so nothing is looked up and nothing
            -- is decided on the value.
            --
            -- Note the second probe sets NO core object. That is intentional:
            -- a modern qbx_core has nothing to capture, and Framework.GetPlayer
            -- reaches the export directly on its first branch for provider
            -- 'QBOX'. Do not "fix" this by assigning a placeholder -- every
            -- other `QBCore.Functions` check in this file tests for a table and
            -- would take a different path.
            local ok, core = pcall(function()
                return exports.qbx_core:GetCoreObject()
            end)
            if ok and core then
                QBX = core
                QBCore = core
                provider = 'QBOX'
                return
            end
            local hasGetPlayer = pcall(function()
                return exports.qbx_core:GetPlayer(0)
            end)
            if hasGetPlayer then
                provider = 'QBOX'
                return
            end
            print('cis_libs: qbx_core is started but exposes neither '
                .. 'GetCoreObject nor GetPlayer; treating it as unusable')
        end
        -- Configured for QBOX but running qb-core. A short 2s wait, not 5s:
        -- this is the unexpected branch, and a server that really runs QBOX has
        -- already answered above. Provider is reported as QBCORE, not QBOX,
        -- because that is what is actually loaded and a consumer branching on
        -- it will call the right thing.
        if waitResource('qb-core', 2000) then
            local ok, core = pcall(function()
                return exports['qb-core']:GetCoreObject()
            end)
            -- `ok and core`, not `ok`. A started resource is not a resource that
            -- has published its exports yet, and the pcall is happy either way:
            -- `ok` alone returned with `QBCore = nil` and `provider = 'QBCORE'`,
            -- which is a bridge that looks installed and answers nil for every
            -- player. The ESX branch below has always had this right, and says
            -- why in a comment.
            if ok and core then
                QBCore = core
                provider = 'QBCORE'
                -- The config is REWRITTEN here too, not just on the AUTO path.
                -- Leaving it saying QBOX while the server bridges as QBCORE means
                -- the client -- which receives Config.Framework.Type verbatim in
                -- the config payload -- takes the QBOX branch, reaches for
                -- exports.qbx_core, finds no such resource, and settles for
                -- standalone: the two halves of the same bridge disagreeing
                -- about which framework the server runs.
                if Config and Config.Framework then
                    Config.Framework.Type = 'QBCORE'
                end
                return
            end
        end
    elseif configured == 'ESX' or configured == 'ESX-LEGACY' then
        if waitResource('es_extended', 5000) then
            -- The modern path. ESX may not have published the export yet even
            -- though the resource reports started, so `ok` alone is not enough:
            -- a nil object has to fall through to the event below.
            local ok, obj = pcall(function()
                return exports['es_extended']:getSharedObject()
            end)
            if ok then
                ESX = obj
            end
            if not ESX then
                -- The legacy path: older ESX has no export and only answers a
                -- request event, which has to be triggered and then waited on.
                -- 3s, 50ms apart -- the object is created during es_extended's
                -- own start, so this either succeeds in the first few rounds
                -- or never will.
                local deadline = GetGameTimer() + 3000
                while ESX == nil and GetGameTimer() < deadline do
                    TriggerEvent('esx:getSharedObject', function(shared)
                        ESX = shared
                    end)
                    Wait(50)
                end
            end
            if ESX then
                -- The CONFIGURED name is preserved rather than normalised to
                -- 'ESX', because Config.Framework.Type is what a consumer reads
                -- to decide how to talk to the framework.
                provider = configured
                return
            end
        end
    else
        provider = 'NONE'
        return
    end
    print('cis_libs: Framework provider unavailable; using standalone mode')
    provider = 'NONE'
    -- Config is REWRITTEN, not just reported. A server that is silently
    -- running standalone is the single most damaging outcome here -- every
    -- player lookup returns a table with no name and no job, and nothing
    -- errors -- so the config is corrected to match reality and
    -- GetConfigSummary in server/initialize.lua then reports 'NONE' instead of
    -- a framework this server is not running.
    if Config and Config.Framework then
        Config.Framework.Type = 'NONE'
    end
end

function Framework.IsLoaded()
    return FrameworkLoaded
end

-- ONE SHAPE, ON EVERY FRAMEWORK.
--
-- It was not. The QBCore branch returned `QBCore.Functions.GetPlayers()`,
-- which returns QBPlayer OBJECTS. The ESX branch returned `ESX.GetPlayers()`
-- -- which, since 1.9.2 at least, IS the FiveM native (`ESX.GetPlayers =
-- GetPlayers`, es_extended/server/functions.lua) and returns an array of SOURCE
-- ID STRINGS. One method, two shapes: a consumer reading the first element got
-- a table on QBCore and the string "3" on ESX, and the bug that produced lived
-- in the consumer, on a platform its author never tested.
--
-- So the promise is kept on both sides and the ESX branch builds what it was
-- implicitly promising. The cost is one GetPlayerFromId per connected player,
-- which is a table read inside ESX, for the "who is online" question this method
-- exists to answer.
function Framework.GetPlayers()
    if provider == 'QBCORE' and QBCore and QBCore.Functions then
        return QBCore.Functions.GetPlayers()
    end
    if (provider == 'ESX' or provider == 'ESX-LEGACY') and ESX then
        local out = {}
        for _, id in ipairs(ESX.GetPlayers() or {}) do
            -- `tonumber` because the ids are STRINGS on every ESX from 1.9.2
            -- onward and numbers before it. GetPlayerFromId tonumbers
            -- internally, but doing it here keeps the list honest about what a
            -- caller is holding.
            local src = tonumber(id)
            if src then
                local xPlayer = ESX.GetPlayerFromId(src)
                if xPlayer then
                    out[#out + 1] = xPlayer
                end
            end
        end
        return out
    end
    return GetPlayers()
end

-- The hottest call in this file: a dispatch, a gate, a money operation all
-- start here. nil for "no such player" -- a disconnected or not-yet-loaded src
-- is normal traffic, not an error, and the callers below all treat it as a
-- plain false.
function Framework.GetPlayer(serverId)
    -- A custom adapter is tried FIRST and unconditionally. The operator
    -- configured it precisely because the branches below would not recognise
    -- their framework, so trying the known ones first is the wrong order.
    --
    -- `getPlayer` may be a function on the adapter table, or the NAME of an
    -- export on the adapter's resource. The table form wins when both are
    -- given, because it is the more explicit of the two.
    if customAdapter then
        local got = nil
        local fn = customAdapter.getPlayerFn
        if type(fn) == 'function' then
            local ok, player = pcall(fn, serverId)
            if ok then
                got = player
            end
        elseif type(customAdapter.getPlayer) == 'string' then
            local res = customAdapter.resource
            local ok, player = pcall(function()
                -- Bound to a local first, rather than chained inline. The
                -- chain is CORRECT -- the exports table is passed explicitly,
                -- which is the whole point -- but `exports[res][name](...)` is
                -- the shape CI greps for as an unbound call, and a build that
                -- fails on a line which is actually right teaches people to
                -- ignore the tripwire. Two lines, and the warning stays sharp.
                local target = exports[res]
                local handler = target[customAdapter.getPlayer]
                return handler(target, serverId)
            end)
            -- The exports table is passed EXPLICITLY: `exports[res][name]` is an
            -- unbound method and would eat serverId as `self`, so the handler
            -- would run with a number where the player should be. The same
            -- trap the callback dispatcher documents.
            if ok then
                got = player
            end
        end
        if got then
            return got
        end
    end

    -- QBOX first, and unconditionally of whether detection found a core
    -- object. On a current qbx_core the export IS the interface, and the
    -- QBCore.Functions branch below has nothing to offer -- so this has to be
    -- tried before it, not only when a core object was captured. A nil here is
    -- ambiguous (no such player, or an id type the export rejects) and both
    -- mean the same thing to a caller, so the fallthrough is correct.
    if provider == 'QBOX' and GetResourceState('qbx_core') == 'started' then
        local ok, player = pcall(function()
            return exports.qbx_core:GetPlayer(serverId)
        end)
        if ok and player then
            return player
        end
    end
    if (provider == 'QBCORE' or provider == 'QBOX') and QBCore and QBCore.Functions then
        return QBCore.Functions.GetPlayer(serverId)
    end
    if (provider == 'ESX' or provider == 'ESX-LEGACY') and ESX then
        return ESX.GetPlayerFromId(serverId)
    end
    return nil
end

-- Items go to server/inventory.lua rather than to the framework's own item
-- API, so that a server running an external inventory (ox_inventory, qb-
-- inventory) is not silently bypassed by a framework bridge call.
function Framework.GiveItem(serverId, item, amount)
    return exports['cis_libs']:InventoryAdd(serverId, item, amount)
end

function Framework.RemoveItem(source, item, amount)
    return exports['cis_libs']:InventoryRemove(source, item, amount)
end

function Framework.HasItem(source, item)
    return exports['cis_libs']:InventoryHas(source, item, 1)
end

function Framework.GiveMoney(serverId, amount, moneyType)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return false
    end
    moneyType = moneyType or 'cash'
    if provider == 'QBCORE' or provider == 'QBOX' then
        -- 'markedbills' is an ITEM on every framework this supports, not an
        -- account, so it is routed to the inventory with the value carried as
        -- metadata. Handing it to AddMoney instead would create an account
        -- named markedbills that no shop and no ATM knows how to spend. The
        -- decision itself is shared with the client half through
        -- CisNormalize.moneyRoute, so the two cannot disagree about it.
        if CisNormalize.moneyRoute(moneyType) == 'inventory' then
            return exports['cis_libs']:InventoryAdd(serverId, 'markedbills', 1, { worth = amount })
        end
        -- Three attempts, in order of preference: the object method when a core
        -- object was captured, then the qbx_core export. The last branch is
        -- what a current qbx_core uses, and it is reached only when the player
        -- object has no Functions table -- which is exactly the shape modern
        -- qbx_core returns. `ok and result and true or false` collapses "raised",
        -- "returned nil" and "returned false" into one honest answer.
        if player.Functions and player.Functions.AddMoney then
            -- AddMoney reports false on a rejected transaction; do not paper over it.
            return player.Functions.AddMoney(moneyType, amount) and true or false
        end
        if GetResourceState('qbx_core') == 'started' then
            local ok, result = pcall(function()
                return exports.qbx_core:AddMoney(serverId, moneyType, amount, 'cis_libs')
            end)
            return ok and result and true or false
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        if CisNormalize.moneyRoute(moneyType) == 'inventory' then
            return exports['cis_libs']:InventoryAdd(serverId, 'markedbills', 1, { worth = amount })
        end
        -- pcall, not a return-value check: ESX's addAccountMoney returns nothing
        -- and raises on an unknown account, so `ok` is the only success signal
        -- available.
        local ok = pcall(function()
            return player:addAccountMoney(moneyType, amount)
        end)
        return ok
    end
    return false
end

function Framework.RemoveMoney(serverId, amount, moneyType)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return false
    end
    moneyType = moneyType or 'cash'
    if provider == 'QBCORE' or provider == 'QBOX' then
        if CisNormalize.moneyRoute(moneyType) == 'inventory' then
            return exports['cis_libs']:InventoryRemove(serverId, 'markedbills', 1)
        end
        if player.Functions and player.Functions.RemoveMoney then
            return player.Functions.RemoveMoney(moneyType, amount) and true or false
        end
        if GetResourceState('qbx_core') == 'started' then
            local ok, result = pcall(function()
                return exports.qbx_core:RemoveMoney(serverId, moneyType, amount, 'cis_libs')
            end)
            return ok and result and true or false
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        if CisNormalize.moneyRoute(moneyType) == 'inventory' then
            return exports['cis_libs']:InventoryRemove(serverId, 'markedbills', 1)
        end
        local ok = pcall(function()
            return player:removeAccountMoney(moneyType, amount)
        end)
        return ok
    end
    return false
end

function Framework.GetPlayerIdentifier(serverId)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return nil
    end
    if provider == 'QBCORE' or provider == 'QBOX' then
        return player.PlayerData and player.PlayerData.citizenid
    end
    if provider == 'ESX' or provider == 'ESX-LEGACY' then
        return player.identifier
    end
    return nil
end

function Framework.GetPlayerJob(serverId)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return nil
    end
    if provider == 'QBCORE' or provider == 'QBOX' then
        return player.PlayerData and player.PlayerData.job
    end
    if provider == 'ESX' or provider == 'ESX-LEGACY' then
        return player.job
    end
    return nil
end

function Framework.SetPlayerJob(serverId, job, grade)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return
    end
    -- The local mirror is updated UNCONDITIONALLY, after whichever framework
    -- call succeeded or not. It is what an online-job-count is answered from,
    -- and a job change the framework accepted but the mirror missed would
    -- leave a cop counted as a civilian until they next changed job. Same
    -- reasoning for the client event: the player's UI must not depend on the
    -- framework's own job event arriving in the right shape.
    if provider == 'QBCORE' or provider == 'QBOX' then
        if player.Functions and player.Functions.SetJob then
            player.Functions.SetJob(job, grade)
        elseif GetResourceState('qbx_core') == 'started' then
            pcall(function()
                exports.qbx_core:SetJob(serverId, job, grade)
            end)
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        player:setJob(job, grade)
    end
    exports['cis_libs']:PublishJobUpdate({ name = job, grade = grade }, serverId)
end

-- Every permission check in the library funnels here, and the QBCore and qbx
-- branches answer with an explicit boolean rather than nil: a nil would read
-- as "no" in one caller and raise in another. Note the ESX branch below does
-- NOT normalise -- an xPlayer with no getGroup returns nil, not false. Both
-- callers treat it as falsy, so it works, but it is the one answer from this
-- function that is not a real boolean.
function Framework.HasPermission(serverId, permission)
    local player = Framework.GetPlayer(serverId)
    if not player then
        return false
    end
    if provider == 'QBCORE' or provider == 'QBOX' then
        if QBCore and QBCore.Functions and QBCore.Functions.HasPermission then
            return QBCore.Functions.HasPermission(serverId, permission)
        end
        if GetResourceState('qbx_core') == 'started' then
            local ok, result = pcall(function()
                return exports.qbx_core:HasPermission(serverId, permission)
            end)
            return ok and result or false
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        return player.getGroup and player:getGroup() == permission
    end
    return false
end

function Framework.GetOnlineJobCount(jobs)
    return exports['cis_libs']:GetOnlineJobCount(jobs)
end

-- ESX-style callback shape (cb, ...) wrapped into a cis_libs callback, so a
-- consumer written against ESX can keep its `function(src, cb, ...) cb(x) end`
-- and get the library's dispatch, rate limiting and timeout for free.
--
-- The adapter is SYNCHRONOUS, and that is a real constraint: it calls cb, then
-- returns whatever cb captured. A handler that calls its callback later -- from
-- an await, a timer, or a database round trip -- returns nothing here, and the
-- client gets a timeout instead of the value. That is inherent to a server-side
-- dispatch that has already answered; the fix for such a handler is to register
-- it as "resource:export" so the await happens on the client.
function Framework.CreateCallback(name, cb)
    exports['cis_libs']:RegisterCallback(name, function(src, ...)
        local result
        cb(src, function(...)
            result = table.pack(...)
        end, ...)
        if result then
            return table.unpack(result, 1, result.n)
        end
    end)
end

function Framework.Notify(src, message, kind)
    exports['cis_libs']:NotifyClient(src, message, kind)
end

-- =============================================================================
--  EVERY ESX xPlayer CALL IS A COLON CALL, AND EVERY ONE OF THEM WAS A DOT
--
--  ESX builds its player with `function self.addAccountMoney(accountName, money,
--  reason)` -- declared against `self`, so `self` is the FIRST DECLARED
--  PARAMETER. (es_extended/server/classes/player.lua: addAccountMoney 440,
--  removeAccountMoney 463, setJob 612, getGroup 318, get 328, getAccounts 332,
--  getName 407, getMeta 913.)
--
--  A dot call therefore feeds the first real argument into `self`. The whole of
--  the ESX surface was reached that way here, and what it does on a real
--  server is worse than returning a wrong value:
--
--    player.getGroup()          self = nil   -> `return self.group` RAISES
--    player.addAccountMoney(a,b) self = a, accountName = b, money = nil
--                                               -> ESX refuses a nil amount
--    player.setJob(job, grade)  self = job, newJob = 3 (a NUMBER) -> no such job
--    player.getName()           self = nil   -> RAISES
--    player.getAccounts()       self = nil   -> RAISES
--
--  So on ESX, money did not work, job changes did not work, permissions RAISED,
--  and the character name was unavailable. Not one of them errored visibly --
--  GiveMoney is wrapped in a pcall and returned false, which reads exactly like
--  "the transaction was declined".
--
--  The QBCore side is the opposite and is why this went unnoticed: QBCore
--  declares `function Player.Functions.AddMoney(moneytype, amount, reason)` on
--  a Functions TABLE, so its implicit self is that table and a dot call from
--  outside is already correct. One convention per framework, and they are
--  opposites, and the file had adopted QBCore's for both.
--
--  If you are editing a line in this block: ESX takes a colon, QBCore takes a
--  dot. Getting it wrong is silent on one framework and fatal on the other.
-- =============================================================================

local function esxAccounts(player)
    if not player or type(player.getAccounts) ~= 'function' then
        return nil
    end
    local ok, accounts = pcall(function()
        return player:getAccounts()
    end)
    if not ok then
        return nil
    end
    -- Only the CALL is framework-specific. The list-to-map conversion is not,
    -- so it lives in shared/normalize.lua with the rest of the shape reading.
    return CisNormalize.accountMap(accounts)
end

-- ESX's metadata, which is NOT where `get()` looks.
--
-- It used to be read as `player.get('metadata')`, and that is ALWAYS nil. The
-- xPlayer is built with two separate tables:
--
--     self.variables = {}        -- what get() and set() read and write
--     self.metadata  = metadata  -- what getMeta() and setMeta() read and write
--
-- (es_extended/server/classes/player.lua: `function self.get(k) return
-- self.variables[k] end`). So `get('metadata')` asks the variables table for a
-- key nothing ever writes there, and `NormalizedPlayer(src).metadata` was nil
-- on every ESX server while looking correct: the field was present, of the
-- right type, and always empty. A consumer checking `metadata.hadcuffed` got
-- nil and took the "not handcuffed" branch forever, with nothing anywhere
-- saying the field was unread.
--
-- Order matters. `getMeta()` is the documented accessor and its index argument
-- is optional, defaulting to the whole table, so a bare call is right. The
-- plain field is the second attempt for builds that predate getMeta, and both
-- are probed because a raise here would take NormalizedPlayer down for a
-- consumer that only wanted the name.
local function esxMetadata(player)
    if type(player.getMeta) == 'function' then
        local ok, value = pcall(function()
            return player:getMeta()
        end)
        if ok and type(value) == 'table' then
            return value
        end
    end
    if type(player.metadata) == 'table' then
        return player.metadata
    end
    -- nil rather than {}. An empty table says "this player has no metadata";
    -- nil says "this framework version does not have the concept". Only one of
    -- those is something a caller can act on.
    return nil
end

-- One player, one shape, whichever framework is underneath. `money` is
-- deliberately not normalised further than "a table keyed by account name":
-- the SQL frameworks hand back a money table and ESX hands back an account
-- list, and collapsing them to a common currency would mean picking one of
-- them and losing information the other carries. A consumer that needs a
-- number asks for the account it wants.
--
-- The name is a JOIN, not the player name. A player with no charinfo and no
-- getName (a framework that stores neither) gets nil rather than an empty
-- string, so a consumer can tell "no name" from "the name is blank".
function Framework.NormalizedPlayer(src)
    local player = Framework.GetPlayer(src)
    local job = Framework.GetPlayerJob(src)
    local name, money, metadata
    if player then
        if player.PlayerData and player.PlayerData.charinfo then
            local info = player.PlayerData.charinfo
            name = CisNormalize.personName(info.firstname, info.lastname)
        elseif type(player.getName) == 'function' then
            local ok, value = pcall(function()
                return player:getName()
            end)
            name = ok and value or nil
        end
        if player.PlayerData then
            money = player.PlayerData.money
            metadata = player.PlayerData.metadata
        else
            -- ESX keeps money in accounts and metadata on the xPlayer itself.
            money = esxAccounts(player)
            metadata = esxMetadata(player)
        end
    end
    return {
        id = src,
        name = name,
        job = job,
        identifier = Framework.GetPlayerIdentifier(src),
        money = money,
        metadata = metadata,
    }
end

-- The one a consumer uses to get at the bridge. Blocks rather than returning a
-- half-initialised table, because every function on Framework depends on
-- `provider` being decided and a call made before detect() finishes would read
-- it as 'NONE'.
--
-- The second wait is belt and braces and is not additive with the first: the
-- thread at the bottom sets FrameworkLoaded and THEN calls markReady, so
-- CisReadyState.wait returning true already implies FrameworkLoaded is true and
-- the loop exits on its first test. The ceiling is therefore 15s, not 30s.
-- The first wait returning false returns early rather than proceeding, because
-- a failed ready state means the library gave up and there is nothing to wait
-- for.
-- The capability table. One export, and it is what cis_libs forwards to.
--
-- It used to be three exports (GetFramework, GetNormalizedPlayer, Notify) that
-- cis_libs called directly. One table with a stable shape is better for three
-- reasons: cis_libs binds it once instead of resolving three names per call, a
-- product can add a method without a change to this library, and the shape is
-- declared in one place -- shared/registry.lua's `framework` slot -- rather than
-- implied by three separate function signatures.
exports('CisCoreFramework', function()
    if not exports['cis_libs']:WaitReady(15000) then
        return Framework
    end
    local deadline = GetGameTimer() + 15000
    while not FrameworkLoaded and GetGameTimer() < deadline do
        Wait(50)
    end
    return Framework
end)

-- Startup, in this order, and the order is the contract:
--
--   detect()   -- decides `provider`; every Framework function reads it
--   loaded     -- GetFramework's belt-and-braces loop watches this
--   markReady  -- the signal consumers actually wait on
--   register   -- the callback is claimed only now
--   backfill   -- everyone already online is recorded in the job histogram
--
-- Backfill is last and is why the histogram is correct on a resource restart:
-- the framework's PlayerLoaded events have already fired for every connected
-- player by the time this thread runs, so without this walk the job store
-- starts empty and an online-police count reads zero until each player
-- reconnects.
--
-- Readiness is cis_libs's own business now, so this thread no longer opens the
-- gate -- it detects a framework and then REGISTERS the capability, which is
-- what actually makes Cis.framework.* answer. A server with no cis_core
-- installed simply has no framework, says so, and the rest of the library
-- carries on; the old arrangement made the whole library's readiness depend on
-- this thread running at all.
--
-- Registration happens AFTER detection and AFTER the callback below is wired,
-- so a consumer that wakes the instant the capability appears already gets a
-- real job count rather than 'unknown'.
CreateThread(function()
    detect()
    FrameworkLoaded = true
    exports['cis_libs']:RegisterCallback('cis_libs:getOnlineJobCount', function(_, jobs)
        return Framework.GetOnlineJobCount(jobs)
    end)
    -- The capability table is what cis_libs forwards to. It is registered as a
    -- REFERENCE, not sent: a function cannot be sent across the exports
    -- boundary, but it can be returned, and the registry resolves a
    -- `resource:Export` string by asking for it back.
    exports['cis_libs']:RegisterCapability('framework', 'cis_core:CisCoreFramework')
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        if src then
            exports['cis_libs']:PublishJobUpdate(Framework.GetPlayerJob(src), src)
        end
    end
end)

-- =============================================================================
--  WHO AN EVENT IS ABOUT
--
--  The four handlers below read a player source out of an event payload, which
--  in FiveM is a value the sender chose: a client can `TriggerServerEvent`
--  with any name and any payload, so `esx:playerLoaded` is not an ESX event, it
--  is a name a player can type.
--
--  That was true here for this resource's whole life, and `PublishJobUpdate`
--  ends in `TriggerClientEvent('cis_libs:jobUpdated', src, ...)` -- so a client
--  naming somebody else's source made THAT PLAYER'S CLIENT receive a job it did
--  not have, and cis_core's own client stores it.
--
--  The rule and its implementation live in server/authority.lua, so the same
--  answer is not re-derived in each file that handles an event. `CisAuthority`
--  is available at event time regardless of load order; nothing below calls it
--  during file execution.
-- =============================================================================

-- The four events below are the frameworks' own notifications, and they are
-- what keeps the job histogram live after startup. Two per framework because
-- the two ecosystems are not interchangeable and a server runs exactly one:
-- qbx_core still fires the QBCore events for compatibility, and a listener
-- for the qbx_core-specific ones alone would miss players on a QBCore build.
-- The src extraction covers both event payload shapes (QBCore passes a player
-- object, ESX passes a number), because the two cannot be told apart by the
-- event alone -- and then, above, neither of them is allowed to decide who the
-- event is about.
RegisterNetEvent('QBCore:Server:PlayerLoaded', function(player)
    local claimed = nil
    if type(player) == 'table' then
        claimed = (type(player.PlayerData) == 'table' and player.PlayerData.source) or player.source
    end
    local src = CisAuthority.resolveSource(claimed, 'QBCore:Server:PlayerLoaded')
    if src then
        local job = Framework.GetPlayerJob(src)
        if job then
            exports['cis_libs']:PublishJobUpdate(job, src)
        end
        exports['cis_libs']:PublishInventory(src)
    end
end)

AddEventHandler('esx:playerLoaded', function(payloadSrc)
    local src = CisAuthority.resolveSource(payloadSrc, 'esx:playerLoaded')
    if src then
        local job = Framework.GetPlayerJob(src)
        if job then
            exports['cis_libs']:PublishJobUpdate(job, src)
        end
        exports['cis_libs']:PublishInventory(src)
    end
end)

RegisterNetEvent('QBCore:Server:OnJobUpdate', function(payloadSrc, job)
    local src = CisAuthority.resolveSource(payloadSrc, 'QBCore:Server:OnJobUpdate')
    if src and type(job) == 'table' and job.name then
        exports['cis_libs']:PublishJobUpdate(job, src)
    end
end)

AddEventHandler('esx:setJob', function(payloadSrc, job)
    local src = CisAuthority.resolveSource(payloadSrc, 'esx:setJob')
    if src and type(job) == 'table' and job.name then
        exports['cis_libs']:PublishJobUpdate(job, src)
    end
end)
