-- Broken on purpose: a command is declared without saying whether it is
-- restricted.
--
-- E061 -- `restricted` must be a boolean.
--
-- Every command in this resource gates on the caller, and that fact is the
-- reason to run one. A declaration that omits it leaves a reader unable to
-- answer the only question that matters before telling a player the command
-- exists.
local real = assert(loadfile(CIS_API_REAL))()
real.commands['cis_core_doctor'].restricted = nil
return real
