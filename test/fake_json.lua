-- A JSON codec for the scenario runner, because fengari has none and the state
-- store is built on one.
--
-- FAITHFUL WHERE IT MATTERS, and the two places are not arbitrary:
--
--   * A FUNCTION RAISES. FiveM's codec is lua-rapidjson, which raises
--     "type 'function' is not supported by JSON". The state store relies on
--     that raise being caught by its own pcall, and a fake that quietly
--     dropped functions would test a path that does not exist.
--
--   * NaN AND INFINITY DO **NOT** RAISE. This is the finding that matters.
--     lua-rapidjson compiles with JSON_NAN_AND_INF in its default flag set, so
--     it writes bare `NaN` / `Infinity` -- invalid per RFC 8259, and a value
--     that comes back as nil on the next boot. `CisStateRules` refuses both
--     BEFORE this is ever reached, which is load-bearing rather than
--     defensive, and a fake that raised here would quietly remove the reason
--     the rule exists.
--
-- What it does NOT model: the 32-level nesting guard (the state rules cap depth
-- at 8, well under it), non-BMP strings, and surrogate pairs.
--
-- It is a real encoder and a real decoder, so the round trip is a real round
-- trip. A lossless-but-not-JSON substitute would have exercised the same
-- control flow while testing nothing about the encoding, which is the part that
-- decides whether a stored value can be read back next boot.

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' then return false end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return n > 0 or true
end

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escapeString(s)
    return (s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format('\\u%04x', c:byte())
    end))
end

local encodeValue

local function encodeTable(t, depth)
    if depth > 32 then
        error('reference cycle', 0)
    end
    local out = {}
    if isArray(t) then
        for i = 1, #t do
            out[#out + 1] = encodeValue(t[i], depth + 1)
        end
        return '[' .. table.concat(out, ',') .. ']'
    end
    local keys = {}
    for k in pairs(t) do
        if type(k) ~= 'string' then
            error('table keys must be strings', 0)
        end
        keys[#keys + 1] = k
    end
    -- Sorted, so an encoded value is byte-identical for the same input. That is
    -- what makes "the same state encodes the same way" a testable claim.
    table.sort(keys)
    for _, k in ipairs(keys) do
        out[#out + 1] = '"' .. escapeString(k) .. '":' .. encodeValue(t[k], depth + 1)
    end
    return '{' .. table.concat(out, ',') .. '}'
end

encodeValue = function(v, depth)
    depth = depth or 1
    local t = type(v)
    if v == nil then return 'null' end
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then
        -- Bare NaN and Infinity, exactly as rapidjson writes them.
        if v ~= v then return 'NaN' end
        if v == math.huge then return 'Infinity' end
        if v == -math.huge then return '-Infinity' end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
        return string.format('%.14g', v)
    end
    if t == 'string' then return '"' .. escapeString(v) .. '"' end
    if t == 'table' then return encodeTable(v, depth) end
    -- Everything else -- functions, userdata, coroutines -- RAISES, as the real
    -- codec does.
    error("type '" .. t .. "' is not supported by JSON", 0)
end

-- ------------------------------------------------------------------- decode

local Decoder = {}
Decoder.__index = Decoder

function Decoder.new(text)
    return setmetatable({ s = text, i = 1 }, Decoder)
end

function Decoder:skip()
    local _, stop = self.s:find('^[ \t\r\n]*', self.i)
    self.i = (stop or self.i - 1) + 1
end

function Decoder:peek()
    return self.s:sub(self.i, self.i)
end

function Decoder:expect(ch)
    if self:peek() ~= ch then
        error(('expected %q at offset %d'):format(ch, self.i), 0)
    end
    self.i = self.i + 1
end

function Decoder:parseString()
    self:expect('"')
    local out = {}
    while true do
        local c = self:peek()
        if c == '' then error('unterminated string', 0) end
        self.i = self.i + 1
        if c == '"' then break end
        if c == '\\' then
            local esc = self:peek()
            self.i = self.i + 1
            local map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
            if map[esc] then
                out[#out + 1] = map[esc]
            elseif esc == 'u' then
                local hex = self.s:sub(self.i, self.i + 3)
                self.i = self.i + 4
                out[#out + 1] = utf8.char(tonumber(hex, 16) or 63)
            else
                error(('bad escape \\%s'):format(esc), 0)
            end
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

function Decoder:parseNumber()
    local text = self.s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', self.i)
    if not text or text == '' then error(('bad number at offset %d'):format(self.i), 0) end
    self.i = self.i + #text
    return tonumber(text)
end

function Decoder:parseValue(depth)
    depth = depth or 1
    if depth > 32 then error('nesting too deep', 0) end
    self:skip()
    local c = self:peek()
    if c == '"' then return self:parseString() end
    if c == '{' then
        self.i = self.i + 1
        local out = {}
        self:skip()
        if self:peek() == '}' then self.i = self.i + 1 return out end
        while true do
            self:skip()
            local key = self:parseString()
            self:skip()
            self:expect(':')
            out[key] = self:parseValue(depth + 1)
            self:skip()
            local d = self:peek()
            self.i = self.i + 1
            if d == '}' then break end
            if d ~= ',' then error(('expected , or } at offset %d'):format(self.i - 1), 0) end
        end
        return out
    end
    if c == '[' then
        self.i = self.i + 1
        local out = {}
        self:skip()
        if self:peek() == ']' then self.i = self.i + 1 return out end
        while true do
            out[#out + 1] = self:parseValue(depth + 1)
            self:skip()
            local d = self:peek()
            self.i = self.i + 1
            if d == ']' then break end
            if d ~= ',' then error(('expected , or ] at offset %d'):format(self.i - 1), 0) end
        end
        return out
    end
    if self.s:sub(self.i, self.i + 3) == 'true' then self.i = self.i + 4 return true end
    if self.s:sub(self.i, self.i + 4) == 'false' then self.i = self.i + 5 return false end
    if self.s:sub(self.i, self.i + 3) == 'null' then self.i = self.i + 4 return nil end
    if self.s:sub(self.i, self.i + 2) == 'NaN' then self.i = self.i + 3 return 0 / 0 end
    if self.s:sub(self.i, self.i + 8) == 'Infinity' then self.i = self.i + 8 return math.huge end
    if self.s:sub(self.i, self.i + 9) == '-Infinity' then self.i = self.i + 9 return -math.huge end
    return self:parseNumber()
end

local fakeJson = {}

function fakeJson.encode(value)
    return encodeValue(value, 1)
end

function fakeJson.decode(text)
    if type(text) ~= 'string' then
        error('json.decode expects a string', 0)
    end
    local d = Decoder.new(text)
    local value = d:parseValue(1)
    return value
end

_G.json = fakeJson

return fakeJson