-- Broken on purpose: a numeric for over a table that starts at 0 and does not
-- compensate. This reads slot 0, which is nil, and moves on.
local t = { 'a', 'b', 'c' }
local out = {}
for i = 0, #t do
    out[#out + 1] = t[i]
end
return out
