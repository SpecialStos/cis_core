-- Scenario: configured QBOX, actually running qb-core.
--
-- The configuration mistake this resource exists to absorb. An operator writes
-- `Type = "QBOX"`, runs qb-core, and gets a server where detection says QBOX and
-- the server half quietly bridges as QBCore.
--
-- It used to end with the two halves DISAGREEING. The server rewrote its own
-- provider to QBCORE and carried on, but the config was only rewritten on the
-- AUTO path -- so the client, which receives `Config.Framework.Type` verbatim in
-- the config payload, still read QBOX, reached for `exports.qbx_core`, found no
-- such resource, and settled for standalone. Notifications went to the GTA feed
-- and job tracking never started, with nothing in the console saying why.
--
-- The assertion that matters is the LAST one: the config must end up agreeing
-- with what the server is actually doing, because that config is what the client
-- reads.

local Env = FrameworkEnv
Env.installCisLibs()

Config = {
    Framework = { Type = 'QBOX', Inventory = 'typical', Database = { Type = 'AUTO' } },
    Printing = { Debug = false, UseDiscordLogs = false },
}

Env.resource('qb-core', '3.7.1')
Env.export('GetCoreObject', function()
    return { Functions = {
        GetPlayer = function(src) return tonumber(src) == 1 and Env.qbPlayer() or nil end,
        GetPlayers = function() return { Env.qbPlayer() } end,
    } }
end)
Env.connect({ 1 })

dofile('framework/framework_server.lua')
Env.runThreads()

Test.begin('qbox-on-qbcore')
local check = Test.check
Test.note(('configured=QBOX now=%s'):format(tostring(Config.Framework.Type)))

-- The server bridged as QBCORE, because QBCORE is what is loaded. Reporting
-- the configured name instead would send every consumer to the wrong branch.
check(Config.Framework.Type == 'QBCORE',
    'the config is corrected to what is actually running, not left claiming QBOX')
check(CisFramework.detected.name == 'QBCORE', 'and the detection result agrees')

-- And it works, which is the whole point of the correction.
check(CisFramework.GetPlayer(1) ~= nil, 'player lookups work')
local n = CisFramework.NormalizedPlayer(1)
check(n.name == 'John Doe', 'and so does the normalised shape a consumer reads')

Test.report()
Test.raiseIfFailed()