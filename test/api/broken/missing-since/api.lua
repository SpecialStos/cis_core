-- Broken on purpose: Migrate has no `since`.
--
-- `since` is the one field with no safe default. Everything else in this file
-- can be inferred from the code; `since` is a claim about history, and a claim
-- with no value is a claim nobody can check. A consumer reading the contract to
-- decide whether a call is safe on their build has no way to tell.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.Migrate.since = nil
return real
