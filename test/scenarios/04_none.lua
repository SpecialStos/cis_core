-- Scenario: no framework at all.
--
-- The failure mode this guards is the one that produces the worst support
-- ticket: not an error, but a resource that boots, reports itself ready, and
-- answers nil for every player. Detection has to reach that state deliberately
-- and say so, rather than raising inside a thread nobody awaits.

local Env = FrameworkEnv
Env.installCisLibs()

Config = {
    Framework = { Type = 'AUTO', Inventory = 'typical', Database = { Type = 'AUTO' } },
    Printing = { Debug = false, UseDiscordLogs = false },
}

-- Nothing is started. No framework, no inventory, no database.
Env.connect({})

dofile('framework/framework_server.lua')
Env.runThreads()

Test.begin('none')
local check = Test.check
Test.note(('detected=%s logged=%d'):format(tostring(Config.Framework.Type), #Env.env.printed))

-- ------------------------------------------------------------------ detect
check(FrameworkLoaded == true, 'boot completes without a framework')
check(Config.Framework.Type == 'NONE', 'and the config is rewritten to NONE, not left claiming AUTO')

-- The rewrite is the point. A server silently running standalone is the most
-- damaging outcome here, so cis_core corrects the config AND prints why.
check(#Env.env.printed > 0, 'and it says out loud that there is no framework')
check(Env.printedMatching('no framework') > 0, 'in words an operator can act on')

-- ----------------------------------------------------------------- surface
-- Every method has a no-framework answer, and it is never an exception. That is
-- the whole contract of this mode.
check(CisFramework.GetPlayer(1) == nil, 'GetPlayer answers nil')
check(CisFramework.GetPlayerJob(1) == nil, 'GetPlayerJob answers nil')
check(CisFramework.GetPlayerIdentifier(1) == nil, 'GetPlayerIdentifier answers nil')
check(CisFramework.HasPermission(1, 'admin') == false, 'HasPermission answers false, not nil')
check(CisFramework.GiveMoney(1, 100, 'cash') == false, 'GiveMoney answers false')
check(CisFramework.RemoveMoney(1, 100, 'cash') == false, 'RemoveMoney answers false')
check(CisFramework.GiveItem(1, 'water', 1) == false, 'GiveItem answers false')
check(CisFramework.RemoveItem(1, 'water', 1) == false, 'RemoveItem answers false')
check(type(CisFramework.GetPlayers()) == 'table', 'GetPlayers still answers a table')

-- NormalizedPlayer is the one a consumer reads, and it must be a table even
-- when there is nothing behind it.
local n = CisFramework.NormalizedPlayer(1)
check(type(n) == 'table', 'NormalizedPlayer answers a table')
check(n.id == 1, 'carrying the source')
check(n.name == nil, 'and nothing it cannot know')

-- SetPlayerJob in standalone must be a no-op that does not raise.
local called, setErr = pcall(function() CisFramework.SetPlayerJob(1, 'police', 4) end)
check(called == true, 'SetPlayerJob is a no-op that does not raise')

Test.report()
Test.raiseIfFailed()