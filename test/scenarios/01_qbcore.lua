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
    GetPlayers = function() return { Env.qbPlayer() } end,
    HasPermission = function() return true end,
} }
Env.export('GetCoreObject', function() return core end)

-- The player who is connected, for the backfill walk at the end of boot.
Env.players = { 1 }

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
Env.triggerServer('QBCore:Server:OnJobUpdate', 1, { name = 'ambulance', grade = 1 })
check(#publishedJobs == jobsBefore + 1, 'a server-side job change is published')
check(publishedJobs[#publishedJobs].job.name == 'ambulance', 'with the job it carried')

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
check(#publishedJobs == 1, 'the backfill published exactly one job')
check(publishedJobs[1].src == 1, 'for the connected player')
check(publishedJobs[1].job ~= nil and publishedJobs[1].job.name == 'police',
    'and with the job that player actually has')

Test.report()
Test.raiseIfFailed()