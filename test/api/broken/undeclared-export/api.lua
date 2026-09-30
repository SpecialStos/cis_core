-- Broken on purpose: AppliedMigrations is registered by server/migrations.lua
-- and is not in api.lua.
--
-- E031 -- the other half of drift. E030 catches a declaration for something
-- that does not exist; this catches a real, working, reachable export that
-- nobody has taken responsibility for. It is the direction that rots quietly,
-- because the export keeps working and nobody notices it is undocumented until
-- it is gone.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.AppliedMigrations = nil
return real
