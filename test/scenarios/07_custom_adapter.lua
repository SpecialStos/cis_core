-- Scenario: an operator-supplied framework nobody has heard of.
--
-- The escape hatch, and the one place detection is supposed to override an
-- EXPLICIT operator choice rather than the other way round. If an operator wired
-- up their own framework, guessing at a known one instead is never what they
-- meant -- so a custom adapter beats `Type = "QBCORE"`, not just `AUTO`.
--
-- The second half of the scenario is the interesting half: an adapter that is
-- configured but NOT started, and one that is started but exposes nothing. Both
-- have to degrade to NONE with a reason rather than silently falling through to
-- a known framework that happens to also be installed.

local Env = FrameworkEnv
Env.installCisLibs()

-- A custom adapter wins even over an explicit, known Type.
Config = {
    Framework = {
        Type = 'QBCORE',
        Custom = { resource = 'my_framework', name = 'MYFRAME', getPlayer = 'GetPlayer' },
        Inventory = 'typical',
        Database = { Type = 'AUTO' },
    },
    Printing = { Debug = false, UseDiscordLogs = false },
}

-- qb-core is ALSO started, and it is installed first in most start orders. The
-- custom adapter must still win.
Env.resource('qb-core', '3.7.1')
Env.resource('my_framework', '0.2.0')
Env.export('GetCoreObject', function()
    return { Functions = { GetPlayer = function() return nil end } }
end)
Env.export('GetPlayer', function(src) return tonumber(src) == 1 and Env.qbPlayer() or nil end)
Env.connect({ 1 })

dofile('framework/framework_server.lua')
Env.runThreads()

Test.begin('custom')
local check = Test.check
Test.note(('configured=%s detected=%s'):format(
    tostring(Config.Framework.Type), tostring(CisFramework.detected and CisFramework.detected.name)))

-- ------------------------------------------------------------------ the win
check(CisFramework.detected.how == 'custom', 'detection reports the adapter as custom, not as detected')
check(CisFramework.detected.resource == 'my_framework', 'and names the operator resource')
check(CisFramework.detected.name == 'MYFRAME', 'and uses the operator name')
check(CisFramework.GetPlayer(1) ~= nil, 'the adapter is how players are found')

Test.report()
Test.raiseIfFailed()