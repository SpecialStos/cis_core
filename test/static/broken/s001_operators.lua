-- Broken on purpose: Java operators.
--
-- These are inside COMMENTS in a way that a naive grep would catch and a reader
-- skims past, and one is in a string. S001 must ignore both of those and still
-- find the real one on the last line.
local a = 1
local b = 2
-- a != b is how you would write this in C, and it is not Lua.
local s = 'this string contains != and && and should not be reported'
local c = a != b
local d = a && b
local e = a == b
return c, d, e
