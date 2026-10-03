-- Tests for the boot-time configuration validator.
--
-- WHAT IS WORTH TESTING HERE, and why it is not "the mock"
--
-- This file is the only part of cis_core that reads operator input, and that is
-- exactly why it is the part worth testing. The failure it exists to prevent --
-- a typo that looks like a working setting -- is invisible to every other test
-- in this repository, because a typo produces a perfectly valid Lua table and a
-- perfectly silent server.
--
-- So the assertions are about the DIAGNOSIS, not about the config: that a wrong
-- value is reported, that the report names the right key, and -- the one that
-- matters most -- that a malformed config produces a sentence instead of a
-- stack trace.

Test.begin('config')
local check = Test.check

-- Every problem in the report, flattened. Tests search this rather than the
-- three buckets separately, because what an operator reads is one list.
local function allProblems(report)
    local out = {}
    for _, bucket in ipairs({ 'error', 'warning', 'info' }) do
        for _, p in ipairs(report[bucket]) do
            -- Copied rather than appended by reference. The report is the thing
            -- being tested elsewhere, and tagging its own entries in place
            -- would let a test change what it is testing.
            out[#out + 1] = {
                code = p.code,
                path = p.path,
                message = p.message,
                fix = p.fix,
                severity = bucket,
            }
        end
    end
    return out
end

local function findProblem(report, path)
    for _, p in ipairs(allProblems(report)) do
        if p.path == path then
            return p
        end
    end
    return nil
end

-- The shipped config, as a shape. Not a copy of configs/master_config.lua: a
-- test that loads the real file is a test that changes meaning every time the
-- defaults are retuned, and what is being asserted here is the validator's
-- behaviour, not the default values.
local function goodConfig()
    return {
        CheckVersion = false,
        CallbackTimeout = 10000,
        UpdateInterval = { Player = 1000, Weapon = 1000, Vehicle = 1000, VehicleProperties = 5000 },
        AimingCheckType = 'default',
        Framework = {
            Type = 'AUTO',
            Inventory = 'ox_inventory',
            Zones = { Enabled = true },
            Target = { Enabled = true, Type = 'ox_target', Debug = false },
            Database = { Type = 'AUTO', Collection = 'cis_migrations', Timeout = 15000 },
        },
        Sync = { Enabled = true },
        Printing = { Debug = false, UseDiscordLogs = false },
    }
end

local function goodSecurity()
    return {
        EventPrefix = 'cis_libs',
        Debug = false,
        AuthorizedResources = { 'cis_keys' },
        DropPlayer = false,
    }
end

-- ============================================================ the happy path
-- A config with no problems at all must produce no problems. A validator that
-- complains about a correct install gets its output ignored within a week, and
-- then it has cost more than it saves.
local ok, report = CisConfig.validate(goodConfig(), goodSecurity())
check(ok, 'a correct config validates clean')
check(report.counts.errors == 0, 'no errors on a correct config')
check(report.counts.warnings == 0, 'no warnings on a correct config')

-- ============================================================ the wrong value
-- The headline case: a value this resource does not accept. It is not an
-- error in Lua, it is not an error in the server, and every branch that reads
-- it falls through to a fallback that behaves like working software.
local bad = goodConfig()
bad.Framework.Type = 'qbcore'
local okBad, reportBad = CisConfig.validate(bad, goodSecurity())
check(not okBad, 'an unknown Framework.Type is an error')
local problem = findProblem(reportBad, 'Config.Framework.Type')
check(problem ~= nil, 'the bad Framework.Type is reported')
check(problem ~= nil and problem.code == 'CFG_VALUE', 'it is reported as a wrong value, not a wrong type')
-- The fix must name the real key. "pick from the list" when the operator was
-- one capital letter away is a worse fix than naming it.
check(problem ~= nil and tostring(problem.fix):find('QBCORE', 1, true) ~= nil,
    'the near-miss fix names the value that was meant')
check(problem ~= nil and problem.fix ~= nil and problem.message ~= nil,
    'every problem carries both a message and a fix')

