-- =============================================================================
--  test/framework_env.lua -- a fake FiveM server, for ONE scenario
--
--  WHY THIS EXISTS, AND WHY IT IS NOT "TESTING THE MOCK"
--
--  DOCUMENTATION.md says the framework abstraction is deliberately not
--  unit-tested, because testing a mock proves nothing about the framework.
--  That is true of the ADAPTER and false of the DECISION, and the second test
--  written in this repository (server/authority.lua, whose stubs are the same
--  shape as these) found a shipped vulnerability. So the distinction is worth
--  being precise about:
--
--      NOT modelled here: what QBCore actually does with money, whether an
--      ESX xPlayer has getAccounts, whether qbx_core still fires a legacy
--      event. Those are facts about other people's code, and no stub can be
--      honest about them.
--
--      Modelled here, and under test: WHICH branch cis_core takes for a given
--      world, what it does with the answer, and whether the two halves of the
--      resource agree. That logic is this resource's, it is where every bug
--      found so far in this file has lived, and it is exactly what a stub can
--      be honest about.
--
--  Every stub below answers a question about the WORLD ("is qb-core started",
--  "does this export exist"), never a question about the DECISION. If you find
--  yourself tempted to add a stub that decides which branch the code should
--  take, that is the line, and the test is in the wrong place.
--
--  ONE STATE PER SCENARIO. Each scenario file is loaded into its own Lua state
--  by test/scenarios.js, so `detect()` can be re-run against a different world
--  without the previous scenario's globals surviving it.
-- =============================================================================

FrameworkEnv = {}

-- ---------------------------------------------------------------- the world

local env = {
    -- resource name -> 'started' | 'stopped' | 'missing'
    resources = {},
    -- 'resource:Export' -> function, for every export that EXISTS
    exports = {},
    -- resource name -> { version = '1.2.3' }
    metadata = {},
    -- 1-based list of connected player sources
    players = {},
    -- everything printed, captured
    printed = {},
    -- threads registered by CreateThread, run explicitly by the scenario
    threads = {},
    -- net events and handlers registered by the file under test
    netEvents = {},
    handlers = {},
    -- exports registered BY the file under test
    registered = {},
    -- the fake clock
    now = 0,
}

FrameworkEnv.env = env

local MAX_WAIT_STEPS = 2000

-- A CLOCK THAT MOVES. `waitResource` polls `GetGameTimer() < deadline` and
-- yields with `Wait(50)`, so a clock that never advances turns "resource never
-- started" into an infinite loop inside the test rather than a failed
-- assertion. Bounded by MAX_WAIT_STEPS so a genuinely stuck loop still fails
-- rather than hangs CI.
function _G.GetGameTimer()
    return env.now
end

function _G.Wait(ms)
    env.now = env.now + (tonumber(ms) or 0)
    if env.now > MAX_WAIT_STEPS * 100 then
        error('the fake clock passed its ceiling: something is polling forever', 2)
    end
end

function _G.GetResourceState(name)
    return env.resources[name] or 'missing'
end

function _G.GetResourceMetadata(name, key)
    local m = env.metadata[name]
    return m and m[key] or nil
end

