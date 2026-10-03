-- Broken on purpose: an `until` that is BEFORE its `since`.
--
-- E011 -- `until` is earlier than `since`.
--
-- This fixture exists because of a bug in the VALIDATOR, not in the contract.
-- fengari's lua_toboolean returns a JS boolean rather than 0/1, and the walker
-- tested it with `=== 1`, which is always false. Every boolean in api.lua was
-- therefore read as `false`, so the guard
--
--     if (meta.until !== false && meta.until !== undefined)
--
-- never entered and the entire `until` block below it -- including this check,
-- and including "must be false or a MAJOR.MINOR.PATCH string" -- never ran. A
-- contract claiming it was removed in a version older than the one that added
-- it validated clean, and nobody noticed for the life of the repository.
--
-- The fix is one character, and the only reason it is one character is that a
-- fixture now fails when it is wrong.
local real = assert(loadfile(CIS_API_REAL))()
-- BRACKET FORM, not `.until`: `until` is a Lua keyword and `.until` is a
-- syntax error. That is the same reason api.lua writes `['until'] = false`,
-- and it is why the first version of this fixture came back E000 -- "the
-- contract did not load" -- which reads like a broken contract and was a
-- broken fixture.
real.exports.GetCoreSummary['until'] = '0.9.0'
return real
