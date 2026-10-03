-- Tests for the shape reading shared by both realms.
--
-- framework_client.lua's header says it directly: "There was no test over this
-- file at all, which is how a divergence survives for years." The divergence it
-- describes is real and it was found -- after the fact, on a live server, by a
-- player noticing their job was wrong. These are the assertions that would have
-- found it on a push instead.
--
-- The subject is third-party DATA. Every shape below exists because some
-- framework, inventory or event payload in the wild has it, and none of them is
-- under this project's control.

Test.begin('normalize')
local check = Test.check

-- ================================================================ one entry
check(CisNormalize.itemEntry({ name = 'water', amount = 3 }) == 'water', 'name + amount reads directly')
check(CisNormalize.itemEntry({ name = 'bread', count = 2 }) == 'bread', 'count is accepted as the amount')
check(CisNormalize.itemEntry({ item = 'phone', amount = 1 }) == 'phone', 'item is accepted as the name')

-- THE ZERO. `amount = 0` is a real state in every one of these inventories -- a
-- stack that is present and empty. Written as `entry.amount or entry.count or
-- 1`, a zero survives (0 is truthy in Lua); written as `if not entry.amount`,
-- it becomes 1 and a player is handed an item they do not have.
local _, zeroAmount = CisNormalize.itemEntry({ name = 'empty', amount = 0 })
check(zeroAmount == 0, 'a zero amount stays zero rather than becoming the default of 1')

-- Both conventions at once, disagreeing. The counter used to match on either
-- field while the snapshot took `.name` first, so one entry counted for two
-- different items. Now both functions resolve the same way, and `.name` wins.
local dualName, dualAmount = CisNormalize.itemEntry({ name = 'water', item = 'poison', amount = 1 })
check(dualName == 'water', 'an entry with both name conventions resolves to name')
check(dualAmount == 1, 'and keeps its amount')

-- A non-numeric amount. Some framework builds have shipped a string here.
local _, coerced = CisNormalize.itemEntry({ name = 'x', amount = 'three' })
check(coerced == 1, 'a non-numeric amount falls back to 1 rather than poisoning every sum')

-- Anything that is not an entry at all. These inventories hand back whatever
-- is in the table, and a string element must not crash the count.
for _, junk in ipairs({ 'a string', 42, true }) do
    local name = CisNormalize.itemEntry(junk)
    check(name == nil, ('a %s is not an entry'):format(type(junk)))
end
local called = pcall(CisNormalize.itemEntry, nil)
check(called, 'itemEntry survives nil')

local noName = CisNormalize.itemEntry({ amount = 5 })
check(noName == nil, 'an entry with no name at all is not an entry')
check(CisNormalize.itemEntry({ name = '', amount = 1 }) == nil, 'an empty name is not an entry')

-- ================================================================== counting
local mixed = {
    { name = 'water', amount = 2 },
    { name = 'water', count = 3 },
    { item = 'water', amount = 1 },
    { name = 'bread', amount = 1 },
    { name = 'phone', count = 1 },
    'not an entry',
    { amount = 7 },
}
check(CisNormalize.itemCount(mixed, 'water') == 6,
    'water counts across name/item and amount/count conventions: 2 + 3 + 1')
check(CisNormalize.itemCount(mixed, 'bread') == 1, 'bread counts once')
check(CisNormalize.itemCount(mixed, 'nothing') == 0, 'an item nobody has counts zero, never nil')
check(CisNormalize.itemCount(nil, 'water') == 0, 'a nil inventory counts zero')
check(CisNormalize.itemCount('not a table', 'water') == 0, 'a non-table inventory counts zero')
check(CisNormalize.itemCount({}, 'water') == 0, 'an empty inventory counts zero')

-- The nil case is the one that raises rather than answering. `nil >= 1` is a
-- comparison against nil, which raises inside the caller.
local count = CisNormalize.itemCount(mixed, 'water')
check(type(count) == 'number', 'a count is a number even when nothing matches')

-- ================================================================= a snapshot
-- The shape every consumer reads. If this and itemCount disagree, a resource
-- can show a player an item it then refuses to let them use.
local snapshot = CisNormalize.itemSnapshot(mixed)
check(snapshot.water == 6, 'the snapshot agrees with the counter: 6')
check(snapshot.bread == 1, 'the snapshot agrees on bread')
check(snapshot['not an entry'] == nil, 'a string element is not a key in the snapshot')
check(CisNormalize.itemSnapshot(nil) ~= nil, 'a nil inventory is an empty snapshot, not nil')
check(next(CisNormalize.itemSnapshot({})) == nil, 'an empty inventory is an empty table')

-- THE MISMATCH THAT WAS LIVE. An entry carrying both name conventions set to
-- different values: the old counter matched it as either item, the old snapshot
-- filed it under `name`. One entry, two inventories. They must agree now.
local ambiguous = { { name = 'water', item = 'poison', amount = 1 } }
check(CisNormalize.itemCount(ambiguous, 'water') == 1, 'the counter files the ambiguous entry under name')
check(CisNormalize.itemCount(ambiguous, 'poison') == 0, 'and not under the item field')
check(CisNormalize.itemSnapshot(ambiguous).water == 1, 'the snapshot files it the same way')
check(CisNormalize.itemSnapshot(ambiguous).poison == nil, 'so the two can never disagree about it')

