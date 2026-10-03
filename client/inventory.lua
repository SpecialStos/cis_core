-- Client inventory counts, as a cache.
--
-- Three sources write the same table and they disagree in shape, so this file
-- normalises to a flat name -> amount map and nothing downstream knows or cares
-- which provider is running. The map is a HINT: it is a snapshot, it can be
-- stale between updates, and it is never authority for a server-side decision.
--
-- One `counts` table, so this file is stateful and must not be duplicated
-- (COMPATIBILITY.md §10).

local counts = {}

local function setCounts(items)
    counts = {}
    if type(items) ~= 'table' then
        return
    end
    for name, amount in pairs(items) do
        counts[name] = amount or 0
    end
end

-- The snapshot arrives on a name cis_libs owns and fires. Listening for it
-- here is correct and is not a boundary violation: the NAME belongs to the
-- library, and a product consuming an event is exactly what it is for. What
-- would be a violation is TRIGGERING it, which is why the push side lives in
-- cis_libs's PublishInventory and only there.
RegisterNetEvent('cis_libs:client:inventory', function(items)
    setCounts(items)
end)

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then
        return
    end
    exports['cis_libs']:RequestInventorySync()
end)

local function inventoryType()
    return CoreLibs.clientFramework().Inventory or 'typical'
end

-- ox_inventory exports two different shapes depending on the build, so both are
-- tried before giving up. Failing either one is not an error: a server that has
-- ox_inventory running with a different permission set just leaves the pushed
-- snapshot as the answer.
local function snapshotOx()
    if GetResourceState('ox_inventory') ~= 'started' then
        return
    end
    local items
    local ok, result = pcall(function()
        return exports.ox_inventory:GetPlayerItems()
    end)
    if ok and type(result) == 'table' then
        items = result
    else
        ok, result = pcall(function()
            return exports.ox_inventory:Search('slots')
        end)
        if ok then
            items = result
        end
    end
    if type(items) ~= 'table' then
        return
    end
    setCounts(CisNormalize.itemSnapshot(items))
end

AddEventHandler('ox_inventory:updateInventory', function()
    if inventoryType() == 'ox_inventory' then
        snapshotOx()
    end
end)

RegisterNetEvent('QBCore:Player:SetPlayerData', function(data)
    if not data or not data.items then
        return
    end
    setCounts(CisNormalize.itemSnapshot(data.items))
end)

-- 0, never nil. A consumer comparing against nil decides a player has no
-- items; one comparing against 0 decides the same thing, and only the second
-- is the truth.
function InventoryCount(item)
    return counts[item] or 0
end

function InventoryHas(item, amount)
    return exports['cis_libs']:InventoryCount(item) >= (amount or 1)
end

-- The client half of the same capability. Method names match the `inventory`
-- slot in cis_libs' registry, and the two realms differ only in the leading
-- src: a client has no player to name.
exports('CisCoreInventoryClient', function()
    return {
        Count = InventoryCount,
        Has = InventoryHas,
    }
end)

-- Registered once cis_libs is ready and the config has landed, for the same
-- reason everything else here waits: the counts come from a snapshot the server
-- pushed, and a registration that beats it answers 0 for the whole session.
CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then
        print('cis_core: cis_libs never became ready; the client inventory service will not register')
        return
    end
    exports['cis_libs']:RegisterCapability('inventory', 'cis_core:CisCoreInventoryClient')
end)