-- An inventory resource name that does not exist. Every one of these is a real
-- resource name, and none of them is a resource, and the symptom is
-- "HasItem always says no" -- which reads as an inventory bug, not a typo.
for _, wrong in ipairs({ 'ox_inventoryr', 'OX_INVENTORY', 'oxinventory' }) do
    local c = goodConfig()
    c.Framework.Inventory = wrong
    local o, r = CisConfig.validate(c, goodSecurity())
    check(not o, ('inventory %q is refused'):format(wrong))
    check(findProblem(r, 'Config.Framework.Inventory') ~= nil,
        ('inventory %q names the key in the report'):format(wrong))
end

-- The database driver list, same reasoning: a name with no adapter behind it
-- registers nothing and every query then answers nil.
local dbBad = goodConfig()
dbBad.Framework.Database.Type = 'mysql-async'
local okDb, reportDb = CisConfig.validate(dbBad, goodSecurity())
check(not okDb, 'a database driver with no adapter is refused')
check(findProblem(reportDb, 'Config.Framework.Database.Type') ~= nil,
    'the database refusal names the key')

-- ================================================================ wrong type
-- A config value that is not the type the resource reads. This must be reported
-- rather than indexed, and it must not raise -- the whole point of the check.
local typed = goodConfig()
typed.CallbackTimeout = 'ten seconds'
local okTyped, reportTyped = CisConfig.validate(typed, goodSecurity())
check(not okTyped, 'a string where a number belongs is an error')
check(findProblem(reportTyped, 'Config.CallbackTimeout') ~= nil, 'the type error names the key')
check(findProblem(reportTyped, 'Config.CallbackTimeout').code == 'CFG_TYPE',
    'a wrong type is reported as a type problem')

-- Nested. The check has to WALK, because a leaf that is right does not make
-- the path to it right.
local nested = goodConfig()
nested.Framework.Target = 'ox_target'
local okNested, reportNested = CisConfig.validate(nested, goodSecurity())
check(not okNested, 'a string where a table belongs is an error')
check(findProblem(reportNested, 'Config.Framework.Target') ~= nil, 'the nested type error names the leaf')

-- ================================================================ the range
-- `CallbackTimeout = 100` is not a syntax error and not a crash. It is every
-- callback on a busy server timing out, and the caller cannot tell that apart
-- from "no such thing", which is the expensive kind of wrong.
local ranged = goodConfig()
ranged.CallbackTimeout = 100
local okRanged, reportRanged = CisConfig.validate(ranged, goodSecurity())
check(not okRanged, 'a sub-500ms callback timeout is an error')
local rangeProblem = findProblem(reportRanged, 'Config.CallbackTimeout')
check(rangeProblem ~= nil and rangeProblem.code == 'CFG_RANGE', 'a bad timeout is reported as a range problem')
check(rangeProblem ~= nil and tostring(rangeProblem.fix):find('cannot') ~= nil or
    tostring(rangeProblem.fix):find('distinguish') ~= nil,
    'the range fix says WHY, not just "pick another number"')

-- ================================================================ the typo
-- The highest-value check in the file, and the one that cannot be found by
-- reading the code: an unknown key is invisible to every other test because
-- Lua accepts it and nothing reads it.
local typo = goodConfig()
typo.Framework.Typ = 'QBCORE'
local okTypo, reportTypo = CisConfig.validate(typo, goodSecurity())
check(okTypo, 'an unknown key is a warning, not an error -- the server still boots')
check(findProblem(reportTypo, 'Config.Framework.Typ') ~= nil, 'the unknown key is reported')
check(findProblem(reportTypo, 'Config.Framework.Typ').severity == 'warning',
    'an unknown key does not fail validation')
check(tostring(findProblem(reportTypo, 'Config.Framework.Typ').fix):find('Framework.Type', 1, true) ~= nil,
    'the typo fix names the key that was meant')

-- The obvious case: the operator typed a real key into the wrong table.
local misplaced = goodConfig()
misplaced.Zones = { Enabled = false }
local _, reportMisplaced = CisConfig.validate(misplaced, goodSecurity())
local misplacedProblem = findProblem(reportMisplaced, 'Config.Zones')
check(misplacedProblem ~= nil, 'a key in the wrong table is reported')
check(misplacedProblem ~= nil and tostring(misplacedProblem.fix):find('Framework.Zones', 1, true) ~= nil,
    'the wrong-table fix names where the key belongs')

