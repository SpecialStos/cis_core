-- Broken on purpose: a missing `local`.
--
-- `leakedCount` is assigned at statement level and is never declared, so it
-- lands in _G where the next resource to load collides with it. Valid Lua.
local function tally()
    leakedCount = leakedCount + 1
    return leakedCount
end
return tally
