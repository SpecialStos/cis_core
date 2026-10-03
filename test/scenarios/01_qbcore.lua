-- Scenario: a QBCore server, detected by AUTO.
--
-- The plain case, and the case most installs are. If THIS breaks, the resource
-- is broken for most of its audience, so it is the first one written.
--
-- What is being asserted is cis_core's behaviour: which branch it takes, that it
-- rewrites the config to what it detected, that the capability is registered,
-- and that a job change on the wire reaches the framework.

local Env = FrameworkEnv
Env.installCisLibs()

-- ---------------------------------------------------------------- the world
Config = {
    Framework = { Type = 'AUTO', Inventory = 'typical', Database = { Type = 'AUTO' } },
    Printing = { Debug = false, UseDiscordLogs = false },
}

Env.resource('qb-core', '3.7.1')
local core = { Functions = {
    GetPlayer = function(src) return src == 1 and Env.qbPlayer() or nil end,
    -- SOURCE IDS, as the real one does: `for k in pairs(QBCore.Players) do
    -- sources[#sources+1] = k end`. This fixture returned objects for the life
    -- of the scenario, and that is how the shape bug survived a test suite.
    GetPlayers = function() return { 1, 2 } end,
    HasPermission = function() return true end,
} }
Env.export('GetCoreObject', function() return core end)

-- The player who is connected, for the backfill walk at the end of boot.
Env.connect({ 1 })

