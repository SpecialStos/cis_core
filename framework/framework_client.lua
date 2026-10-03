-- Client-side framework bridge. The mirror of framework_server.lua.
--
-- IT USED TO BE A MIRROR OF EVERYTHING EXCEPT THE DETECTION, and the difference
-- was a live bug rather than a style choice. The server half probed
-- `GetCoreObject` and fell back to `GetPlayer`; this file had no such fallback,
-- so on a qbx_core that removed `GetCoreObject` it printed one line, fell
-- through to standalone, and the qbx_core event registrations at the bottom
-- never ran -- meaning `cis_libs:jobUpdated` never fired on the client. The two
-- halves disagreed on precisely the server where qbx_core was configured, and
-- nothing errored: notifications quietly fell back to the native feed and job
-- tracking simply never started.
--
-- There was no test over this file at all, which is how a divergence survives
-- for years.
--
-- The fix is the one line at the top of detect(). The DECISION is made by
-- cis_libs:DetectFramework, which is the same pure, unit-tested function the
-- server half calls, over the same ordered table. What stays here is the part
-- that genuinely differs between realms: how to reach the chosen framework's
-- core object. The client has a local player and no server id; the server has
-- the reverse. Neither is a copy of the other and neither should be.

FrameworkLoaded = false
Framework = {}
-- The redacted config, fetched once. NOT a global: `Config` was a global in
-- cis_libs's client state, and a global here would be a second `Config` in the
-- same VM meaning something subtly different -- which is exactly the kind of
-- name that gets read by the wrong file three months from now. It is a local,
-- populated inside detect() because fetching it blocks on readiness and file
-- scope runs before any thread can yield.
local Config = {}
local PlayerJob = nil
local provider = 'NONE'
local QBCore, ESX, QBX

-- Same 50ms/5s shape as the server half, for the same reason: a boot-path wait
-- for another resource, where the only question is "has it started yet".
local function waitResource(name, timeout)
    local deadline = GetGameTimer() + (timeout or 5000)
    while GetResourceState(name) ~= 'started' and GetGameTimer() < deadline do
        Wait(50)
    end
    return GetResourceState(name) == 'started'
end

local function detect()
    Config = CoreLibs.clientConfig()
    local framework = Config.Framework or {}
    -- The same call the server makes, with the same arguments shape. Passing the
    -- CONFIGURED name through is what makes an operator's explicit choice win
    -- over detection, and passing the custom adapter through is what lets an
    -- operator wire up a framework this library has never heard of.
    local choice = exports['cis_libs']:DetectFramework(framework.Type, framework.Custom)

    if choice.name == 'QBCORE' then
        if waitResource('qb-core', 5000) then
            local ok, core = pcall(function()
                return exports['qb-core']:GetCoreObject()
            end)
            if ok and core then
                QBCore = core
                provider = 'QBCORE'
                Config.Framework.Type = 'QBCORE'
                return
            end
            print(('cis_core: qb-core is running but GetCoreObject failed (%s)'):format(choice.reason or ''))
        end
    elseif choice.name == 'QBOX' then
        if waitResource('qbx_core', 5000) then
            -- qbx_core REMOVED GetCoreObject in 1.9. Probing only for it makes
            -- this branch fail on every current qbx_core. The server half had
            -- carried the fallback for a long time; this one had not.
            local ok, core = pcall(function()
                return exports.qbx_core:GetCoreObject()
            end)
            if ok and core then
                QBX = core
                QBCore = core
                provider = 'QBOX'
                Config.Framework.Type = 'QBOX'
                return
            end
            -- Fall back to the export a current qbx_core actually has. Calling
            -- a missing export raises; calling a present one with a bad id
            -- returns nil, so the pcall is an honest existence test rather
            -- than a guess.
            local hasGetPlayer = pcall(function()
                return exports.qbx_core:GetPlayer(0)
            end)
            if hasGetPlayer then
                provider = 'QBOX'
                Config.Framework.Type = 'QBOX'
                return
            end
            print('cis_core: qbx_core is started but exposes neither GetCoreObject nor GetPlayer; '
                .. 'treating it as unusable')
        end
    elseif choice.name == 'ESX' then
        if waitResource('es_extended', 5000) then
            -- Current ESX: ask for the export. Legacy ESX has no export, so the
            -- event below is the only route, and splitting on the CONFIGURED
            -- name rather than probing is what keeps a current build from
            -- waiting three seconds for an event it would answer immediately.
            if string.upper(framework.Type or '') == 'ESX-LEGACY' then
                local ok, obj = pcall(function()
                    return exports['es_extended']:getSharedObject()
                end)
                if ok then
                    ESX = obj
                end
            else
                local ok, obj = pcall(function()
                    return exports['es_extended']:getSharedObject()
                end)
                if ok and obj then
                    ESX = obj
                end
            end
            if not ESX then
                local deadline = GetGameTimer() + 3000
                while ESX == nil and GetGameTimer() < deadline do
                    TriggerEvent('esx:getSharedObject', function(obj)
                        ESX = obj
                    end)
                    Wait(50)
                end
            end
            if ESX then
                provider = 'ESX'
                Config.Framework.Type = 'ESX'
                return
            end
        end
    elseif choice.name == 'NONE' then
        provider = 'NONE'
        Config.Framework.Type = 'NONE'
        print(('cis_core: no framework in use (%s)'):format(choice.reason or 'none configured'))
        return
    end

    print('cis_core: framework provider unavailable; using standalone mode')
    provider = 'NONE'
    Config.Framework.Type = 'NONE'
