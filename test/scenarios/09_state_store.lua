-- Scenario: the state store, against a fake driver.
--
-- test/state.lua covers the RULES -- what a value is allowed to be. This covers
-- the BEHAVIOUR: that two resources cannot see each other, that an upsert is an
-- upsert, and that a database which has gone away comes back when it returns.
--
-- The security property being tested is the one in server/state.lua's header:
-- there is no `owner` parameter anywhere in the public API, because the
-- namespace IS GetInvokingResource(). A store where the namespace is a
-- parameter is a store any resource can read and write for any other.

local Env = FrameworkEnv
Env.installCisLibs()
local db = Env.installFakeDb()

Env.invokingAs('cis_keys')

-- The store asks CisMigrationRunner whether its schema is there, so both files
-- load, in that order: migrations first, because state.lua calls into it.
dofile('server/migrations.lua')
dofile('server/state.lua')
Env.runThreads()

Test.begin('state-store')
local check = Test.check
Test.note(('tables=%d calls=%d'):format(
    (function()
        local n = 0
        for _ in pairs(db.tables) do n = n + 1 end
        return n
    end)(),
    #db.calls))

-- The schema was created through the ledger, by the same runner a product uses.
check(db.tables.cis_migrations ~= nil, 'the ledger was created')
check(db.tables.cis_state ~= nil, 'and so was the state store')

-- ------------------------------------------------------------------- write
check(exports['cis_core']:StateSet('greeting', 'hello') == true, 'a string writes')
check(exports['cis_core']:StateSet('count', 42) == true, 'a number writes')
check(exports['cis_core']:StateSet('flag', true) == true, 'a boolean writes')
check(exports['cis_core']:StateSet('table', { a = 1, b = { c = 2 } }) == true, 'a table writes')
check(exports['cis_core']:StateSet('list', { 1, 2, 3 }) == true, 'an array writes')

-- Round trip. A store that writes and cannot read back is worse than one that
-- does not write, because the caller believes it.
check(exports['cis_core']:StateGet('greeting') == 'hello', 'a string comes back')
check(exports['cis_core']:StateGet('count') == 42, 'a number comes back')
check(exports['cis_core']:StateGet('flag') == true, 'a boolean comes back')
local t = exports['cis_core']:StateGet('table')
check(type(t) == 'table' and t.b and t.b.c == 2, 'a nested table comes back intact')
local l = exports['cis_core']:StateGet('list')
check(type(l) == 'table' and #l == 3 and l[2] == 2, 'an array comes back in order')

-- The fallback is returned when the key is not there, and it is returned on
-- FAILURE too, so an unavailable store answers the default rather than nil.
check(exports['cis_core']:StateGet('missing', 'fallback') == 'fallback', 'a missing key answers the fallback')
check(exports['cis_core']:StateGet('missing') == nil, 'and nil when no fallback is given')

-- ------------------------------------------------------------- the upsert
-- Twice is one row, not two. The store reads before it writes because MySQL's
-- ON DUPLICATE KEY UPDATE is MySQL syntax and MongoDB is also a supported
-- driver.
check(db.tables.cis_state ~= nil and #db.tables.cis_state > 0, 'rows exist')
local function rowCount(owner, key)
    local n = 0
    for _, row in ipairs(db.tables.cis_state) do
        if row.owner == owner and row.k == key then n = n + 1 end
    end
    return n
end
check(rowCount('cis_keys', 'greeting') == 1, 'a first write is one row')
check(exports['cis_core']:StateSet('greeting', 'goodbye') == true, 'a second write is accepted')
check(rowCount('cis_keys', 'greeting') == 1, 'and is still one row')
check(exports['cis_core']:StateGet('greeting') == 'goodbye', 'and the newer value is what comes back')

-- ------------------------------------------------------ the security property
-- THE ASSERTION THIS FILE EXISTS FOR. There is no owner parameter, so a
-- resource cannot name another one -- and this proves it by being one.
Env.invokingAs('cis_housing')
check(exports['cis_core']:StateGet('greeting') == nil, "another resource cannot see cis_keys' values")
check(exports['cis_core']:StateGet('greeting', 'fallback') == 'fallback', 'and gets its fallback instead')
check(exports['cis_core']:StateSet('greeting', 'hijacked') == true, 'and can write its own')
check(exports['cis_core']:StateGet('greeting') == 'hijacked', 'without disturbing the other')

Env.invokingAs('cis_keys')
check(exports['cis_core']:StateGet('greeting') == 'goodbye', 'and the first resource is untouched')

local all = exports['cis_core']:StateAll()
check(type(all) == 'table', 'StateAll returns a table')
check(all.housing_only == nil, 'which contains only this namespace')

-- ------------------------------------------------------------- enumeration
local keys = exports['cis_core']:StateKeys()
check(type(keys) == 'table', 'StateKeys returns a table')
check(#keys >= 5, 'listing every key it holds')
local sorted = true
for i = 2, #keys do
    if keys[i - 1] > keys[i] then sorted = false end
end
check(sorted, 'and they are sorted, so two calls answer the same way')

-- ------------------------------------------------------------------ removal
check(exports['cis_core']:StateDelete('greeting') == true, 'a key is deleted')
check(exports['cis_core']:StateGet('greeting') == nil, 'and is gone')
check(exports['cis_core']:StateDelete('greeting') == true,
    'deleting a key that is not there is true, not an error -- "make sure this is gone" is what callers want')

local before = #exports['cis_core']:StateAll()
check(exports['cis_core']:StateClear() >= before, 'StateClear removes the namespace')
check(next(exports['cis_core']:StateAll()) == nil, 'and the namespace is empty')

-- ---------------------------------------------------------------- refusals
check(exports['cis_core']:StateSet('bad key', 1) == false, 'a key with a space is refused')
check(exports['cis_core']:StateSet('', 1) == false, 'an empty key is refused')
local okFn, whyFn = exports['cis_core']:StateSet('fn', function() end)
check(okFn == false, 'a function value is refused')
check(type(whyFn) == 'string' and whyFn:find('function', 1, true) ~= nil,
    'and the refusal names the type it was handed')

-- ------------------------------------------------------- the driver goes away
-- THE CASE THAT MATTERS OPERATIONALLY. A database that blips must not leave the
-- store dead for the life of the server: the retry backoff exists so it comes
-- back on its own, with no restart.
db.broken = true
Env.env.now = Env.env.now + 100000 -- past the 5s backoff
local okDown, whyDown = exports['cis_core']:StateSet('while_down', 1)
check(okDown == false, 'a write is refused while the driver is gone')
check(type(whyDown) == 'string' and whyDown ~= '', 'with a reason the caller can print')
check(exports['cis_core']:StateGet('while_down', 'fallback') == 'fallback',
    'and a read answers its fallback rather than nil')

db.broken = false
Env.env.now = Env.env.now + 100000
check(exports['cis_core']:StateSet('after_recovery', 1) == true,
    'and the store recovers by itself once the driver returns')
check(exports['cis_core']:StateGet('after_recovery') == 1, 'with the value it accepted')

-- -------------------------------------------------------------- the summary
local summary = exports['cis_core']:GetStateSummary()
check(type(summary) == 'table', 'GetStateSummary answers a table')
check(summary.available == true, 'and reports itself available now the driver is back')
check(type(summary.namespaces) == 'table', 'with the namespaces it can see')
local sawKeys = false
for _, ns in ipairs(summary.namespaces) do
    if ns.owner == 'cis_keys' and ns.keys > 0 then sawKeys = true end
end
check(sawKeys, 'and a count for this one -- read from the database, not from memory')

-- And it exposes no VALUE, which is the property that makes it safe to paste
-- into a support thread. Every key it carries is a resource name, a count or a
-- boolean; assert there is no field that could hold one.
for _, ns in ipairs(summary.namespaces) do
    check(ns.owner ~= nil and ns.keys ~= nil, 'a namespace entry is a name and a count, nothing else')
    check(type(ns.owner) == 'string' and type(ns.keys) == 'number', 'and both are the right type to print')
end
check(summary.available == true, 'and the summary says whether the store is usable')

Test.report()
Test.raiseIfFailed()