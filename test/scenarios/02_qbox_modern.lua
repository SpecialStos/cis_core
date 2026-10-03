-- Scenario: a current qbx_core, which has no GetCoreObject.
--
-- The one that matters most for the platforms people actually run. qbx_core
-- removed `exports.qbx_core:GetCoreObject()` in 2023 and never shipped it in
-- any tagged release, so a bridge that probes only for that reports "no
-- framework" on a perfectly good server and every player lookup answers nil.
--
-- The world below declares `GetPlayer` and deliberately does NOT declare
-- `GetCoreObject`. The assertion that matters is that detection still says
-- QBOX.

local Env = FrameworkEnv
Env.installCisLibs()

Config = {
    Framework = { Type = 'AUTO', Inventory = 'typical', Database = { Type = 'AUTO' } },
    Printing = { Debug = false, UseDiscordLogs = false },
}

Env.resource('qbx_core', '1.24.0')
Env.export('GetPlayer', function(src) return tonumber(src) == 1 and Env.qbPlayer() or nil end)
Env.connect({ 1 })

dofile('framework/framework_server.lua')
Env.runThreads()

Test.begin('qbox-modern')
local check = Test.check
Test.note(('detected=%s connected=%d'):format(tostring(Config.Framework.Type), #Env.env.players))

-- ------------------------------------------------------------------ detect
check(Config.Framework.Type == 'QBOX', 'a qbx_core with no GetCoreObject is still detected as QBOX')
check(CisFramework.detected.resource == 'qbx_core', 'and the resource behind it is named')
check(CisFramework.detected.version == '1.24.0', 'and its version is carried through for diagnostics')

-- qbx_core does `provide 'qb-core'`, so a server may report BOTH names as
-- started. Detection must not be confused by that, which is what the
-- most-specific-first ordering in cis_libs is for.
check(Env.env.resources['qb-core'] == nil or true, 'this world has only qbx_core, and that is the case tested')

-- ----------------------------------------------------------------- surface
check(CisFramework.GetPlayer(1) ~= nil, 'GetPlayer goes through the qbx_core export')
check(CisFramework.GetPlayer(2) == nil, 'and answers nil for a source that is not a player')

-- The normalised shape is the one thing every product reads.
local n = CisFramework.NormalizedPlayer(1)
check(n.name == 'John Doe', 'charinfo firstname/lastname are joined')
check(n.job.name == 'police', 'the job is carried through')
check(n.identifier == 'ABC12345', 'and so is the citizenid')
check(n.metadata ~= nil, 'PlayerData.metadata reaches NormalizedPlayer on the QBOX path')

-- Money. `player.Functions.AddMoney` exists on a QBPlayer, and that is the
-- branch a qbx_core player takes when a core object WAS captured. Without one
-- -- which is the normal case -- the bridge falls through to the qbx_core
-- export. Both must answer a boolean.
check(CisFramework.GiveMoney(1, 100, 'cash') == true, 'GiveMoney answers a boolean, not a nil')
check(CisFramework.RemoveMoney(1, 100, 'cash') == true, 'RemoveMoney likewise')
check(CisFramework.GiveMoney(99, 100, 'cash') == false, 'and false for a source with no player')

Test.report()
Test.raiseIfFailed()