end

-- nil when the framework has not published data yet, which on a fresh connect
-- is normal rather than exceptional. Every caller above checks before using it.
function Framework.GetPlayerData()
    if provider == 'QBCORE' or provider == 'QBOX' then
        -- The QBX path only fires on a qbx_core that still published a core
        -- object with GetPlayerData on it. Note the consequence: when QBX is
        -- nil this falls through to the QBCore branch, which also has nothing,
        -- so the result is nil -- and OnPlayerLoaded below bails on exactly
        -- that, so `cis_libs:playerLoaded` does not fire either. Read together
        -- with the header, that is the whole of the qbx_core problem.
        if provider == 'QBOX' and QBX and QBX.GetPlayerData then
            return QBX.GetPlayerData()
        end
        if QBCore and QBCore.Functions then
            return QBCore.Functions.GetPlayerData()
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        return ESX.GetPlayerData()
    end
    return nil
end

-- The framework's job-change event. It used to be republished on the library's
-- own name with a LOCAL TriggerEvent, which meant each client derived
-- `cis_libs:jobUpdated` from its own framework event rather than being told.
--
-- The server broadcasts that name now -- cis_libs owns it and fires it, from
-- PublishJobUpdate -- so a client is TOLD. That is the better shape: one
-- server-side decision, one event, and a client whose framework events fire at
-- a different moment from everyone else's still ends up consistent, because it
-- is listening to the same wire rather than re-deriving the same conclusion.
--
-- The local copy is this client's answer to GetPlayerJob, and it is set from
-- the broadcast. The framework is not asked on demand because its player data
-- is only valid while a character is loaded.
RegisterNetEvent('cis_libs:jobUpdated', function(job)
    if type(job) == 'table' then
        PlayerJob = job
    end
end)

RegisterNetEvent('cis_libs:playerLoaded', function(job)
    if type(job) == 'table' and job.name then
        PlayerJob = job
    end
end)

function Framework.GetPlayerJob()
    return PlayerJob
end

-- The two handlers the framework's own client events are registered against.
--
-- They were REFERENCED and never defined. Every `RegisterNetEvent` below passed
-- a nil handler, so on a QBCore, qbx_core or ESX server the client received
-- `QBCore:Client:OnJobUpdate`, `qbx_core:client:onJobUpdate`, `esx:setJob` and
-- the three playerLoaded events and discarded every one of them. The job only
-- ever moved when the SERVER happened to broadcast `cis_libs:jobUpdated`, so a
-- job change the server did not originate -- which is the common case, since a
-- job change usually starts on the client -- left this client answering with a
-- stale job, and nothing anywhere said so.
--
-- Both do what the broadcast handlers above do: take the job, ignore anything
-- that is not one. The frameworks differ in the shape they send, so each reads
-- its own argument rather than assuming a shared one:
--
--   esx:setJob(job, lastJob)                      -> the job itself
--   QBCore:Client:OnJobUpdate(job)                -> the job itself
--   qbx_core:client:onJobUpdate(job)              -> the job itself
--   esx:playerLoaded(playerData, isNew, skin)     -> playerData, job under .job
--   QBCore:Client:OnPlayerLoaded(playerData)       -> playerData, job under .job
--   qbx_core:client:playerLoaded(playerData)       -> playerData, job under .job
--
-- Taking only the first shape would have made every playerLoaded event a no-op,
-- which is the same bug the nil handlers were.
function Framework.UpdatePlayerJob(job)
    if type(job) == 'table' then
        PlayerJob = job
    end
