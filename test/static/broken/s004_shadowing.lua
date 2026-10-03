-- Broken on purpose: a local that shadows a standard global.
--
-- Works fine until someone in this file means the real `type`, and the code
-- reads as though they did.
local function describe(value)
    local type = value == nil and 'nil' or 'something'
    return type
end
return describe
