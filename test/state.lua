-- Tests for the state store's rules.
--
-- This is the only part of cis_core that takes a value from a caller and
-- writes it somewhere durable, so it is the part where an unexamined edge case
-- becomes a row that is wrong forever. The rules are pure -- no database, no
-- exports, no globals -- which is what makes them testable here at all.
--
-- Every assertion below is about a value that JSON cannot round-trip, a value
-- that would grow without bound, or a value that would crash the server. Those
-- are the three ways a key/value store eats a resource, and all three are
-- invisible until a player triggers them.

Test.begin('state')
local check = Test.check

-- ================================================================== the key
-- The column is VARCHAR(64), so a longer key is truncated by one driver and
-- refused by another. Checked here rather than discovered when two resources
-- disagree about what a key is called.
check(CisStateRules.key('version'), 'a plain key is accepted')
check(CisStateRules.key('housing:door_lock'), 'a key may contain dots and colons')
check(CisStateRules.key('schema-version_2'), 'a key may contain dashes, underscores and digits')

for _, bad in ipairs({ '', 'has space', 'quote"', 'semi;colon', 'slash/here', 'drop\0table' }) do
    local ok = CisStateRules.key(bad)
    check(ok == false, ('key %q is refused'):format(bad))
end
for _, bad in ipairs({ 42, true, {}, print }) do
    local ok, why = CisStateRules.key(bad)
    check(ok == false, ('key of type %s is refused'):format(type(bad)))
    check(tostring(why):find('string', 1, true) ~= nil, 'the key refusal names the type it wanted')
end

local longKey = string.rep('k', 65)
local okLong, whyLong = CisStateRules.key(longKey)
check(okLong == false, 'a 65-character key is refused')
check(tostring(whyLong):find('64', 1, true) ~= nil, 'the length refusal quotes the limit')
check(CisStateRules.key(string.rep('k', 64)), 'a 64-character key is exactly at the limit and accepted')

-- ================================================================= the value
check(CisStateRules.value(true), 'a boolean is stored')
check(CisStateRules.value(0), 'zero is stored')
check(CisStateRules.value(''), 'an empty string is stored')
check(CisStateRules.value('anything at all'), 'a string is stored')
check(CisStateRules.value({}), 'an empty table is stored')
check(CisStateRules.value({ 1, 2, 3 }), 'an array is stored')
check(CisStateRules.value({ a = 1, b = { c = 'd' } }), 'a nested table is stored')

-- The one that matters most: a function. json.encode refuses it, but it refuses
-- it deep inside a C routine with a message about an internal type tag and no
-- key on the stack. The whole point of pre-checking is that the message says
-- WHICH one.
local okFn, whyFn = CisStateRules.value({ metadata = { callback = function() end } })
check(okFn == false, 'a table containing a function is refused')
check(tostring(whyFn):find('metadata.callback', 1, true) ~= nil,
    'the refusal names the path to the function, not just "a function"')

check(CisStateRules.value(print) == false, 'a bare function is refused')
check(CisStateRules.value(coroutine.create(function() end)) == false, 'a coroutine is refused')

-- JSON cannot represent these, so a row containing one reads back as nil on
-- the next boot -- which is a setting that silently reverts.
local okNaN = CisStateRules.value(0 / 0)
check(okNaN == false, 'NaN is refused')
check(tostring(select(2, CisStateRules.value(0 / 0))):find('NaN', 1, true) ~= nil,
    'the NaN refusal says NaN')
check(CisStateRules.value(math.huge) == false, 'infinity is refused')
check(CisStateRules.value(-math.huge) == false, 'negative infinity is refused')

-- =================================================================== the cycle
-- THE ONE THAT IS WORTH A SUITE. A table containing itself walks until the
-- stack gives out, and on the server that takes the resource down rather than
-- returning an error. The depth cap alone would stop the walk, but it would
-- report "nested too deep" for a value that is 1 deep and self-referential --
-- a message that sends the reader looking in the wrong place.
local cyclic = { name = 'loop' }
cyclic.self = cyclic
local okCycle, whyCycle = CisStateRules.value(cyclic)
check(okCycle == false, 'a table containing itself is refused')
check(tostring(whyCycle):find('itself', 1, true) ~= nil, 'the cycle refusal says "itself"')

