-- Broken on purpose: GetCoreSummary is declared for the client realm, where
-- nothing registers it.
--
-- E030 -- a declaration for a realm that does not exist. This is the direction
-- that hurts: a consumer writes against the client signature, ships, and finds
-- a nil index at runtime with nothing in the contract to explain it.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.GetCoreSummary.realm = 'client'
return real
