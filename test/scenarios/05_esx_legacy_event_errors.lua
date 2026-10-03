-- Scenario: an ESX build with no `getSharedObject` export.
--
-- The research is specific about three generations here, and the difference
-- between them is the whole scenario:
--
--   1.4.2 - 1.8.5   the event answers: `AddEventHandler('esx:getSharedObject',
--                     function(cb) cb(ESX) end)`
--   1.9.4            the event does nothing at all
--   1.10.10          the event RAISES -- its handler is
--                     `function() error("...this event no longer exists!") end`
--
-- So a bridge that falls back to the event with an un-guarded TriggerEvent does
-- not degrade, it takes its boot thread down on 1.10.10 -- inside a thread
-- nobody awaits, which is the worst of both: the resource is half-started and
-- the console shows an error attributed to a different file.
--
-- This world answers the event by RAISING, which is the 1.10.10 behaviour, and
-- asserts that cis_core still boots.

local Env = FrameworkEnv
Env.installCisLibs()

Config = {
    Framework = { Type = 'ESX-LEGACY', Inventory = 'typical', Database = { Type = 'AUTO' } },
    Printing = { Debug = false, UseDiscordLogs = false },
}

Env.resource('es_extended', '1.10.10')

-- No `getSharedObject` export at all: that is what ESX-LEGACY means here.
-- And the event, when asked, raises -- exactly as 1.10.10 does.
local eventAsked = 0
function _G.TriggerEvent(name, ...)
    if name == 'esx:getSharedObject' then
        eventAsked = eventAsked + 1
        error('Resource X Used the getSharedObject Event, this event no longer exists!', 0)
    end
end

local booted, bootErr = pcall(function()
    dofile('framework/framework_server.lua')
    Env.runThreads()
end)

Test.begin('esx-legacy-errors')
local check = Test.check
Test.note(('booted=%s err=%s eventAsked=%d detected=%s'):format(
    tostring(booted), tostring(bootErr), eventAsked, tostring(Config.Framework.Type)))

-- THE ASSERTION. Everything else in this file is context.
check(booted == true,
    'an ESX whose getSharedObject event RAISES does not take the boot thread down')

-- And the honest outcome: no framework, said out loud. Not a crash, and not a
-- claim that ESX is there.
check(Config.Framework.Type == 'NONE', 'and it settles on NONE rather than claiming ESX')
check(Env.printedMatching('standalone') + Env.printedMatching('unavailable') > 0,
    'printing which state it is in')

-- The surface still answers every question, because "no framework" is a mode.
check(CisFramework.GetPlayer(1) == nil, 'GetPlayer answers nil')
check(CisFramework.HasPermission(1, 'admin') == false, 'HasPermission answers false')

Test.report()
Test.raiseIfFailed()