function _G.GetPlayers()
    local out = {}
    for _, src in ipairs(env.players) do
        out[#out + 1] = tostring(src)
    end
    return out
end

function _G.GetPlayerName(src)
    for _, p in ipairs(env.players) do
        if p == src then
            return ('player_%d'):format(src)
        end
    end
    return nil
end

function _G.GetMaxPlayers()
    return 64
end

function _G.GetCurrentResourceName()
    return 'cis_core'
end

function _G.GetInvokingResource()
    return 'cis_core'
end

function _G.DropPlayer(src, reason)
    env.dropped = { src = src, reason = reason }
end

function _G.IsDuplicityVersion()
    return true
end

function _G.print(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        parts[i] = tostring((select(i, ...)))
    end
    env.printed[#env.printed + 1] = table.concat(parts, '\t')
end

-- Threads are CAPTURED, not run. A scenario decides when the boot thread runs,
-- because the order is what several of these tests are about -- and a
-- CreateThread that ran eagerly would make every scenario's timing identical
-- and therefore untestable.
function _G.CreateThread(fn)
    env.threads[#env.threads + 1] = fn
    return #env.threads
end

function _G.RegisterNetEvent(name, handler)
    env.netEvents[#env.netEvents + 1] = { name = name, handler = handler or env.netEvents[#env.netEvents + 1] }
end

function _G.AddEventHandler(name, handler)
    env.handlers[#env.handlers + 1] = { name = name, handler = handler }
end

function _G.TriggerEvent() end
function _G.TriggerClientEvent() end
function _G.TriggerServerEvent() end

-- ------------------------------------------------------------- the exports

-- The proxy. Indexing a resource name yields a table; indexing an export name
-- on THAT yields a CALLABLE the scenario declared, or nil.
--
-- THE WRAPPER IS THE WHOLE POINT, and getting it wrong makes every scenario
-- test the wrong thing.
--
-- In Lua, `exports['r']:Foo(x)` evaluates as `exports['r'].Foo(exports['r'], x)` --
-- the `self` is the first argument. FiveM's export proxy consumes it: the export
-- receives `(x)`. So the mock returns a closure that DROPS the first argument.
--
-- Without that, `DetectFramework` in cis_core arrives with the exports table as
-- its `configured` parameter, `(configured or 'AUTO'):upper()` raises on a table,
-- and the scenario fails with "attempt to call a nil value (method 'upper')" --
-- which reads like a bug in cis_core and is a bug in the mock. That failure is
-- what this comment was written after seeing.
--
-- A consequence worth stating: because the wrapper is installed through
-- `__index`, the `exports['r']['Foo'](x)` form also drops its first argument
-- here, where in FiveM it does not. So this mock CANNOT detect the self trap
-- documented in init.lua -- both call shapes reach the export the same way. The
-- CI grep is what covers that, and it is why the grep exists rather than a
-- test.
--
-- nil is the other half of it. A declared-absent export indexes to nil, so
-- calling it raises "attempt to call a nil value", which is what a real FiveM
-- `exports.resource.missingName()` does and what the code under test pcalls
-- against. Modelling it as "return a function that returns nil" instead would
-- make every existence probe in cis_core look correct.
local resourcesMt = {
    __index = function(_, exportName)
        local declared = env.exports[exportName]
        if declared == nil then
            return nil
        end
        return function(_, ...)
            return declared(...)
        end
    end,
}

_G.exports = setmetatable({}, {
    -- `exports('Name', fn)` -- the REGISTRATION form, used by the file under test
    __call = function(_, name, fn)
        env.registered[#env.registered + 1] = { name = name, fn = fn }
    end,
    -- `exports['resource']` -- the CALL form
    __index = function(_, resourceName)
        return setmetatable({}, resourcesMt)
    end,
})

-- ================================================================== helpers

--- Declare a resource as started, with an optional version.
--- Declare the players who are connected.
---
--- A helper rather than `Env.env.players = {...}` because a scenario reaching
--- into `FrameworkEnv` for a field that lives on the world table sets a NEW
--- field, silently, and the world keeps its empty list. That happened: the
--- first QBCore scenario reported a connected player and had none, and the
--- symptom was four unrelated assertion failures rather than one obvious one.
function FrameworkEnv.connect(sources)
    env.players = {}
    for i, src in ipairs(sources) do
        env.players[i] = tonumber(src)
    end
    return env.players
end

function FrameworkEnv.resource(name, version)
    env.resources[name] = 'started'
    env.metadata[name] = { version = version }
end

--- Declare a resource as present but NOT started.
function FrameworkEnv.stoppedResource(name)
    env.resources[name] = 'stopped'
end

--- Declare an export that exists. `fn` is the behaviour under test's
--- dependency, so it should answer what the REAL export answers -- or, for a
--- scenario about a framework that changed, what it used to answer.
function FrameworkEnv.export(name, fn)
    env.exports[name] = fn
end

--- A framework object shaped the way QBCore/qbx_core hands one back.
---
--- NOT a mock of QBCore's behaviour. A shape, and nothing else: the tests
--- assert which fields cis_core READS, so the shape must be the real one and
--- the methods must do nothing clever.
-- NOT A CONSTRUCTOR LITERAL, AND THAT IS THE POINT.
--
-- The obvious way to write this is `local p = { Functions = { AddMoney =
-- function() ... p.PlayerData ... end } }`, and it does not work: the scope of a
-- local begins AFTER its declaration statement, so `p` inside the constructor
-- is the outer one -- a GLOBAL here. Every stub that closed over `p` raised
-- "attempt to index a nil value (global 'p')", which reads like a bug in the
-- framework bridge and is a bug in the mock.
--
-- Declare, then assign. `local p` alone puts the local in scope for everything
-- that follows, including a constructor that mentions it.

function FrameworkEnv.qbPlayer(overrides)
    local p
    p = {
        PlayerData = {
            source = 1,
            citizenid = 'ABC12345',
            license = 'license:0000',
            charinfo = { firstname = 'John', lastname = 'Doe' },
            job = { name = 'police', grade = 3 },
            money = { cash = 500, bank = 1200 },
            items = { { name = 'water', amount = 2, slot = 1 } },
            metadata = { handcuffed = false },
        },
        -- NO leading `_` for self, and that is deliberate.
        --
        -- QBCore declares these as `function Player.Functions.AddMoney(moneytype,
        -- amount, reason)` -- declared with a dot, so the implicit first
        -- parameter is the Functions table and the CALLER passes only the real
        -- arguments. cis_core therefore calls `player.Functions.AddMoney(moneyType,
        -- amount)` with a dot, and that is CORRECT.
        --
        -- The first version of this stub took `(_, moneyType, amount)`, so
        -- amount arrived nil and the scenario died with "attempt to compare
        -- number with nil" -- which reads like a bug in the money path and was a
        -- bug in the mock. It is recorded here because the instinct to "fix"
        -- cis_core's dot call into a colon call is exactly the mistake this
        -- comment exists to stop, and it would pass every test in the file.
        Functions = {
            AddMoney = function(moneyType, amount) return tonumber(amount) and amount > 0 end,
            RemoveMoney = function(moneyType, amount) return tonumber(amount) and amount > 0 end,
            HasPermission = function() return true end,
        },
    }
    p.Functions.SetJob = function(job, grade)
        p.PlayerData.job = { name = job, grade = grade }
    end
    for k, v in pairs(overrides or {}) do
        p[k] = v
    end
    return p
end

function FrameworkEnv.esxPlayer(overrides)
    local p
    p = {
        identifier = 'license:0000',
        -- ESX's account store, so the stubs below can decide what is a real
        -- account rather than accepting every string.
        accounts = { cash = 500, bank = 1200 },
        job = { name = 'police', grade = 3 },
        -- The parentheses are REQUIRED and not stylistic: a table constructor
        -- is a simpleexp and cannot begin an index chain, so `{...}[key]` is a
        -- syntax error and `({...})[key]` is the only way to index a literal.
        get = function(key) return ({ handcuffed = false })[key] end,
    }

    -- EVERY method below takes `self` FIRST, because ESX declares them as
    -- `function self.addAccountMoney(accountName, money, reason)` -- so a
    -- caller must use a COLON. The QBCore factory above is the opposite, and
    -- getting either one wrong makes the scenario pass while the bridge is
    -- broken, which is the whole reason this note exists.

    -- Faithful to es_extended/server/classes/player.lua, which RAISES on an
    -- unknown account and on a non-positive amount from 1.8.5 onward. A stub
    -- that accepted anything would make cis_core's pcall-based success check
    -- look correct when it had never actually been exercised.
    function p.addAccountMoney(self, account, amount)
        if type(account) ~= 'string' or p.accounts[account] == nil then
            error(('Tried To Add To Invalid Account %s For Player %s!'):format(
                tostring(account), tostring(self.source)), 2)
        end
        if type(amount) ~= 'number' or amount <= 0 then
            error('Cannot add a non-positive amount', 2)
        end
        p.accounts[account] = p.accounts[account] + amount
        return true
    end

    function p.removeAccountMoney(self, account, amount)
        if type(account) ~= 'string' or p.accounts[account] == nil then
            error(('Tried To Remove From Invalid Account %s For Player %s!'):format(
                tostring(account), tostring(self.source)), 2)
        end
        if type(amount) ~= 'number' or amount <= 0 then
            error('Cannot remove a non-positive amount', 2)
        end
        p.accounts[account] = p.accounts[account] - amount
        return true
    end

    function p.setJob(self, job, grade)
        p.job = { name = job, grade = grade }
    end

    function p.getGroup(self)
        -- Never nil in real ESX: the DB defaults the group to 'user'. Returning
        -- a group rather than nil is what makes the permission check meaningful
        -- and what stops a bridge from treating "no group" as "superadmin".
        return 'user'
    end

    function p.getName(self)
        return 'JohnDoe'
    end

    function p.getAccounts(self)
        return { { name = 'cash', money = 500 }, { name = 'bank', money = 1200 } }
    end

    for k, v in pairs(overrides or {}) do
        p[k] = v
    end
    return p
end

--- Declare the players who are connected.
function FrameworkEnv.runThreads()
    for i = 1, #env.threads do
        env.threads[i]()
    end
end

--- Find a handler across BOTH registration lists.
---
--- `RegisterNetEvent` and `AddEventHandler` are two doors into the same room: in
--- FiveM a TriggerEvent reaches handlers registered either way, and so does a
--- client-triggered net event. Searching one list and calling the helper "fire
--- it as the server would" is how a scenario reports that a handler never fired
--- when it is registered through the other door -- which is exactly what
--- happened the first time this ran.
local function findHandler(name)
    local found = nil
    for _, e in ipairs(env.netEvents) do
        if e.name == name then
            found = e.handler
        end
    end
    for _, e in ipairs(env.handlers) do
        if e.name == name then
            found = e.handler
        end
    end
    return found
end

--- Fire a registered event as a CLIENT would, with `source` set to the player.
function FrameworkEnv.triggerNet(name, from, ...)
    local handler = findHandler(name)
    if not handler then
        return false, 'no handler registered for ' .. name
    end
    _G.source = from
    local ok, err = pcall(handler, ...)
    _G.source = 0
    if not ok then
        return false, err
    end
    return true
end

--- Fire a registered event as the SERVER would (`source` is 0).
function FrameworkEnv.triggerServer(name, ...)
    local handler = findHandler(name)
    if not handler then
        return false, 'no handler registered for ' .. name
    end
    _G.source = 0
    local ok, err = pcall(handler, ...)
    _G.source = 0
    if not ok then
        return false, err
    end
    return true
end

function FrameworkEnv.printedMatching(needle)
    local n = 0
    for _, line in ipairs(env.printed) do
        if line:find(needle, 1, true) then
            n = n + 1
        end
    end
    return n
end

function FrameworkEnv.reset()
    env.resources = {}
    env.exports = {}
    env.metadata = {}
    env.players = {}
    env.printed = {}
    env.threads = {}
    env.netEvents = {}
    env.handlers = {}
    env.registered = {}
    env.now = 0
    env.dropped = nil
end

-- =============================================================================
--  cis_libs's DetectFramework, modelled
--
--  cis_core CALLS this across the boundary -- it cannot share cis_libs's Lua
--  state, which is the whole of the bug fixed in 1.1.0's first commit (a bare
--  `CisDetect` global is nil here, always). So the scenarios have to supply it.
--
--  This is a MODEL of cis_libs/shared/detect.lua, transcribed from it, not a
--  copy of it: cis_core is its own repository and its CI checks out only
--  cis_core, so `dofile('../cis_libs/...')` would work on this machine and fail
--  on every push.
--
--  THE COUPLING THIS CREATES IS REAL AND IS NOT HIDDEN: if cis_libs changes its
--  framework table, these scenarios keep passing while production changes. What
--  they DO prove is everything on cis_core's side of the boundary -- which
--  branch it takes, what it does with the answer, and whether the two realms
--  agree -- and that is where every bug found so far in this file has lived.
--
--  Transcribed from cis_libs at the time of writing; see PLATFORM_NOTES.md.
-- =============================================================================

-- cis_libs `CisDetect.FRAMEWORKS`, most specific first. The ORDER is the
-- contract: a qbx_core server also has qb-* resources on disk, and a naive
-- "is anything started" scan reports whichever it finds first.
local FRAMEWORKS = {
    { name = 'QBOX', resource = 'qbx_core', probe = 'GetPlayer' },
    { name = 'QBCORE', resource = 'qb-core', probe = 'GetCoreObject' },
    { name = 'ESX', resource = 'es_extended', probe = 'getSharedObject' },
}

--- Install the cis_libs exports cis_core's boot path calls, modelling
--- cis_libs's real implementations. A scenario overrides any of them after
--- this call, and that override is the scenario's statement about the world.
function FrameworkEnv.installCisLibs()
    local function isStarted(name)
        return (env.resources[name] or 'missing') == 'started'
    end

    local function version(name)
        local m = env.metadata[name]
        return m and m.version or nil
    end

    -- cis_core's own probeExport: resolve the reference, do not call it.
    local function probe(resource, exportName)
        if type(exportName) ~= 'string' or exportName == '' then
            return true
        end
        local ok, fn = pcall(function()
            return exports[resource][exportName]
        end)
        if not ok or fn == nil then
            return false
        end
        if type(fn) == 'function' then
            return true
        end
        return type(fn) == 'table' and rawget(fn, '__cfx_functionReference') ~= nil
    end

    FrameworkEnv.export('DetectFramework', function(configured, custom)
        configured = (configured or 'AUTO'):upper()
        if type(custom) == 'table' and type(custom.resource) == 'string' and custom.resource ~= '' then
            if not isStarted(custom.resource) then
                return { name = 'NONE', how = 'custom', resource = nil, version = nil,
                    reason = ('custom framework %q is not started'):format(custom.resource) }
            end
            local exportName = custom.getPlayer or custom.probe
            if type(exportName) == 'string' and exportName ~= '' and not probe(custom.resource, exportName) then
                return { name = 'NONE', how = 'custom', resource = nil, version = nil,
                    reason = ('custom framework %q exposes no %q export'):format(custom.resource, exportName) }
            end
            return { name = (custom.name or 'CUSTOM'):upper(), resource = custom.resource,
                version = version(custom.resource), how = 'custom',
                reason = ('custom framework %q'):format(custom.resource) }
        end
        if configured ~= 'AUTO' and configured ~= 'NONE' then
            for _, known in ipairs(FRAMEWORKS) do
                if known.name == configured then
                    local up = isStarted(known.resource)
                    return { name = known.name, resource = up and known.resource or nil,
                        version = up and version(known.resource) or nil, how = 'configured', wanted = true,
                        reason = up and ('configured as %s'):format(known.name)
                            or ('configured as %s but %q is not started'):format(known.name, known.resource) }
                end
            end
            local up = isStarted(configured)
            return { name = up and configured or 'NONE', resource = up and configured or nil,
                version = up and version(configured) or nil, how = 'configured',
                reason = up and ('configured as %s'):format(configured)
                    or ('configured as %s, which is not a known framework and is not started'):format(configured) }
        end
        if configured == 'NONE' then
            return { name = 'NONE', how = 'configured', resource = nil, version = nil,
                reason = 'configured as NONE; no framework is used' }
        end
        for _, known in ipairs(FRAMEWORKS) do
            if isStarted(known.resource) and probe(known.resource, known.probe) then
                return { name = known.name, resource = known.resource, version = version(known.resource),
                    how = 'detected',
                    reason = ('detected %s (%s) running'):format(known.resource, tostring(version(known.resource))) }
            end
        end
        return { name = 'NONE', how = 'detected', resource = nil, version = nil,
            reason = 'no supported framework is started' }
    end)

    -- Everything else cis_core calls that the framework scenarios exercise.
    -- Answering "not ready" is the honest default: a scenario that wants
    -- readiness says so.
    FrameworkEnv.export('WaitReady', function() return false end)
    FrameworkEnv.export('SetConfig', function() return true end)
    FrameworkEnv.export('SetDropPlayerHandler', function() return true end)
    FrameworkEnv.export('RegisterCapability', function() return true end)
    FrameworkEnv.export('RegisterCallback', function() return true end)
    FrameworkEnv.export('PublishJobUpdate', function() return true end)
    FrameworkEnv.export('PublishInventory', function() return true end)
    -- Faithful to the real path, which is what makes a scenario's answer mean
    -- something: the inventory service falls back to the FRAMEWORK's player
    -- object, so with no framework there is nothing to add to and it answers
    -- false. A stub that returned an unconditional true made "GiveItem answers
    -- false in standalone mode" fail -- and it was the stub that was wrong, not
    -- the resource, which is exactly the sort of thing these tests exist to
    -- settle.
    local function hasPlayer(src)
        return CisFramework ~= nil and CisFramework.GetPlayer(src) ~= nil
    end
    FrameworkEnv.export('InventoryAdd', function(src) return hasPlayer(src) end)
    FrameworkEnv.export('InventoryRemove', function(src) return hasPlayer(src) end)
    FrameworkEnv.export('InventoryHas', function() return false end)
    FrameworkEnv.export('GetOnlineJobCount', function() return 0 end)
    FrameworkEnv.export('GetCapabilities', function() return {} end)
    FrameworkEnv.export('GetSelfCheck', function() return { ok = true, problems = {} } end)
    -- `CisFramework`, not `Framework`: the server file aliases the capability
    -- table to a FILE-LOCAL named `Framework`, and the global `Framework` only
    -- exists on the client. Reaching for the wrong one is an error at load time.
    FrameworkEnv.export('GetFramework', function() return CisFramework end)
    FrameworkEnv.export('NotifyClient', function() return true end)
    FrameworkEnv.export('DbQuery', function() return nil end)
    FrameworkEnv.export('DbSingle', function() return nil end)
    FrameworkEnv.export('DbUpdate', function() return nil end)
    FrameworkEnv.export('DbInsert', function() return nil end)
    FrameworkEnv.export('DbTransaction', function() return false, 'no transactions here' end)
end

return FrameworkEnv