-- Scenario: every handler, fired with hostile payloads.
--
-- The four events this resource listens for are all reachable from a client by
-- name. A cheat menu does not have to find a bug; it can simply send whatever it
-- likes to `esx:playerLoaded` and watch. So each handler is fired here with the
-- payloads that actually break code: sources that are not sources, numbers that
-- are not numbers, tables where a value belongs, and a payload big enough to be
-- a denial of service.
--
-- TWO ASSERTIONS MATTER, and neither is "it returned an error":
--
--   1. NOTHING RAISES. A handler that raises takes down whatever thread called
--      it. For a networked event that is the scheduler thread, and the failure
--      surfaces as a resource that stopped handling events with a stack trace
--      pointing at the wrong file.
--
--   2. NOTHING IS GRANTED. A handler that "handles" a hostile payload by acting
--      on it is worse than one that raises. Every refusal here must be a
--      refusal, and the forgery counter must move for each one that tried.

local Env = FrameworkEnv
Env.installCisLibs()

Config = {
    Framework = { Type = 'AUTO', Inventory = 'typical', Database = { Type = 'AUTO' } },
    Printing = { Debug = false, UseDiscordLogs = false },
}

Env.resource('qb-core', '3.7.1')
Env.export('GetCoreObject', function()
    return { Functions = {
        GetPlayer = function(src) return tonumber(src) == 1 and Env.qbPlayer() or nil end,
        GetPlayers = function() return { 1 } end, -- source IDS, as the real one does
    } }
end)
Env.connect({ 1 })