end

function Framework.OnPlayerLoaded(data)
    if type(data) ~= 'table' then
        return
    end
    local job = data.name and data or data.job
    if type(job) == 'table' and job.name then
        PlayerJob = job
    end
end

-- The framework's own notification, and the native feed as the last resort.
-- The native fallback is not dead code: it is what a server in standalone mode
-- gets, and it is why notifications work at all on a server where detection
-- failed. The QBOX branch reaches the qbx_core export when no core object was
-- captured, which is the current-build case.
function Framework.ShowNotification(message, kind)
    if provider == 'QBCORE' or provider == 'QBOX' then
        if QBCore and QBCore.Functions and QBCore.Functions.Notify then
            QBCore.Functions.Notify(message, kind)
            return
        end
        if GetResourceState('qbx_core') == 'started' then
            pcall(function()
                exports.qbx_core:Notify(message, kind or 'inform')
            end)
            return
        end
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        ESX.ShowNotification(message)
        return
    end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(tostring(message))
    EndTextComponentThefeedPostTicker(false, false)
end

-- There was a second definition of this function immediately below the one
-- above, which forwarded to `exports['cis_libs']:Notify`, and cis_libs's Notify
-- forwards back to the `framework` capability's ShowNotification. The second
-- definition won, so the pair was one unbounded cross-resource recursion
-- waiting for the client capability to be registered. It stayed latent only
-- because the client never registered that capability -- which is its own bug,
-- and the reason every notification on a configured server fell through to the
-- native GTA feed instead of the framework's own UI. Both are fixed: this is
-- the one and only definition, and the capability below is registered.

-- Callback style, not the library's await style, because this is the shape a
-- framework consumer already writes. The timeout and the rate limit come free
-- from server/callback.lua; this only exists to name the shape.
function Framework.TriggerServerCallback(name, cb, ...)
    exports['cis_libs']:TriggerLibCallback(name, cb, ...)
end

-- Client-side count, which is the CLIENT's view of its own inventory. The
-- server keeps its own count for authority; this is a display concern and the
-- two are allowed to disagree briefly.
function Framework.HasItem(item, amount)
    return exports['cis_libs']:InventoryHas(item, amount or 1)
end

-- Three paths, and the order is a preference order: the framework's own spawn
-- when it has one (it handles plate, state bags and ownership), then the
-- library's. The native path runs in a thread because RequestModelTimeout
-- yields, and a spawn that cannot load its model reports 0 rather than
-- skipping the callback -- a caller waiting on a vehicle handle has to be
-- woken either way.
function Framework.CreateVehicle(model, coords, heading, cb)
    local function finish(vehicle)
        if vehicle and vehicle ~= 0 then
            SetEntityHeading(vehicle, heading or 0.0)
            SetVehicleOnGroundProperly(vehicle)
        end
        if cb then
            cb(vehicle)
        end
    end
    if provider == 'QBCORE' and QBCore and QBCore.Functions and QBCore.Functions.SpawnVehicle then
        QBCore.Functions.SpawnVehicle(model, finish, coords, true)
        return
    end
    if (provider == 'ESX' or provider == 'ESX-LEGACY') and ESX and ESX.Game and ESX.Game.SpawnVehicle then
        ESX.Game.SpawnVehicle(model, coords, heading, finish)
        return
    end
    CreateThread(function()
        -- 5s to load a model. Longer than the native default because a cold
        -- stream on a busy server is the case this path exists for, and a
        -- caller that gets 0 has to handle a missing vehicle.
        local loaded, hash = RequestModelTimeout(model, 5000)
        if not loaded then
            finish(0)
            return
        end
        local vehicle = CreateVehicle(hash, coords.x, coords.y, coords.z, heading or 0.0, true, false)
        -- Released immediately after the spawn. Holding it would keep the model
        -- resident for the life of the session, and nothing here needs it again.
        SetModelAsNoLongerNeeded(hash)
        finish(vehicle)
    end)
