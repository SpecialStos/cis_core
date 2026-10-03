-- Tests for the pure half of cis_core.
--
-- Only CisMigrations and the config accessor are pure, so only they are here.
-- The framework abstraction and the inventory service are adapters around
-- natives and third-party exports; testing those without a running server
-- would mean testing the mock, which is a comment about the mock.
--
-- What IS worth testing without a server is the ordering, the validation and
-- the sanitising, because each of those has a failure mode that looks like
-- success from the console and is discovered weeks later.

Test.begin('migrations')
local check = Test.check

-- ============================================================== sort ordering
-- The reason this module exists rather than a plain array iteration: an id like
-- "add_keys_table" sorts BEFORE "001_initial" as a string, so a product mixing
-- numbered and named migrations applies its later one first and finds a table
-- that does not exist yet.
local _, ka, sa = CisMigrations.sortKey('001_initial')
local _, kb, sb = CisMigrations.sortKey('010_add_keys')
check(ka < kb, 'numbered migrations sort by their number, not as strings')
-- 9 before 10. As strings '10' < '9', so a plain id sort applies the tenth
-- migration first and it fails against a table the second one creates.
local _, nine = CisMigrations.sortKey('9_thing')
local _, ten = CisMigrations.sortKey('10_thing')
check(nine < ten, '9 sorts before 10, which a string sort gets backwards')
check(sa < sb, 'ties fall through to the id')
local ug = CisMigrations.sortKey('add_keys_table')
check(ug == 1, 'an unnumbered id sorts after the numbered ones')

local ordered = CisMigrations.order({
    { id = 'add_keys_table' },
    { id = '010_second' },
    { id = '002_first' },
    { id = '001_initial' },
})
check(ordered[1].id == '001_initial', 'order: 001 first')
check(ordered[2].id == '002_first', 'order: 002 second')
check(ordered[3].id == '010_second', 'order: 010 third (not after 002 lexically-by-accident)')
check(ordered[4].id == 'add_keys_table', 'order: unnumbered ids come last')

-- Stable regardless of input order, which is the property that matters: the
-- same list written in a different order must not apply differently.
local shuffled = CisMigrations.order({
    { id = '001_initial' },
    { id = 'add_keys_table' },
    { id = '010_second' },
    { id = '002_first' },
})
local same = true
for i = 1, #ordered do
    if ordered[i].id ~= shuffled[i].id then
        same = false
    end
end
check(same, 'order is independent of the order the list was written in')

-- ================================================================ validation
-- Each of these is a migration that would otherwise LOOK applied and not be.
check(CisMigrations.validate({ { id = 'a', statements = { 'SELECT 1' } } }),
    'a well-formed list validates')

local ok1, why1 = CisMigrations.validate(nil)
check(ok1 == false, 'a nil list is refused')
local ok2, why2 = CisMigrations.validate({ { statements = { 'SELECT 1' } } })
check(ok2 == false, 'a migration with no id is refused')
check(tostring(why2):find('never be recorded') ~= nil,
    'the no-id refusal says why: it could never be recorded as applied')
local ok3 = CisMigrations.validate({ { id = 'a', statements = {} } })
check(ok3 == false, 'a migration with no statements is refused')
local ok4, why4 = CisMigrations.validate({
    { id = 'a', statements = { 'SELECT 1' } },
    { id = 'a', statements = { 'SELECT 2' } },
})
check(ok4 == false, 'a duplicate id is refused')
check(tostring(why4):find('twice') ~= nil, 'the duplicate refusal names the problem')

-- A migration with a nil id re-runs on every boot and a migration with no
-- statements silently does nothing -- both report success from the console,
-- which is why they are caught here rather than at apply time.
local badStatement, badWhy = CisMigrations.validate({ { id = 'a', statements = { 'ok', '' } } })
check(badStatement == false, 'an empty statement is refused')
check(tostring(badWhy):find('statement 2') ~= nil, 'the refusal says WHICH statement')

-- ==================================================================== plan
-- Two accepted shapes, because a product will use whichever reads better in
-- the file it happens to be writing.
local plan = CisMigrations.plan({
    { id = 'a', statements = { 'CREATE TABLE t (id INT)' } },
    { id = 'b', statements = { { sql = 'INSERT INTO t VALUES (?)', values = { 1 } } } },
})
check(#plan == 2, 'both statement shapes are planned')
check(plan[1].sql == 'CREATE TABLE t (id INT)' and type(plan[1].values) == 'table',
    'a bare string becomes a parameterless entry')
check(plan[2].sql == 'INSERT INTO t VALUES (?)' and plan[2].values[1] == 1,
    'a table entry keeps its sql and its values')
local alt = CisMigrations.plan({ { id = 'b', statements = { { sql = 'x', params = { 9 } } } } })
check(alt[1].values[1] == 9, '`params` is accepted as an alias for `values`')

-- ============================================================== config read
-- On the client, CoreLibs.clientConfig must always return a TABLE. A nil that
-- has to be checked at each use is a nil that will be forgotten at one of them,
-- and forgetting it means reading a framework setting as "not configured" on a
-- server that configured it.
exports = {}
local okGet, cfg = pcall(function()
    return CoreLibs.clientConfig()
end)
check(okGet, 'clientConfig does not raise when cis_libs is not there')
check(type(cfg) == 'table', 'clientConfig answers a table, never nil')
check(next(cfg) == nil, 'with no library the config is empty, not absent')
check(CoreLibs.clientFramework() ~= nil, 'clientFramework answers a table even with no payload')

CoreLibs.invalidateClientConfig()
check(type(CoreLibs.clientConfig()) == 'table', 'the cache can be dropped and refilled')
Test.report()