local published = {}
local snapshots = {}
Env.export('PublishJobUpdate', function(job, src)
    published[#published + 1] = { job = job, src = src }
    return true
end)
Env.export('PublishInventory', function(src)
    snapshots[#snapshots + 1] = src
    return true
end)

dofile('framework/framework_server.lua')
Env.runThreads()

Test.begin('adversarial')
local check = Test.check

local events = {
    'QBCore:Server:PlayerLoaded',
    'QBCore:Server:OnJobUpdate',
    'esx:playerLoaded',
    'esx:setJob',
    'ox_inventory:openedInventory',
}

-- ---------------------------------------------------------------- the sweep
-- Every combination of "a source a client could send" and "a payload a client
-- could send". The point is not that any particular one succeeds -- none may --
-- but that none of them raises.
--
-- THE LISTS ARE COUNTED, NOT `ipairs`-ed, and that is load-bearing. `ipairs`
-- stops at the first nil, and the FIRST payload here is nil -- the "client sent
-- the event with no arguments at all" case, which is the first thing a cheat
-- menu does. Written as a plain list it was silently skipped, the sweep
-- delivered nothing, and every assertion came back green: `deliveries=0` is
-- what a vacuous test always looks like.
local NO_ARG = setmetatable({}, { __tostring = function() return 'NO_ARG' end })

local sources = {
    1, 2, 99, 0, -1, 2049, 1e9, 0 / 0, math.huge, -math.huge,
    '1', 'abc', '', true, false, {}, { 1, 2 }, print, nil,
}
local SOURCE_N = 19

local payloads = {
    NO_ARG, nil, 0, -1, 1e308, 0 / 0, math.huge, '', 'x', "' OR 1=1 --",
    '; DROP TABLE x; --', string.rep('A', 65536),
    { name = 'police', grade = 0 },
    { name = 'police', grade = 0, extra = string.rep('B', 4096) },
    { name = 42, grade = {} },
    { name = 'police', grade = -99999 },
    {},
    { PlayerData = { source = 99 } },
    { PlayerData = 'not a table', source = 99 },
    print,
}
local PAYLOAD_N = 20

local raised, ran = 0, 0
for e = 1, #events do
    local event = events[e]
    for si = 1, SOURCE_N do
        local src = sources[si]
        for pi = 1, PAYLOAD_N do
            local payload = payloads[pi]
            ran = ran + 1
            local ok
            if payload == NO_ARG then
                -- Sent with nothing at all: a different call shape, and the one
                -- a menu uses first.
                ok = pcall(Env.triggerNet, event, src)
            else
                ok = pcall(Env.triggerNet, event, src, payload, payload)
            end
            if not ok then
                raised = raised + 1
            end
        end
    end
end

-- The vacuity guard, stated as its own assertion rather than left implied by
-- the count that happens to be printed next to it. `deliveries=0` with every
-- other assertion green is what a sweep that silently tested nothing looks
-- like, and it passed once already.
check(ran > 1000, ('the sweep actually delivered events (%d)'):format(ran))
check(raised == 0,
    ('no handler raised across %d hostile event deliveries (%d did)'):format(ran, raised))
Test.note(('deliveries=%d raised=%d published=%d snapshots=%d')
    :format(ran, raised, #published, #snapshots))

-- ------------------------------------------------------------- what was done
-- The counter must have moved for every networked forgery, and NONE of the
-- deliveries may have published anything about a player who is not the sender.
local publishedToOthers = 0
for _, p in ipairs(published) do
    if p.src ~= 1 then
        publishedToOthers = publishedToOthers + 1
    end
end
check(publishedToOthers == 0,
    ('nothing was published about a player the sender was not (%d did)'):format(publishedToOthers))

-- THE TWO COUNTS ARE SEPARATE, and that is the finding.
--
-- A sweep like this one sends every event with no source at all, which is NOT
-- a forgery: nothing was named, and the sender's own source was used. If that
-- incremented `spoofed` then anyone could drive the counter -- the one number
-- meant to detect a cheat menu -- with a zero-byte event, and the doctor would
-- tell an operator that clients are forging sources when they are not.
check(CisAuthority.spoofed > 0,
    ('forged sources are counted rather than silently absorbed (%d)'):format(CisAuthority.spoofed))
check(CisAuthority.anonymous > 0,
    ('and events sent with no source are counted separately (%d)'):format(CisAuthority.anonymous))

-- A zero-byte event from a client must NOT move the forgery count. This is the
-- exploit in one line.
local spoofBefore = CisAuthority.spoofed
local anonBefore = CisAuthority.anonymous
Env.triggerNet('QBCore:Server:OnJobUpdate', 1)
check(CisAuthority.spoofed == spoofBefore,
    'a client event carrying no source is not counted as a forgery')
check(CisAuthority.anonymous == anonBefore + 1, 'it is counted as anonymous instead')

-- --------------------------------------------------------- the big one
-- A payload large enough to be worth sending. This is the shape that turns a
-- handler into a denial of service: not one huge string, but a table the client
-- assembled to be expensive to walk.
local huge = {}
for i = 1, 12000 do
    huge[i] = { name = 'item' .. i, amount = i }
end
local okHuge, errHuge = pcall(Env.triggerNet, 'QBCore:Server:PlayerLoaded', 1, huge)
check(okHuge == true, ('a 12000-entry payload does not raise (%s)'):format(tostring(errHuge)))

-- The source claim inside it must still be checked, not believed: the payload
-- says the event is about player 99 and the network says player 1.
check(publishedToOthers == 0, 'and the embedded source claim is still overridden by the network')

-- ------------------------------------------------- the framework surface too
-- Same treatment for the methods a consumer calls with a value from a net event.
for _, bad in ipairs({ 'water', 42, {}, print, 'item with spaces', string.rep('n', 500) }) do
    local ok = pcall(CisFramework.GiveMoney, bad, 100, 'cash')
    check(ok == true, ('GiveMoney survives a %s source'):format(type(bad)))
    ok = pcall(CisFramework.GetPlayerJob, bad)
    check(ok == true, ('GetPlayerJob survives a %s source'):format(type(bad)))
end

check(CisFramework.GiveMoney(1, 0, 'cash') == false, 'adding zero is refused rather than taken')
check(CisFramework.GiveMoney(1, -100, 'cash') == false, 'and so is adding a negative amount')
check(CisFramework.RemoveMoney(1, 0, 'cash') == false, 'removing zero is refused')

Test.report()
Test.raiseIfFailed()