end

-- A server round trip, not a local count. The client's own inventory does not
-- know who else is online, and a dispatch balance must not be decided by what
-- one player can see.
function Framework.GetOnlineJobCount(jobs, cb)
    exports['cis_libs']:TriggerLibCallback('cis_libs:getOnlineJobCount', cb, jobs)
end

exports('CisCoreFrameworkNotify', function(message, kind)
    exports['cis_libs']:Notify(message, kind)
end)

-- Same shape as the server export, and the same belt-and-braces second wait:
-- the thread above sets FrameworkLoaded before it registers the listeners, so
-- a successful ready wait already implies the flag is set and the loop exits
-- immediately. 15s total, not 30s.
exports('CisCoreFramework', function()
    if not exports['cis_libs']:WaitReady(15000) then
        return Framework
    end
    local deadline = GetGameTimer() + 15000
    while not FrameworkLoaded and GetGameTimer() < deadline do
        Wait(50)
    end
    return Framework
end)

-- Client startup, and the order is the contract.
--
-- The ready gate is checked FIRST, unlike the server half. A client that
-- failed readiness must not go on to probe for a framework and register
-- listeners: the library has already told the player it is not working, and a
-- half-attached bridge on top of that produces errors the player cannot
-- explain. The early return still sets FrameworkLoaded so GetFramework stops
-- waiting on a thread that has already given up.
CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then
        FrameworkLoaded = true
        return
    end
    detect()
    FrameworkLoaded = true
    -- The CLIENT half of the framework capability, and it was never registered.
    -- The server has registered `framework` since the split; the client had
    -- only `inventory`, so `CisRegistry.has('framework')` was false on the
    -- client and every `Cis.framework` call fell through to the native GTA
    -- feed. A server's own notification UI was unreachable from every consumer,
    -- and `exports['cis_libs']:GetFramework()` on the client waited 15s for a
    -- capability that was never going to arrive.
    --
    -- Registered AFTER detect() and after the duplicate ShowNotification was
    -- removed: while that duplicate existed, registering this would have turned
    -- every notification into Notify -> ShowNotification -> Notify.
    exports['cis_libs']:RegisterCapability('framework', 'cis_core:CisCoreFramework')
    -- Read the job once, immediately, so a consumer that asks before the
    -- framework's first event still gets an answer. The listeners below then
    -- keep it current.
    local playerData = Framework.GetPlayerData()
    if playerData and playerData.job then
        PlayerJob = playerData.job
    end
    -- BOTH ecosystems' events are registered for QBOX, not just the qbx_core
    -- pair. qbx_core still fires the QBCore events for compatibility, and a
    -- client that listened only for `qbx_core:client:*` would work on a current
    -- build and silently stop updating on a transitional one. Registering
    -- four listeners for one job is cheaper than the bug.
    --
    -- The whole block is unreachable on a qbx_core that removed GetCoreObject,
    -- because provider is 'NONE' by then. See the header.
    if provider == 'QBCORE' or provider == 'QBOX' then
        RegisterNetEvent('QBCore:Client:OnJobUpdate', Framework.UpdatePlayerJob)
        RegisterNetEvent('QBCore:Client:OnPlayerLoaded', Framework.OnPlayerLoaded)
        RegisterNetEvent('qbx_core:client:playerLoaded', Framework.OnPlayerLoaded)
        RegisterNetEvent('qbx_core:client:onJobUpdate', Framework.UpdatePlayerJob)
    elseif provider == 'ESX' or provider == 'ESX-LEGACY' then
        RegisterNetEvent('esx:setJob', Framework.UpdatePlayerJob)
        RegisterNetEvent('esx:playerLoaded', Framework.OnPlayerLoaded)
    end
end)