-- TWO KEYS CAN BE ONE EDIT APART, AND THE SHALLOWER ONE IS THE ANSWER.
--
-- `Typ` is one edit from both `Framework.Type` and `Framework.Database.Type`,
-- and the two tie. Ordered lexicographically the DEEPER path sorts first ('D'
-- is less than 'T'), so the fix pointed an operator at a deeper key than the
-- one they had in mind -- and both are plausible, which is exactly what makes
-- it unhelpful.
local ambiguous = goodConfig()
ambiguous.Framework.Typ = 'QBCORE'
local _, reportAmbiguous = CisConfig.validate(ambiguous, goodSecurity())
local ambiguousFix = findProblem(reportAmbiguous, 'Config.Framework.Typ')
check(ambiguousFix ~= nil
    and tostring(ambiguousFix.fix):find('Config.Framework.Type --', 1, true) ~= nil,
    'an ambiguous typo is resolved to the SHALLOWER path, not the alphabetically first one')

-- And the suggestion is STABLE. Two boots of the same config must not name two
-- different keys -- which is the rule this file states about vim_keys, and the
-- one place it did not hold.
local firstFix
local stable = true
for _ = 1, 5 do
    local _, again = CisConfig.validate(ambiguous, goodSecurity())
    local fix = tostring(findProblem(again, 'Config.Framework.Typ').fix)
    if firstFix == nil then firstFix = fix end
    if fix ~= firstFix then stable = false end
end
check(stable, 'the suggestion is identical on every run -- hash order must not decide it')

-- ================================================================== security
local secBad = goodSecurity()
secBad.AuthorizedResources = 'cis_keys'
local okSec, reportSec = CisConfig.validate(goodConfig(), secBad)
check(not okSec, 'an allow-list that is a string rather than a table is an error')

local secEntries = goodSecurity()
secEntries.AuthorizedResources = { 'cis_keys', 42 }
local okEntries, reportEntries = CisConfig.validate(goodConfig(), secEntries)
check(not okEntries, 'a non-string allow-list entry is an error')

-- The map-shaped allow-list. `{ cis_keys = true }` is a natural thing to write
-- and it authorises nothing at all, because the reader is ipairs.
local secMap = goodSecurity()
secMap.AuthorizedResources = { cis_keys = true }
local _, reportMap = CisConfig.validate(goodConfig(), secMap)
check(findProblem(reportMap, 'Security.AuthorizedResources') ~= nil,
    'an allow-list written as a map is reported -- it authorises nothing')

-- Duplicates are harmless, and saying so once is cheaper than a support thread.
local secDup = goodSecurity()
secDup.AuthorizedResources = { 'cis_keys', 'cis_keys' }
local _, reportDup = CisConfig.validate(goodConfig(), secDup)
check(findProblem(reportDup, 'Security.AuthorizedResources[2]') ~= nil, 'a duplicate entry is noted')

-- Missing entirely is a WARNING, not an error, and the fix has to say what an
-- empty list means -- because "I never set it" and "I set it to nothing" have
-- opposite consequences and the operator cannot tell them apart.
local secNone = goodSecurity()
secNone.AuthorizedResources = nil
local okNone, reportNone = CisConfig.validate(goodConfig(), secNone)
check(okNone, 'an absent allow-list is a warning, not an error')
check(findProblem(reportNone, 'Security.AuthorizedResources') ~= nil, 'an absent allow-list is reported')
check(tostring(findProblem(reportNone, 'Security.AuthorizedResources').fix):find('NOBODY', 1, true) ~= nil,
    'the allow-list fix explains what an empty list means')

-- DropPlayer accepts three things and refuses the rest.
for _, good in ipairs({ true, false }) do
    local s = goodSecurity()
    s.DropPlayer = good
    check(CisConfig.validate(goodConfig(), s), ('DropPlayer = %s is accepted'):format(tostring(good)))
