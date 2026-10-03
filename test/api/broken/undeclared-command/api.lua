-- Broken on purpose: the contract declares no console commands at all.
--
-- E062 -- a command registered in the source but not declared in api.lua.
--
-- This is the direction that hurts. A command that is not in the contract is a
-- capability whose permission model nobody wrote down, and the permission model
-- is the first thing a reader of a console command needs: it decides whether
-- the command is safe to mention in public, and whether a player can type it.
-- An operator whose support thread says "run cis_core_doctor" cannot check.
local real = assert(loadfile(CIS_API_REAL))()
real.commands = {}
return real
