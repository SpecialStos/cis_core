-- Scenario: the client half of the framework bridge.
--
-- The client had no tests at all, and it is not a mirror of the server: the
-- detection is the same call, but the job cache is driven by the framework's
-- OWN client events, and this file is where two of those were registered
-- against names that either did not exist or did not mean what the code
-- claimed.
--
-- Specifically, and verified against qbx_core v1.24.0 source rather than
-- assumed:
--
--   qbx_core:client:playerLoaded   DOES NOT EXIST. Not deprecated, not
--       renamed -- absent from every tagged release. The listener was dead from
--       the day it was written.
--
--   qbx_core:client:onJobUpdate    EXISTS and is NOT a player's job change. It
--       is the job DEFINITION registry:
--           TriggerClientEvent('qbx_core:client:onJobUpdate', -1, name,
--               jobs[name])
--       broadcast to every client whenever a job definition is created or
--       edited. Note the lowercase `on`. Binding a player-job handler to it was
--       harmless only because the first argument is a string and the shape
--       reader rejected it -- a job definition table has a `name` field, so an
--       upstream argument reorder would have stored a definition as the
--       player's job with nothing erroring.
--
-- qbx_core's whole player-lifecycle surface is under the `QBCore:` prefix. So
-- the assertions below are about the two listeners that survived.

local Env = FrameworkEnv
Env.installCisLibs()

-- The client reads the REDACTED config from the library, not from disk.
Env.export('GetClientConfig', function()
    return { Framework = { Type = 'QBCORE', Inventory = 'ox_inventory' }, Printing = {} }
end)

Env.resource('qb-core', '3.7.1')
Env.export('GetCoreObject', function()
    return {
        Functions = {
            GetPlayerData = function()
                return { job = { name = 'police', grade = 3 }, items = {} }
            end
        },
    }
end)
Env.connect({ 1 })

dofile('framework/framework_client.lua')
Env.runThreads()

Test.begin('client')
local check = Test.check
-- `Config` is a FILE-LOCAL in framework_client.lua, deliberately: a global of
-- that name would be a second Config in the same VM meaning something subtly
-- different. So the world is read back through the capability instead.
Test.note(('loaded=%s listeners=%d'):format(tostring(FrameworkLoaded), #Env.env.netEvents))
for _, entry in ipairs(Env.env.netEvents) do Test.note('listens: ' .. tostring(entry.name)) end

-- ============================================================== the listeners
local registered = {}
for _, entry in ipairs(Env.env.netEvents) do
    registered[entry.name] = entry.handler
end

check(registered['QBCore:Client:OnJobUpdate'] ~= nil, 'the per-player job event is listened for')
check(registered['QBCore:Client:OnPlayerLoaded'] ~= nil, 'the per-player loaded event is listened for')

-- AND ONLY THOSE. The assertion is about ABSENCE, which is the only kind that
-- catches a listener wired to a name that does not exist.
check(registered['qbx_core:client:playerLoaded'] == nil,
    'no listener on a qbx_core event that does not exist')
check(registered['qbx_core:client:onJobUpdate'] == nil,
    'and none on the job DEFINITION registry, which is not a player job change')

-- ================================================================ the job cache
-- The initial read, so a consumer asking before the first event still gets an
-- answer.
check(Framework.GetPlayerJob() ~= nil, 'the job is read at boot')
check(Framework.GetPlayerJob().name == 'police', 'from the framework player data')

-- A job change from the framework: the job moves.
Env.triggerNet('QBCore:Client:OnJobUpdate', 65535, { name = 'ambulance', grade = 1 })
check(Framework.GetPlayerJob().name == 'ambulance', 'a framework job change updates the cache')

-- A player-loaded event carrying PlayerData, which is the QBCore shape.
Env.triggerNet('QBCore:Client:OnPlayerLoaded', 65535, { job = { name = 'mechanic', grade = 0 } })
check(Framework.GetPlayerJob().name == 'mechanic', 'a wrapped playerData resolves the job under .job')

-- THE CASE THAT WAS BROKEN. A qbx_core playerData carries a character `name`
-- BESIDE its `job`, so the payload matches both accepted shapes at once. Read
-- the other way round -- `data.name and data or data.job` -- it resolves to the
-- whole playerData, whose `.name` is the CHARACTER'S, and the job is dropped.
local qbxShape = { name = 'John Doe', job = { name = 'police', grade = 4 } }
Env.triggerNet('QBCore:Client:OnPlayerLoaded', 65535, qbxShape)
check(Framework.GetPlayerJob().name == 'police',
    'a playerData carrying BOTH a character name and a job resolves to the JOB')
check(Framework.GetPlayerJob().grade == 4, 'including its grade')

-- ============================================================ hostile payloads
-- Every shape a client can put on the wire, and none of them may blank the
-- cache: an unresolvable payload must leave the last good job alone, because a
-- client that cleared it would report "no job" for a player who has one --
-- which reads as a framework bug and is not one.
for _, junk in ipairs({
    nil, 'police', 42, true, {}, { name = '' }, { job = 'police' },
    { name = 'a' .. string.rep('x', 500) },
}) do
    local before = Framework.GetPlayerJob()
    local ok = pcall(Env.triggerNet, 'QBCore:Client:OnJobUpdate', 65535, junk)
    check(ok == true, ('a %s payload does not raise'):format(type(junk)))
    check(Framework.GetPlayerJob() ~= nil, ('and the cached job survives a %s payload'):format(type(junk)))
    if Framework.GetPlayerJob() and before then
        check(Framework.GetPlayerJob().name == before.name,
            ('the job is unchanged by a %s payload'):format(type(junk)))
    end
end

-- The capability the client registers, resolved the way a consumer would.
local capability
for _, entry in ipairs(Env.env.registered) do
    if entry.name == 'CisCoreFramework' then
        capability = exports['cis_core'].CisCoreFramework()
    end
end
check(type(capability) == 'table', 'the client registers the framework capability')
check(capability ~= nil and type(capability.GetPlayerJob) == 'function',
    'and it carries the client methods')
check(capability ~= nil and type(capability.ShowNotification) == 'function',
    'including the client-only one, whose signature has no source')

-- ============================================================== the surface
check(type(Framework.GetPlayerData) == 'function', 'GetPlayerData is exposed')
check(type(Framework.ShowNotification) == 'function', 'ShowNotification is exposed')
check(type(Framework.HasItem) == 'function', 'HasItem is exposed')
check(Framework.IsLoaded() == true, 'the client half reports itself loaded')
check(capability ~= nil and type(capability.IsLoaded) == 'function',
    'and carries IsLoaded, which cis_libs declares on the framework slot for BOTH realms')

-- ShowNotification must never raise, on any framework and with any message --
-- it is the one method every product calls when something goes wrong, so it is
-- the one that cannot be allowed to be the thing that goes wrong.
for _, message in ipairs({ 'hello', '', 'a' .. string.rep('x', 1000) }) do
    local ok = pcall(Framework.ShowNotification, message, 'inform')
    check(ok, 'ShowNotification survives a ' .. #message .. '-character message')
end

Test.report()
Test.raiseIfFailed()