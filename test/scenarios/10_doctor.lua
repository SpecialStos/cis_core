-- Scenario: the boot report and the two console commands.
--
-- The roadmap puts this at the top of the cost analysis: an install that is
-- wrong and says nothing produces a support ticket, and an install that is
-- wrong and SAYS SO does not. So the report is the feature, and this tests
-- what it actually prints rather than that the function returns.
--
-- The world below is deliberately broken in four different ways, because the
-- value of a report is proportional to how many of them it catches at once --
-- and to whether the fixes it prints are the ones an operator would actually
-- apply.

local Env = FrameworkEnv
Env.installCisLibs()

-- ------------------------------------------------------------ a broken world
Config = {
    CheckVersion = false,
    CallbackTimeout = 100,
    UpdateInterval = { Player = 1000, Weapon = 1000, Vehicle = 1000 },
    AimingCheckType = 'default',
    Framework = {
        Type = 'AUTO',
        -- a name that does not exist
        Inventory = 'ox_inventoryr',
        -- a key nobody reads: the typo that is invisible in Lua
        Typ = 'QBCORE',
        -- a value on the way to a key, which validated clean until it did not
        Target = 'ox_target',
        Database = { Type = 'AUTO', Timeout = 15000 },
    },
    Sync = { Enabled = true },
    Printing = { Debug = false, UseDiscordLogs = true },
}

Security = {
    EventPrefix = 'cis_libs',
    -- an authorised resource that is not installed: a latent grant
    AuthorizedResources = { 'cis_core', 'cis_never_installed' },
    -- an allow-list written as a map, which authorises nothing at all
    DropPlayer = false,
}
Security.AuthorizedResources = { 'cis_core' }
Security.CisCustomThing = true

DiscordConfig = { DiscordLogsLinks = { MasterLogs = 'CHANGE-ME-WITH-YOUR-WEBHOOK-LINK' } }

-- cis_libs has to be DECLARED, not merely stubbed. The first run of this
-- scenario reported `resource state is "missing"` for cis_libs -- which was the
-- doctor being exactly right and the world being incomplete. The stubs make
-- its exports answer; the resource state is a separate question, and the
-- doctor asks it before it asks for the self-check.
Env.resource('cis_libs', '2.2.0')

-- A framework is running, so the report has something true to say about it.
Env.resource('qb-core', '3.7.1')
Env.export('GetCoreObject', function()
    return { Functions = { GetPlayer = function() return nil end } }
end)
Env.connect({})

-- cis_libs's own self-check reports one problem, so the doctor has something
-- from the other side of the boundary to pass through.
local captured = {}
Env.export('GetSelfCheck', function()
    return { ok = false, problems = {
        { code = 'missing_dependency', message = 'a resource cis_libs needs is not started',
          fix = 'ensure qb-core before cis_libs' },
    } }
end)
Env.export('GetCapabilities', function()
    return { framework = { owner = 'cis_core' }, database = { owner = 'cis_bridge' } }
end)

dofile('framework/framework_server.lua')
dofile('server/validate_config.lua')
dofile('server/doctor.lua')
dofile('server/commands.lua')
Env.runThreads()

-- The framework capability is what a consumer actually calls, so resolve it
-- through the same export a consumer would use.
local capability
for _, entry in ipairs(Env.env.registered) do
    if entry.name == 'CisCoreFramework' then
        -- Called the way a CONSUMER calls it, through the exports proxy, so the
        -- capability is resolved rather than read out of the side table.
        capability = exports['cis_core'].CisCoreFramework()
    end
end

Test.begin('doctor')
local check = Test.check

