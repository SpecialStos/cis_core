-- Broken on purpose: Migrate is declared as (list) but registers (owner, list).
--
-- E032 -- the declaration and the code disagree about the parameter list. The
-- classic form of this bug is an argument that arrives one slot left of where
-- the reader expected it, which raises nothing and returns a wrong answer.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.Migrate.signature = '(list)'
return real