local indirect = { name = 'a' }
indirect.child = { parent = indirect }
local okIndirect = CisStateRules.value(indirect)
check(okIndirect == false, 'an indirect cycle is refused too, not just a direct one')

-- And the case that must NOT be refused: the same table referenced twice. That
-- is a normal shape -- a config that mentions one sub-table in two places -- and
-- a store that rejects it would be rejecting something harmless.
local shared = { id = 7 }
local okShared = CisStateRules.value({ first = shared, second = shared })
check(okShared == true, 'a table referenced twice in the same value is accepted')

-- A table that was walked once must not leave the ancestor set dirty, or the
-- SECOND, unrelated use of that same table would be reported as a cycle. This
-- is the false positive that a naive implementation produces and that a caller
-- hits on their second call, never their first.
local reused = { id = 1 }
check(CisStateRules.value({ a = reused }), 'a table passes on first use')
check(CisStateRules.value({ a = reused }), 'and passes again on the second use')

-- ================================================================== the limits
-- Depth. A structure this deep is a data structure, not a setting.
local deep = { value = true }
for _ = 1, 20 do
    deep = { nested = deep }
end
local okDeep, whyDeep = CisStateRules.value(deep)
check(okDeep == false, 'a value nested past the depth cap is refused')
check(tostring(whyDeep):find('deep', 1, true) ~= nil, 'the depth refusal says deep')

-- Entries. Without this, one key whose value is a million-element table turns
-- a single state write into a single very long request.
local wide = {}
for i = 1, 400 do
    wide['k' .. i] = i
end
local okWide, whyWide = CisStateRules.value(wide)
check(okWide == false, 'a value with more entries than the cap is refused')
check(tostring(whyWide):find('entries', 1, true) ~= nil, 'the width refusal says entries')

-- Non-string, non-number keys. JSON has no other key type, so this is silently
-- lost on encode.
local badKey = CisStateRules.value({ [true] = 'x' })
check(badKey == false, 'a table keyed by a boolean is refused')

-- ============================================================== the size cap
-- Checked against the ENCODED form, because that is what the column holds: a
-- 40-character string of multi-byte characters is over 100 bytes before any
-- JSON quoting, and "40 characters" would have said it was fine.
check(CisStateRules.encodedSize('small'), 'a small encoding is accepted')
local okSize, whySize = CisStateRules.encodedSize(string.rep('x', 20000))
check(okSize == false, 'an oversized encoding is refused')
check(tostring(whySize):find('16384', 1, true) ~= nil, 'the size refusal quotes the limit')
check(CisStateRules.encodedSize(string.rep('x', 16384)) == true, 'exactly at the limit is accepted')
check(CisStateRules.encodedSize(nil) == false, 'a non-string encoding is refused')

-- ============================================================ the combined check
-- Key first. A bad key is the caller's bug at the call site, and a value error
-- that does not mention the key is half an answer.
local okBoth, whyBoth = CisStateRules.check('bad key', 5)
check(okBoth == false, 'check() refuses a bad key even when the value is fine')
check(tostring(whyBoth):find('key', 1, true) ~= nil, 'and says the problem is the key')
check(CisStateRules.check('good_key', { a = 1 }) == true, 'check() accepts a good pair')

-- ==================================================================== total
-- Every one of these has to be an answer and never a raise. The rules run on
-- caller-supplied values, and a rules file that raises is a crash with a stack
-- trace where a sentence was owed.
for _, v in ipairs({ 1, -1, 0, 0.5, 1e308, true, false, 'x', {}, { {} } }) do
    local called = pcall(CisStateRules.value, v)
    check(called, ('value() survives %s input'):format(type(v)))
end
for _, v in ipairs({ 1, 'x', true, {}, print, nil }) do
    local called = pcall(CisStateRules.key, v)
    check(called, ('key() survives %s input'):format(type(v)))
    local calledCheck = pcall(CisStateRules.check, v, v)
    check(calledCheck, ('check() survives %s input'):format(type(v)))
end

-- The limits table is a real answer to "how big can this be", so it must be
-- readable by a caller rather than buried in the source.
check(type(CisStateRules.LIMITS) == 'table', 'the limits are exposed')
check(type(CisStateRules.LIMITS.VALUE_BYTES) == 'number', 'the byte limit is exposed')
check(type(CisStateRules.LIMITS.KEY_LENGTH) == 'number', 'the key limit is exposed')

Test.report()