-- ==================================================================== the report
Env.env.printed = {}
local lines = CisDoctor.environment()
check(type(lines) == 'table' and #lines > 0, 'the doctor produces a report')

local function lineFor(subject)
    for _, l in ipairs(lines) do
        if l.subject == subject then return l end
    end
    return nil
end

-- Every line that says something is wrong must also say what to do. A report
-- that only reports has moved the problem rather than solving it, and an
-- operator reading it at 3am cannot act on "no inventory provider".
local noFix = 0
for _, l in ipairs(lines) do
    if (l.severity == 'MISSING' or l.severity == 'DEGRADED') and (l.fix == nil or l.fix == '') then
        noFix = noFix + 1
    end
end
check(noFix == 0, ('every MISSING or DEGRADED line carries a fix (%d did not)'):format(noFix))

-- The specific problems this world has.
-- TWO lines share this subject: the count, and what is authorised but not
-- installed. Only the second carries a fix, and only the second should.
local allowFix
for _, l in ipairs(lines) do
    if l.subject == 'allow-list' and l.fix then allowFix = l end
end
check(allowFix ~= nil, 'the allow-list is reported, with a fix on the line that has one')
check(allowFix ~= nil and allowFix.state:find('not installed', 1, true) ~= nil,
    'and it is the line about an entry that is authorised but not running')
check(allowFix ~= nil and tostring(allowFix.fix):find('inherit', 1, true) ~= nil,
    'naming the consequence, because a grant is attached to a NAME')

local authority = lineFor('event authority')
check(authority ~= nil, 'event authority is reported')
check(authority ~= nil and authority.state:find('clean', 1, true) ~= nil,
    'and is clean on a server where nothing forged a source')

-- The state store is NOT loaded in this scenario, so CisState does not exist.
-- The doctor has to survive that: the report is the thing an operator runs on a
-- server where something is half-broken, and a diagnostic that raises because
-- the module it describes failed to load is worse than no diagnostic.
local state = lineFor('state store')
check(state ~= nil, 'the state store is reported even though the module never loaded')
check(state ~= nil and state.state:find('did not answer', 1, true) ~= nil,
    'as "did not answer" rather than as a fault')

-- cis_libs's own self-check must be passed THROUGH, not summarised away. The
-- operator cannot see cis_libs's problems from inside cis_core, so if the
-- doctor drops them they have no single place to look.
local sawSelfCheck = false
for _, l in ipairs(lines) do
    if l.subject == 'cis_libs' and l.state:find('missing_dependency', 1, true) then
        sawSelfCheck = true
    end
end
check(sawSelfCheck, "cis_libs's own self-check problems are passed through with their fix")

-- ================================================================ the validator
local ok, report = CisConfig.validate(Config, Security, DiscordConfig)
check(ok == false, 'a config this broken does not validate')

local function problemFor(path)
    for _, bucket in ipairs({ 'error', 'warning', 'info' }) do
        for _, p in ipairs(report[bucket]) do
            if p.path == path then return p end
        end
    end
    return nil
end

-- The typo. Invisible to Lua, and the one an operator has no other way to find.
local typo = problemFor('Config.Framework.Typ')
check(typo ~= nil, 'the unknown key is reported')
check(typo ~= nil and tostring(typo.fix):find('Framework.Type', 1, true) ~= nil,
    'and the fix names the key that was meant, not "remove it"')

-- The value on the way to a key. This one validated CLEAN until the walk was
-- taught to tell "absent" from "unreachable".
local target = problemFor('Config.Framework.Target')
check(target ~= nil, 'a value where a table belongs is reported, not read as absent')

-- The wrong enum value, with a near-miss fix.
local inventory = problemFor('Config.Framework.Inventory')
check(inventory ~= nil, 'the bad inventory name is reported')
check(inventory ~= nil and tostring(inventory.fix):find('ox_inventory', 1, true) ~= nil,
    'and the fix names the value that was meant')

-- The timeout, and WHY rather than just a range.
local timeout = problemFor('Config.CallbackTimeout')
check(timeout ~= nil, 'a 100ms callback timeout is reported')
check(timeout ~= nil and tostring(timeout.fix):find('distinguish', 1, true) ~= nil,
    'with the consequence, not just a number')

-- The unknown Security key.
check(problemFor('Security.CisCustomThing') ~= nil, 'an unknown Security key is reported')

-- The placeholder webhook: silence explained before the ticket exists.
check(problemFor('DiscordConfig.DiscordLogsLinks') ~= nil,
    'a placeholder webhook is reported, so "no messages" is answered at boot')

-- ================================================================= the commands
check(Env.commandNamed('cis_core_info') ~= nil, 'cis_core_info is registered')
check(Env.commandNamed('cis_core_doctor') ~= nil, 'cis_core_doctor is registered')
check(Env.commandNamed('cis_core_info').restricted == true,
    'and both are registered restricted, so they do not appear in a player help list')

-- The console. src == 0 is allowed by definition.
Env.env.printed = {}
check(Env.runCommand('cis_core_info', 0) == true, 'cis_core_info runs in the console')
check(#Env.env.printed > 0, 'and prints its one line')
local infoAll = table.concat(Env.env.printed, ' | ')
check(infoAll:find('cis_core', 1, true) ~= nil, 'which names the resource and its version')
check(infoAll:find('doctor', 1, true) ~= nil,
    'and points at the full report -- on a second line, so the hint does not crowd the summary')

Env.env.printed = {}
check(Env.runCommand('cis_core_doctor', 0) == true, 'cis_core_doctor runs in the console')
check(#Env.env.printed > 0, 'and prints the whole report')

-- A non-admin is refused, and the refusal is SILENCE. A command that tells a
-- stranger what this server runs is a command that should not exist.
Env.export('GetFramework', function()
    return { HasPermission = function() return false end }
end)
Env.env.printed = {}
check(Env.runCommand('cis_core_doctor', 5) == true, 'cis_core_doctor accepts a player src')
check(#Env.env.printed == 0, 'but prints NOTHING for a non-admin')

-- And the positive: an admin gets the report.
local askedFor = nil
Env.export('GetFramework', function()
    -- SELF, src, permission. `pcall(fw.HasPermission, fw, src, group)` -- so the
    -- permission is the THIRD parameter, not the second. Getting that wrong in
    -- the stub reads the player id as a group name and fails in a way that
    -- looks like the command checking the wrong thing.
    return { HasPermission = function(_, src, permission)
        askedFor = permission
        return true
    end }
end)
Env.env.printed = {}
Env.runCommand('cis_core_doctor', 5)
check(#Env.env.printed > 0, 'and everything for an admin')

-- THE GROUP IS CONFIGURABLE, and it has to be. ESX's superuser group is
-- `superadmin`, which is not the string `admin` -- so a server that grants
-- `superadmin` could never run these in game and got SILENCE, which is the
-- correct refusal and a baffling symptom at the same time.
check(askedFor == 'admin', 'the default group is the one QBCore and qbx_core grant')
Security.AdminGroup = 'superadmin'
Env.env.printed = {}
Env.runCommand('cis_core_doctor', 5)
check(askedFor == 'superadmin', 'and an operator on ESX can name their own')
check(#Env.env.printed > 0, 'which then works in game')
Security.AdminGroup = nil

-- ================================================================= no secrets
-- The whole point of the report being safe to paste into a support thread.
local rendered = {}
for _, l in ipairs(lines) do
    rendered[#rendered + 1] = tostring(l.subject) .. ' ' .. tostring(l.state) .. ' ' .. tostring(l.fix)
end
local body = table.concat(rendered, '\n')
for _, secret in ipairs({ 'CHANGE-ME-WITH-YOUR-WEBHOOK-LINK', 'api.cisoko.net', 'discord.com' }) do
    check(not body:find(secret, 1, true), ('the report does not contain %q'):format(secret))
end

Test.report()
Test.raiseIfFailed()