-- Record what the boot path PUBLISHES. The backfill is invisible from the
-- outside -- it prints nothing -- so the only honest way to assert it happened
-- is to watch the call it makes.
local publishedJobs = {}
Env.export('PublishJobUpdate', function(job, src)
    publishedJobs[#publishedJobs + 1] = { job = job, src = src }
    return true
end)

dofile('framework/framework_server.lua')
Env.runThreads()

-- Counted HERE, immediately after boot and BEFORE any event is fired. The
-- backfill is the first thing that publishes, and asserting on the total at the
-- bottom of the file counts the events this scenario fired afterwards too --
-- which is how "the backfill published exactly one job" failed on a run where
-- the backfill had published exactly one job.
local afterBoot = #publishedJobs

local check = Test.check
Test.begin('qbcore')

-- ------------------------------------------------------------------ detect
check(FrameworkLoaded == true, 'boot completed')
check(Config.Framework.Type == 'QBCORE',
    'the config is rewritten to what was detected, so the client agrees with the server')
check(CisFramework.detected ~= nil and CisFramework.detected.name == 'QBCORE',
    'the detection result is recorded for cis_debug and the doctor')
check(CisFramework.detected.how == 'detected', 'and it says it was detected, not configured')

-- The capability is registered by REFERENCE, not sent: a function cannot cross
-- the exports boundary but a string can, and cis_libs resolves it back.
local sawCapability = nil
for _, r in ipairs(Env.env.registered) do
    if r.name == 'CisCoreFramework' then
        sawCapability = r.fn
    end
end
check(sawCapability ~= nil, 'CisCoreFramework was registered as an export')

-- ------------------------------------------------------------- the surface
check(CisFramework.IsLoaded() == true, 'IsLoaded answers true after boot')
check(CisFramework.GetPlayer(1) ~= nil, 'GetPlayer returns the player for a live source')
check(CisFramework.GetPlayer(99) == nil, 'GetPlayer returns nil for a source that is not a player')
check(CisFramework.GetPlayerJob(1).name == 'police', 'GetPlayerJob reads the framework job')
check(CisFramework.GetPlayerIdentifier(1) == 'ABC12345', 'GetPlayerIdentifier reads citizenid')
check(CisFramework.HasPermission(1, 'admin') == true, 'HasPermission answers a real boolean')

-- The normalised shape is the ONE thing every product reads, so its field
-- sources are worth pinning.
local n = CisFramework.NormalizedPlayer(1)
check(n.id == 1, 'NormalizedPlayer carries the source')
check(n.name == 'John Doe', 'charinfo firstname/lastname are joined -- and the CASE matters')
check(n.job.name == 'police', 'the job is carried through')
check(n.identifier == 'ABC12345', 'the identifier is carried through')
check(n.money.cash == 500, 'the SQL frameworks money table is carried through unflattened')
check(n.metadata ~= nil, 'PlayerData.metadata is carried through')

-- A player who is not there gets the documented answer, not a raise.
local none = CisFramework.NormalizedPlayer(99)
check(none.id == 99, 'a missing player still answers the id')
check(none.name == nil, 'and nothing else')

-- -------------------------------------------------------------- the events
-- A job change the server broadcasts. `source` is 0 because the framework
-- triggered it from its own server code.
local jobsBefore = #publishedJobs
local fired, fireErr = Env.triggerServer('QBCore:Server:OnJobUpdate', 1, { name = 'ambulance', grade = 1 })
-- Notes, not assertions: the world this ran against, printed only when
-- something else failed. A reader of a red run should not have to re-derive it.
Test.note(('triggerServer fired=%s connected=%d detected=%s'):format(
    tostring(fired), #Env.env.players, tostring(Config.Framework.Type)))
Test.note(('published before=%d after=%d'):format(jobsBefore, #publishedJobs))
check(#publishedJobs == jobsBefore + 1, 'a server-side job change is published')

-- NOT the job the payload carried. The job is derived from the framework
-- server-side, because the payload is as sender-chosen as the source was and it
-- lands in the histogram dispatch balances are answered from. The framework
-- still says 'police' at this point, so the honest expectation is 'police' --
-- publishing 'ambulance' here is the vulnerability, not the feature.
local last = publishedJobs[#publishedJobs]
check(last ~= nil and last.job ~= nil and last.job.name == 'police',
    'and the job the FRAMEWORK says, not the one the payload claimed')

-- The same event from a CLIENT naming somebody else: refused, and the attacker
-- gets their own source. This is the security fix, exercised through the real
-- file rather than through authority.lua alone.
local spoofBefore = CisAuthority.spoofed
Env.triggerNet('QBCore:Server:OnJobUpdate', 1, 9, { name = 'police', grade = 4 })
check(CisAuthority.spoofed == spoofBefore + 1, 'a client naming another player is counted as a forgery')

-- And the boot backfill: every connected player is recorded at startup. This is
-- what makes an online-police count correct on a RESTART rather than only after
-- each player happens to reconnect -- the framework's own PlayerLoaded events
-- have already fired for everyone by the time this thread runs.
check(afterBoot == 1, 'the backfill published exactly one job')
check(publishedJobs[1].src == 1, 'for the connected player')
check(publishedJobs[1].job ~= nil and publishedJobs[1].job.name == 'police',
    'and with the job that player actually has')

-- GetPlayers. `QBCore.Functions.GetPlayers()` answers SOURCE IDS -- verified in
-- qb-core's own server/functions.lua, where it iterates `pairs(QBCore.Players)`
-- and collects the KEYS. The fixture used to answer objects, which is a fixture
-- written to match the code rather than the framework, and it is exactly why
-- this shape bug survived.
--
-- So this is the assertion that the bridge resolves them: every branch returns
-- the same shape, and a consumer does not have to know which framework is up.
local listed = CisFramework.GetPlayers()
check(type(listed) == 'table', 'GetPlayers returns a table')
check(#listed == 2, 'with one entry per connected player')
check(listed[1] ~= nil and type(listed[1]) == 'table', 'and each entry is an OBJECT, not a source id')
check(listed[1].id == 1, 'carrying the source')
check(listed[2] ~= nil and listed[2].id == 2, 'for both players')
check(listed[1].name == 'John Doe', 'and the normalised shape, so a consumer reads it the same way on every framework')

-- Money. The Functions table BINDS its own receiver -- buildMethodTable does
-- `t[name] = function(...) return fn(player, ...) end` -- so a DOT call is
-- correct here, while ESX's xPlayer methods declare `self` explicitly and need
-- a COLON. Opposite conventions, one file, and getting either wrong is silent
-- on one framework.
check(CisFramework.GiveMoney(1, 100, 'cash') == true, 'GiveMoney answers a boolean through the bound Functions table')
check(CisFramework.RemoveMoney(1, 100, 'cash') == true, 'and RemoveMoney likewise')
check(CisFramework.GiveMoney(99, 100, 'cash') == false, 'false for a source with no player')

-- And markedbills is an ITEM, not a money type -- verified in qb-core's
-- shared/items.lua: `markedbills = { ... type = 'item' ... unique = true }`.
-- Routing it to AddMoney would create an account named markedbills that no shop
-- and no ATM knows how to spend, while the balance still rises.
-- Nothing is printed either way, so the assertion is about the ROUTE: no line
-- anywhere names markedbills as an account, and the call answers the same
-- boolean a real account would.
check(CisFramework.GiveMoney(1, 500, 'markedbills') == true, 'markedbills is accepted')
check(Env.printedMatching('markedbills') == 0,
    'and nothing anywhere treats it as an account')

Test.report()
Test.raiseIfFailed()