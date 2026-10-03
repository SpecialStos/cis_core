-- Scenario: a current ESX, reached through its export.
--
-- Two findings from reading esx_core's source are pinned here, because both are
-- the kind that look correct and are not:
--
--   * `ESX.GetPlayers` IS the FiveM native (`ESX.GetPlayers = GetPlayers` in
--     es_extended/server/functions.lua), so it answers an array of SOURCE ID
--     STRINGS. Returning it from the framework capability handed consumers
--     strings on ESX and player objects on QBCore -- one method, two shapes.
--
--   * `xPlayer.get('metadata')` is ALWAYS nil. The xPlayer keeps `variables`
--     (what get/set touch) and `metadata` (what getMeta/setMeta touch) in two
--     separate tables, so `get('metadata')` asks for a key nothing writes.
--     `NormalizedPlayer().metadata` was nil on every ESX server while looking
--     present and correctly typed.

local Env = FrameworkEnv
Env.installCisLibs()

Config = {
    Framework = { Type = 'AUTO', Inventory = 'typical', Database = { Type = 'AUTO' } },
    Printing = { Debug = false, UseDiscordLogs = false },
}

Env.resource('es_extended', '1.15.2')

-- The xPlayer shape, from es_extended/server/classes/player.lua. Built with
-- BOTH tables, because that is the point: `variables` has no `metadata` key and
-- `metadata` is a real table.
local function xPlayer(src)
    local p = Env.esxPlayer()
    p.source = src
    p.variables = { firstName = 'John', lastName = 'Doe' }
    p.metadata = { handcuffed = false, inLastCar = 0 }
    p.getMeta = function()
        return p.metadata
    end
    return p
end

local players = { [1] = xPlayer(1), [2] = xPlayer(2) }
Env.export('getSharedObject', function()
    return {
        GetPlayerFromId = function(src) return players[tonumber(src)] end,
        -- The native, verbatim: an array of SOURCE ID STRINGS.
        GetPlayers = function() return { '1', '2' } end,
    }
end)
Env.connect({ 1, 2 })

dofile('framework/framework_server.lua')
Env.runThreads()

Test.begin('esx')
local check = Test.check
Test.note(('detected=%s connected=%d'):format(tostring(Config.Framework.Type), #Env.env.players))

-- ------------------------------------------------------------------ detect
check(Config.Framework.Type == 'ESX', 'es_extended is detected as ESX')

-- --------------------------------------------------------------- the surface
check(CisFramework.GetPlayer(1) ~= nil, 'GetPlayer returns the xPlayer')
check(CisFramework.GetPlayer(99) == nil, 'and nil for a source that is not a player')

-- THE FINDING. Two shapes from one method is the bug; this is the assertion
-- that fails if it comes back.
local list = CisFramework.GetPlayers()
check(type(list) == 'table', 'GetPlayers returns a table')
check(#list == 2, 'with one entry per connected player')
check(type(list[1]) == 'table', 'each entry is a PLAYER OBJECT, not a source id')
check(list[1] ~= nil and list[1].identifier == 'license:0000', 'and it is an xPlayer')
check(list[2] ~= nil and list[2].source == 2, 'the second is the second player')

-- THE OTHER FINDING. metadata, on a framework that keeps it somewhere get()
-- never looks.
local n = CisFramework.NormalizedPlayer(1)
check(n.metadata ~= nil, 'NormalizedPlayer.metadata is populated on ESX')
check(n.metadata ~= nil and n.metadata.handcuffed == false,
    'and it is the REAL metadata table, not an empty stand-in')
check(n.name == 'JohnDoe', 'the name comes from getName(), since ESX has no charinfo')
check(n.money.cash == 500, 'money is the account list, flattened')
check(n.money.bank == 1200, 'including every account')

-- A framework with no metadata concept at all must answer nil rather than {},
-- because only one of those is something a caller can act on.
players[2].getMeta = nil
players[2].metadata = nil
check(CisFramework.NormalizedPlayer(2).metadata == nil,
    'a player on a build with no metadata concept answers nil, not an empty table')

-- Money. ESX's addAccountMoney RAISES on an unknown account in 1.8.5+, so the
-- bridge has to be answering from the pcall rather than from a return value.
check(CisFramework.GiveMoney(1, 100, 'cash') == true, 'GiveMoney answers true for a real account')
check(CisFramework.GiveMoney(1, 100, 'not_an_account') == false,
    'and false for one ESX would raise on, rather than raising here')
check(CisFramework.RemoveMoney(99, 100, 'cash') == false, 'false for a source with no player')

Test.report()
Test.raiseIfFailed()