-- ================================================================= the job
-- Five payload shapes, none a superset of another. Both of the obvious ways to
-- read this were live bugs in this file at different times: taking only the
-- first made every playerLoaded a no-op, taking only the second would make
-- every setJob one.
local job = { name = 'police', grade = 3 }
local wrapped = { job = job, firstname = 'John' }

check(CisNormalize.jobFromPayload(job) == job, 'a bare job table is the job itself')
check(CisNormalize.jobFromPayload(wrapped) == job, 'a playerData wrapper yields the job under .job')
check(CisNormalize.jobFromPayload({ name = 'police' }) ~= nil, 'a name-only job is still a job')

-- A playerData that carries a name alongside its job -- which qbx_core's does
-- -- resolves as the job. Every framework that sends that shape means the job.
local both = { name = 'John Doe', job = job }
check(CisNormalize.jobFromPayload(both) == job,
    'a payload with both a name and a job resolves to the job, not the character name')

-- Everything that is not a job. These fire on real servers: a disconnect race, a
-- payload from a framework build that changed, a third-party resource triggering
-- the same event.
for _, junk in ipairs({ 'police', 42, true, {}, { name = '' }, { job = 'police' } }) do
    local got = CisNormalize.jobFromPayload(junk)
    check(got == nil, ('%s is not a job'):format(type(junk)))
end
local calledJob = pcall(CisNormalize.jobFromPayload, nil)
check(calledJob, 'jobFromPayload survives nil')

-- An unresolvable payload must leave the cache alone, not blank it. A client
-- that cleared its job on a bad payload would report "no job" for a player who
-- has one -- which reads as a framework bug and is not one.
local resolved = CisNormalize.jobFromPayload('police')
check(resolved == nil, 'an unresolvable payload answers nil, so the caller keeps what it had')

-- =============================================================== money route
-- `markedbills` is an ITEM on every framework here, not an account. Handing it
-- to AddMoney creates an account no shop and no ATM knows how to spend, and the
-- balance still rises -- so it looks like it worked.
check(CisNormalize.moneyRoute('markedbills') == 'inventory', 'markedbills is an item')
for _, account in ipairs({ 'cash', 'bank', 'crypto', 'black_money', '' }) do
    check(CisNormalize.moneyRoute(account) == 'account', ('%q is an account'):format(account))
end
check(CisNormalize.moneyRoute(nil) == 'account', 'a nil account type routes to the account path, as the default')

-- ================================================================== accounts
-- ESX hands back a LIST; QBCore hands back a table. This is the conversion.
local esx = {
    { name = 'cash', money = 500 },
    { name = 'bank', money = 1200 },
}
local mapped = CisNormalize.accountMap(esx)
check(mapped.cash == 500, 'an ESX account list maps cash')
check(mapped.bank == 1200, 'an ESX account list maps bank')
check(CisNormalize.accountMap(nil) ~= nil, 'a nil account list is an empty table, not nil')
check(CisNormalize.accountMap({ 'junk', 42, { money = 1 }, { name = 'ok', money = 2 } }).ok == 2,
    'an account with no name is skipped rather than keyed by nil')

-- ============================================================== person name
check(CisNormalize.personName('John', 'Doe') == 'John Doe', 'two names join with one space')
check(CisNormalize.personName('John', nil) == 'John', 'one name and no other still joins')
check(CisNormalize.personName(nil, nil) == nil, 'no name at all is nil, not an empty string')
check(CisNormalize.personName('', '') == nil, 'two empty names is nil, not ""')
check(CisNormalize.personName(42, true) == nil, 'non-string names are refused')
-- Only the OUTER padding is trimmed, which is what the original inline version
-- did with two gsubs and what the character name has always been. The gap in
-- the middle is preserved, because collapsing it would be a second, different
-- rule nobody asked for.
check(CisNormalize.personName('  John  ', '  Doe  ') == 'John     Doe',
    'the outer padding is trimmed and the gap between the names is left alone')

-- The distinction is the point. A blank name is something to fix; a missing one
-- is something to tolerate, and a consumer cannot tell them apart if both come
-- back as "".
local blank = CisNormalize.personName('', '')
local missing = CisNormalize.personName(nil, nil)
check(blank == nil and missing == nil, 'both unusable names are nil, so "no name" and "blank" agree')
check(type(CisNormalize.personName('A', 'B')) == 'string', 'and a real name is still a string')

-- ==================================================================== total
-- Every function answers and none raises. These run on framework data, which is
-- outside this project's control and has shipped shapes nobody predicted.
local probes = { nil, 0, 1, -1, '', 'x', true, false, {}, { {} }, { { {} } }, print, function() end }
for _, fn in ipairs({ 'itemEntry', 'itemCount', 'jobFromPayload', 'moneyRoute', 'accountMap', 'personName' }) do
    for _, a in ipairs(probes) do
        local ok = pcall(CisNormalize[fn], a, a)
        check(ok, ('%s survives %s input'):format(fn, type(a)))
    end
end
for _, a in ipairs(probes) do
    local ok = pcall(CisNormalize.itemSnapshot, a)
    check(ok, ('itemSnapshot survives %s input'):format(type(a)))
end

Test.report()