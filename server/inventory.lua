-- Inventory access, funnelled through one place so the framework differences
-- are resolved once. Every function here is a COUNT or a mutation -- nothing
-- returns a raw inventory object to a consumer, because the shapes differ per
-- resource and a consumer that reads one directly breaks on the next server.
--
-- The dispatch rule, applied identically in every function: take the branch
-- Config.Framework.Inventory names ONLY if that resource is actually started,
-- and otherwise fall through to the next one. Falling through rather than
-- erroring is the whole point -- a server configured for an inventory it has
-- not installed still gets a working (if less accurate) answer instead of a
-- hard failure at the first item check.

local function inventoryType()
    return Config and Config.Framework and Config.Framework.Inventory or 'typical'
end

-- Re-checked per call rather than cached at load. An inventory resource that
-- is stopped and restarted, or one that starts after cis_libs, changes the
-- answer, and a cached `started()` would keep routing to a dead export.
local function started(name)
    return GetResourceState(name) == 'started'
end

local function oxCount(src, item)
    if not started('ox_inventory') then
        return 0
    end
    local count = exports.ox_inventory:Search(src, 'count', item)
    -- 0 rather than nil. Callers compare with >=, and a nil here would raise on
    -- the comparison instead of reading as "does not have it".
    return count or 0
end

-- The two shapes, in order: QBCore/qbx_core keep items on PlayerData, ESX
-- exposes them through a method, and a bare framework object may carry the
-- table directly. All three are read here and nowhere else.
local function playerItems(src)
    if not CisFramework then
        return {}
    end
    local fw = exports['cis_libs']:GetFramework()
    local player = fw and fw.GetPlayer and fw.GetPlayer(src) or nil
    if not player then
        return {}
    end
    if player.PlayerData and player.PlayerData.items then
        return player.PlayerData.items
    end
    if player.getInventory then
        return player.getInventory()
    end
    return player.inventory or {}
end

function InventoryCount(src, item)
    local kind = inventoryType()
    if kind == 'ox_inventory' then
        return oxCount(src, item)
    end
    if kind == 'codem-inventory' and started('codem-inventory') then
        -- Two probes, not one. `GetItemsTotalAmount` is not present on every
        -- codem-inventory build; where it is missing the export call raises
        -- rather than returning nil, so the pcall is what detects it. The
        -- fallback is `HasItem`, which answers a yes/no and is therefore
        -- capped at 1 -- the count is only ever compared with >= 1, but a
        -- caller asking for an exact number gets an answer that is exact only
        -- in the "at least one" direction.
        local ok, result = pcall(function()
            return exports['codem-inventory']:GetItemsTotalAmount(src, item)
        end)
        if ok and type(result) == 'number' then
            return result
        end
        ok, result = pcall(function()
            return exports['codem-inventory']:HasItem(src, item, 1)
        end)
        if ok then
            return result and 1 or 0
        end
    end
    -- The generic walk. Which field holds the name, which holds the amount, and
    -- what an unrecognised entry counts as are all decisions, so they live in
    -- shared/normalize.lua where they are unit tested -- this file's header
    -- records a two-year divergence between the counter and the snapshot that
    -- only a test would have caught.
    return CisNormalize.itemCount(playerItems(src), item)
end

-- A comparison, not a separate call, so "has" can never disagree with "count"
-- by being implemented differently.
function InventoryHas(src, item, amount)
    return InventoryCount(src, item) >= (amount or 1)
end

-- name -> total count, flattened. Consumers ask "how much of X" and never
-- iterate the inventory themselves, which is what keeps the per-resource entry
-- shapes out of every companion resource.
function InventorySnapshot(src)
    local kind = inventoryType()
    if kind == 'ox_inventory' and started('ox_inventory') then
        return CisNormalize.itemSnapshot(exports.ox_inventory:GetInventoryItems(src))
    end
    return CisNormalize.itemSnapshot(playerItems(src))
end

-- The client is told the new state only after the inventory accepted the
-- change. Pushing unconditionally would let a rejected mutation overwrite the
-- client's correct copy with a stale one, and the client has no way to
-- reconcile that -- it trusts this event.
local function pushSnapshot(src)
    exports['cis_libs']:PublishInventory(src)
end

local function typicalPlayer(src)
    local fw = exports['cis_libs']:GetFramework()
    return fw and fw.GetPlayer and fw.GetPlayer(src) or nil
end