end
local sFn = goodSecurity()
sFn.DropPlayer = function() end
check(CisConfig.validate(goodConfig(), sFn), 'DropPlayer as a function is accepted')
local sBad = goodSecurity()
sBad.DropPlayer = 'yes'
local okDrop, reportDrop = CisConfig.validate(goodConfig(), sBad)
check(not okDrop, 'DropPlayer = "yes" is refused')

-- A custom adapter with no resource name. Detection would fall back to the
-- known frameworks and the operator's framework would silently not be on the
-- list, which is the hardest version of this failure to notice.
local custom = goodConfig()
custom.Framework.Custom = { name = 'MYFRAME' }
local okCustom, reportCustom = CisConfig.validate(custom, goodSecurity())
check(not okCustom, 'a custom adapter with no resource name is an error')
check(findProblem(reportCustom, 'Config.Framework.Custom.resource') ~= nil, 'the custom adapter error names the key')

-- ================================================================== discord
-- Enabling logs with a placeholder webhook is safe -- the queue refuses it --
-- but it is SILENT, and "I turned it on and nothing arrives" is a ticket.
local discordPlaceholder = { DiscordLogsLinks = { MasterLogs = 'CHANGE-ME-WITH-YOUR-WEBHOOK-LINK' } }
local _, reportDiscord = CisConfig.validate(goodConfig(), goodSecurity(), discordPlaceholder)
check(findProblem(reportDiscord, 'DiscordConfig.DiscordLogsLinks') ~= nil,
    'a placeholder webhook is noted, so "no messages" is explained before the ticket exists')

-- A real webhook must NOT be reported. A diagnostic that fires on a correct
-- install is a diagnostic that gets ignored.
local discordReal = { DiscordLogsLinks = { MasterLogs = 'https://discord.com/api/webhooks/1/abc' } }
local _, reportReal = CisConfig.validate(goodConfig(), goodSecurity(), discordReal)
check(findProblem(reportReal, 'DiscordConfig.DiscordLogsLinks') == nil,
    'a real webhook produces no problem')

-- ==================================================================== total
-- THE ONE THAT MATTERS MOST. A validator that raises on a malformed config is
-- the single failure this file exists to prevent, so every one of these is a
-- case where the input is not a config at all.
local weird = { true, false, 0, 42, '', print, function() end }
for _, v in ipairs(weird) do
    local called, r = pcall(CisConfig.validate, v, v, v)
    check(called, 'validate does not raise on ' .. type(v) .. ' input')
    if called and type(r) == 'table' then
        check(type(r.counts) == 'table' and r.counts.errors ~= nil,
            'a malformed root still produces a report with counts')
    end
end

-- A config whose nested tables are the wrong type all the way down.
local hostile = {
    Framework = 'not a table',
    UpdateInterval = 5,
    Sync = print,
    Printing = { Debug = 'yes', UseDiscordLogs = {} },
}
-- THREE values back: pcall's own success, then the two the function returns.
-- Taking two of them reads `ok` as the report, and every assertion after it
-- would be indexing a boolean -- which is the failure this suite exists to
-- catch, committed by the suite itself.
local calledHostile, hostileOk, rHostile =
    pcall(CisConfig.validate, hostile, { EventPrefix = {} }, { DiscordLogsLinks = 7 })
check(calledHostile, 'a config with wrong types at every level does not raise')
if calledHostile then
    check(hostileOk == false, 'and a config that wrong is not reported as valid')
    check(type(rHostile) == 'table' and rHostile.counts.errors > 0,
        'and it is reported rather than ignored')
end

-- Absent is not a problem. Shipping defaults and then failing a partial config
-- would make the defaults useless.
local okPartial, reportPartial = CisConfig.validate({}, {})
check(okPartial, 'an empty config validates -- every key has a default')
check(#reportPartial.error == 0, 'an empty config produces no errors')
check(#reportPartial.warning > 0, 'an empty config is still told the allow-list is empty')

-- ================================================================== summary
check(type(CisConfig.summary(report)) == 'string', 'summary is a string')
check(CisConfig.summary(reportPartial):find('warning', 1, true) ~= nil,
    'the summary counts what was found')
Test.report()
