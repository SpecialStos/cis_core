-- Scenario: the inventory service, and the argument order that hides inside it.
--
-- Every branch of InventoryAdd passes metadata to a DIFFERENT POSITION, because
-- the four drivers disagree about what sits between `amount` and `metadata`. It
-- is the kind of thing that works -- the item appears, the count is right -- and
-- quietly stores the metadata as a slot name, or drops it, or writes it as
-- `false`. Nothing errors and nothing is visibly wrong until a product reads the
-- metadata back.
--
-- So this scenario records every call each driver receives and asserts the
-- ARGUMENTS, not just that the item arrived.

local Env = FrameworkEnv
Env.installCisLibs()

Config = {
    Framework = { Type = 'AUTO', Inventory = 'ox_inventory', Database = { Type = 'AUTO' } },
    Printing = { Debug = false, UseDiscordLogs = false },
}
-- cis_libs forwards to the inventory capability, which is the one under test.
Env.export('InventoryAdd', function(src, item, amount, metadata)
    return exports['cis_core'].CisCoreInventory().Add(src, item, amount, metadata)
end)
Env.export('InventoryRemove', function(src, item, amount)
    return exports['cis_core'].CisCoreInventory().Remove(src, item, amount)
end)
Env.export('InventoryHas', function(src, item, amount)
    return exports['cis_core'].CisCoreInventory().Has(src, item, amount)
end)
Env.export('PublishInventory', function() return true end)

dofile('server/authority.lua')
dofile('server/inventory.lua')

local service = exports['cis_core'].CisCoreInventory()

Test.begin('inventory')
local check = Test.check

-- What each driver was called with, in order.
-- `table.pack` rather than a literal list: it keeps the NIL positions, so an
-- assertion can tell "the driver was passed nothing here" from "the call had
-- fewer arguments" -- which is the whole question when the argument in that
-- position is metadata.
local received = {}
local function record(...)
    received[#received + 1] = table.pack(...)
end

-- =============================================================== ox_inventory
-- metadata is the FOURTH argument. There is no slot parameter between them.
Env.export('AddItem', function(...) record('ox', ...) return true end)
Env.export('GetInventoryItems', function(src)
    return { { name = 'water', amount = 2 }, { name = 'bread', count = 1 }, { name = 'empty', amount = 0 } }
end)
Env.resource('ox_inventory')
Env.export('Search', function() return 3 end)

local ok = service.Add(1, 'water', 5, { quality = 'clean' })
check(ok == true, 'ox_inventory accepts an add')
check(received[1][1] == 'ox', 'the ox_inventory branch was taken')
check(received[1][2] == 1, 'with the source first')
check(received[1][3] == 'water', 'then the item')
check(received[1][4] == 5, 'then the amount')
check(received[1][5] ~= nil and received[1][5].quality == 'clean',
    'and metadata in the FOURTH position, where ox_inventory reads it')

-- The snapshot, flattened. `count` is ox_inventory's field, `amount` is
-- everyone's else, and an entry with a zero amount is present at zero.
local snap = service.Snapshot(1)
check(snap.water == 2, 'the snapshot reads `amount`')
check(snap.bread == 1, 'and `count`, which ox_inventory uses')
check(snap.empty == 0, 'and an entry at zero stays zero rather than disappearing')

check(service.Count(1, 'water') == 3, 'Count prefers the driver when it is started')
check(service.Has(1, 'water', 3) == true, 'Has is a comparison against Count, not a second code path')
check(service.Has(1, 'water', 4) == false, 'and answers false above the count')

-- ============================================== the degradation that matters
-- The documented behaviour: a named inventory that is not STARTED falls through
-- to the framework rather than erroring. "HasItem always says no" is the
-- symptom; it is not a crash.
Env.resource('ox_inventory', nil)
Env.env.resources['ox_inventory'] = 'stopped'
Env.export('GetCoreObject', function()
    return { Functions = {
        GetPlayer = function(src) return tonumber(src) == 1 and Env.qbPlayer() or nil end,
    } }
end)
CisFramework = { GetPlayer = function(src) return tonumber(src) == 1 and Env.qbPlayer() or nil end }

received = {}
local fell, fellWhy = service.Add(1, 'water', 5, { quality = 'clean' })

-- AND IT SAYS WHY, which is the part this scenario exists for. Current QBCore
-- has no item API at all -- `AddItem` is absent from its `varargMethods` list
-- and undefined on the player -- so the framework fallback that the code's own
-- comment called "a working default for QBCore and ESX" answers bare false on
-- the most common framework. A bare false reads as "declined"; the reason
-- names the config key and the value that fixes it.
check(fell == false, 'a framework with no item API refuses the add')
check(type(fellWhy) == 'string' and fellWhy:find('Inventory', 1, true) ~= nil,
    'and the reason names the setting to change')
check(type(fellWhy) == 'string' and fellWhy:find('ox_inventory', 1, true) ~= nil,
    'and the value that fixes it')
check(#received == 0, 'the stopped driver is never called')

-- COUNT still works, because it walks the table rather than calling a method --
-- which is why the original symptom was "money moves but the item never
-- arrives" rather than an obvious breakage.
-- Count must FALL THROUGH, and this is the assertion that had been failing.
-- `oxCount` used to return 0 when ox_inventory was stopped, so this returned 0
-- for every item for every player -- the one branch in this file that did not
-- apply the dispatch rule its own header mandates.
check(service.Count(1, 'water') == 2,
    'Count falls through to the framework walk when the configured inventory is not started')
check(service.Count(1, 'nothing') == 0, 'and answers 0 -- never nil -- for an item nobody has')

-- ================================================================= Remove
-- The positional differences again, and Remove has one more shape than Add: a
-- driver takes (src, item, amount) with NO metadata parameter at all, so a
-- fifth argument would be read as something else entirely.
Env.export('RemoveItem', function(...) record('ox-remove', ...) return true end)
Env.resource('ox_inventory')
received = {}
check(service.Remove(1, 'water', 2) == true, 'Remove is accepted')
check(received[1][2] == 1 and received[1][3] == 'water' and received[1][4] == 2,
    'and passes source, item and amount in that order')
check(received[1].n == 4, 'with NO metadata parameter, because ox_inventory RemoveItem has none')

-- ================================================================ the rest
-- The shape of the capability itself, because this is what cis_libs forwards to.
for _, name in ipairs({ 'Count', 'Add', 'Remove', 'Has', 'Snapshot' }) do
    check(type(service[name]) == 'function', ('the capability exposes %s'):format(name))
end

-- A player the framework does not know must be refused, not invented.
-- Back to the framework path, which is the one that can refuse for want of a
-- player. With ox_inventory started, `Add(99, ...)` is the driver's business
-- and the driver's answer is what it is.
Env.env.resources['ox_inventory'] = 'stopped'
local noPlayer, noPlayerWhy = service.Add(99, 'water', 1)
check(noPlayer == false, 'a source with no player is refused rather than silently dropped')
check(type(noPlayerWhy) == 'string' and noPlayerWhy:find('99', 1, true) ~= nil,
    'and the reason names the source it could not find')
check(service.Count(99, 'water') == 0, 'and counts zero for it')

Test.report()
Test.raiseIfFailed()