-- The branch order below is the fallback chain, and every branch is gated on
-- `started(name)`. That gate is what makes the last `else` a working default
-- rather than a "should not happen": a server that named an inventory it does
-- not have installed lands here and uses the framework's own AddItem, which is
-- the correct answer for QBCore and ESX.
--
-- The positional `nil`/`false` before `metadata` is each resource's own
-- "slot/slotName/target" or "ignore enqueue" argument, not a placeholder this
-- library invented. Passing metadata in that position would store it as a slot
-- name on some resources and silently drop it on others.
function InventoryAdd(src, item, amount, metadata)
    amount = amount or 1
    local kind = inventoryType()
    local ok
    if kind == 'ox_inventory' and started('ox_inventory') then
        ok = exports.ox_inventory:AddItem(src, item, amount, metadata)
    elseif kind == 'codem-inventory' and started('codem-inventory') then
        ok = exports['codem-inventory']:AddItem(src, item, amount, nil, metadata)
    elseif kind == 'qs-inventory' and started('qs-inventory') then
        ok = exports['qs-inventory']:AddItem(src, item, amount, nil, metadata)
    elseif kind == 'qb-inventory' and started('qb-inventory') then
        ok = exports['qb-inventory']:AddItem(src, item, amount, false, metadata)
    else
        local player = typicalPlayer(src)
        if player and player.Functions and player.Functions.AddItem then
            ok = player.Functions.AddItem(item, amount, false, metadata)
        elseif player and player.addInventoryItem then
            ok = player.addInventoryItem(item, amount, metadata)
        else
            ok = false
        end
    end
    if ok then
        pushSnapshot(src)
    end
    return ok
end

function InventoryRemove(src, item, amount)
    amount = amount or 1
    local kind = inventoryType()
    local ok
    if kind == 'ox_inventory' and started('ox_inventory') then
        ok = exports.ox_inventory:RemoveItem(src, item, amount)
    elseif kind == 'codem-inventory' and started('codem-inventory') then
        ok = exports['codem-inventory']:RemoveItem(src, item, amount)
    elseif kind == 'qs-inventory' and started('qs-inventory') then
        ok = exports['qs-inventory']:RemoveItem(src, item, amount)
    elseif kind == 'qb-inventory' and started('qb-inventory') then
        ok = exports['qb-inventory']:RemoveItem(src, item, amount, false)
    else
        local player = typicalPlayer(src)
        if player and player.Functions and player.Functions.RemoveItem then
            ok = player.Functions.RemoveItem(item, amount)
        elseif player and player.removeInventoryItem then
            ok = player.removeInventoryItem(item, amount)
        else
            ok = false
        end
    end
    if ok then
        pushSnapshot(src)
    end
    return ok
end

-- A client asking for a fresh copy. The only handler here that is NOT rate
-- limited meaningfully, because it does no work beyond building a snapshot
-- from data already in memory.

-- Registration deferred to a thread so it happens after every server file has
-- executed, rather than depending on this file's position in fxmanifest
-- relative to whatever else registers callbacks. The cost is a window during
-- resource start in which a client asking for this name gets 'unknown' rather
-- than a number; the alternative is a load-order coupling between files that
-- have no other reason to know about each other.
CreateThread(function()
    exports['cis_libs']:RegisterCallback('cis_libs:inventoryCount', function(src, item)
        return InventoryCount(src, item)
    end)
end)

-- ox_inventory does not emit an event when its contents change, only when a
-- container is opened, so this is the only external signal available to resend
-- the snapshot. Harmless when ox_inventory is not the configured inventory.
--
-- The source goes through CisAuthority like every other handler in this
-- resource, and for the same reason: `ox_inventory:openedInventory` is a name a
-- client can type, and the source here arrives from the payload. The impact is
-- smaller than the job handlers -- the snapshot is pushed to the resolved
-- player rather than to the sender, so the worst a forgery achieves is making
-- an arbitrary player recompute their own inventory -- and "smaller" is not
-- "none", and the rule is not worth breaking in one file for the sake of a
-- cheaper shape in it.
AddEventHandler('ox_inventory:openedInventory', function(payloadSrc)
    local src = CisAuthority.resolveSource(payloadSrc, 'ox_inventory:openedInventory')
    if src then
        pushSnapshot(src)
    end
end)

-- The capability table, registered into cis_libs as `inventory`.
--
-- One export rather than four, because the four names are not four things: they
-- are the inventory SERVICE, and the service is what a consumer talks to. The
-- third-party adapters behind it register separately as `inventoryProvider`, so
-- the normalisation every consumer depends on can be replaced without the
-- adapter, and the adapter without the normalisation.
exports('CisCoreInventory', function()
    return {
        -- Capitalised to match the `inventory` slot declared in cis_libs'
        -- registry, which is the shape both sides agree on.
        Count = InventoryCount,
        Add = InventoryAdd,
        Remove = InventoryRemove,
        Has = InventoryHas,
        Snapshot = InventorySnapshot,
    }
end)
