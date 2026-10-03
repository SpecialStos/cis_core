-- =============================================================================
--  cis_core -- state store rules  (SERVER SIDE ONLY, PURE)
--
--  WHY THIS IS ITS OWN FILE AND HAS NO IMPORTS
--
--  Everything in here is a question about a value, answered without touching a
--  database, an export or a global. That is what makes it testable under
--  fengari on every push -- and the state store is the one part of cis_core
--  that takes a VALUE FROM A CALLER and writes it somewhere durable, so it is
--  exactly the part where an unexamined edge case becomes a row that is wrong
--  forever.
--
--  WHAT A STATE VALUE IS ALLOWED TO BE
--
--  A small, closed set of JSON types, and nothing else. No function, no userdata,
--  no thread, no cycle, no unbounded nesting. Every one of those is refused with
--  a sentence naming what was wrong, because "failed to save state" is the
--  single least useful diagnostic in this resource.
--
--  WHY NOT JUST LET THE ENCODER RAISE
--
--  json.encode does refuse a function, and refusing is not the problem. The
--  problem is WHERE it refuses: deep inside a C routine, with a message about
--  an internal type tag, on a stack that no longer has the caller's key on it.
--  A pre-check that walks the value answers "this value contains a function at
--  depth 2, under the key 'metadata'" instead, and it costs one pass over a
--  structure that is capped at 256 entries anyway.
-- =============================================================================

CisStateRules = {}

-- The limits, named so the fix can quote them.
CisStateRules.LIMITS = {
    -- MySQL VARCHAR(64) is the column width, and a key longer than that is
    -- truncated by some drivers and refused by others. Checked here rather than
    -- discovered when two resources disagree about what a key is called.
    KEY_LENGTH = 64,

    -- LONGTEXT is the column, and this is the practical ceiling. A state value
    -- larger than this is a schema, a file or a log, and none of those belong in
    -- a key/value store -- cis_migrate is the tool for a real import.
    VALUE_BYTES = 16384,

    -- Depth. A nested table deeper than this is a data structure, not a setting.
    DEPTH = 8,

    -- Entries per table. Without this a caller can write one key whose value is
    -- a million-element table and turn a single state write into a single very
    -- long request.
    ENTRIES = 256,
}

-- The characters a key may contain. Deliberately narrow: a key is an identifier
-- that appears in logs, in `cis_core_doctor` output and in a support thread, and
-- allowing arbitrary bytes into it means any of those can be made to render
-- something other than what was stored.
--
-- This is a closed list rather than a denylist on purpose. A denylist is a list
-- of the things somebody already tried, and the next thing is not on it.
local KEY_PATTERN = '^[%w_%-%.:%+]+$'

--- Is this a usable key?
--- @return boolean ok, string|nil reason
function CisStateRules.key(k)
    if type(k) ~= 'string' then
        return false, ('a key must be a string, and this is %s'):format(type(k))
    end
    if k == '' then
        return false, 'a key cannot be empty'
    end
    if #k > CisStateRules.LIMITS.KEY_LENGTH then
        return false, ('a key is %d characters; the limit is %d'):format(
            #k, CisStateRules.LIMITS.KEY_LENGTH)
    end
    if not k:match(KEY_PATTERN) then
        return false, ('a key may only contain letters, digits, underscore, dash, dot, colon and plus -- %q '
            .. 'contains something else'):format(k)
    end
    return true
end

-- Walk a value, refusing anything that is not a JSON type, and anything too
-- big or too deep to store.
--
-- `path` is carried down so the message can point at the offending element. That
-- is the whole reason this is a walk and not a type check: `{ metadata = { fn =
-- function() end } }` has one wrong type in it and the operator needs to know
-- WHICH one.
--
-- `ancestors` is the set of tables on the CURRENT path, added on the way down and
-- removed on the way back up. That removal is what makes a shared sub-table legal:
-- a value that mentions the same table twice is a normal shape and refusing it
-- would be refusing something harmless. What it does not permit is a table that
-- contains itself, which is the case that would otherwise walk until the stack
-- gave out and take the resource down instead of returning an error.
local function walk(value, depth, path, ancestors, budget)
    local t = type(value)

    if t == 'nil' or t == 'boolean' then
        return true
    end

    if t == 'string' then
        -- THE SIZE CHECK HAPPENS HERE, DURING THE WALK, NOT AFTER ENCODING.
        --
        -- `LIMITS.VALUE_BYTES` read like a memory bound and was not one. The
        -- entry and depth caps bound STRUCTURE -- 256 entries, 8 levels -- and
        -- said nothing about how big those entries were. A value of 256
        -- megabyte strings passed the walk, was then handed to `json.encode`,
        -- which materialises the whole thing as one string, and only then
        -- reached `encodedSize` and refused it. Hundreds of megabytes allocated
        -- inside one call to reject a value the rules had already decided to
        -- reject.
        --
        -- Counting bytes as they are met means the refusal happens at the
        -- megabyte that crosses the line rather than at the end of a walk that
        -- was always going to fail. `encodedSize` stays as the backstop for
        -- JSON quoting, which adds bytes the walk never saw.
        budget.bytes = budget.bytes + #value
        if budget.bytes > CisStateRules.LIMITS.VALUE_BYTES then
            return false, ('%s and everything before it is already %d bytes; the limit is %d')
                :format(path, budget.bytes, CisStateRules.LIMITS.VALUE_BYTES)
        end
        return true
    end

    if t == 'number' then
        -- JSON has no NaN and no infinity, and every encoder either refuses
        -- them or writes something no decoder can read back. Refusing here means
        -- the answer is a sentence rather than a row that reads back as nil.
        if value ~= value then
            return false, ('%s is NaN, which JSON cannot represent'):format(path)
        end
        if value == math.huge or value == -math.huge then
            return false, ('%s is infinite, which JSON cannot represent'):format(path)
        end
        return true
    end

    if t == 'function' then
        return false, ('%s is a function, and only values survive a restart'):format(path)
    end
    if t == 'thread' then
        return false, ('%s is a coroutine, which cannot be stored'):format(path)
    end
    if t == 'userdata' then
        return false, ('%s is userdata, which cannot be stored'):format(path)
    end

    if t ~= 'table' then
        return false, ('%s is %s, which is not a storable type'):format(path, t)
    end

    if depth >= CisStateRules.LIMITS.DEPTH then
        return false, ('%s is nested more than %d deep, which is a data structure rather than a setting')
            :format(path, CisStateRules.LIMITS.DEPTH)
    end

    if ancestors[value] then
        return false, ('%s contains a table that contains itself'):format(path)
    end
    ancestors[value] = true

    local n = 0
    for k, v in pairs(value) do
        n = n + 1
        if n > CisStateRules.LIMITS.ENTRIES then
            ancestors[value] = nil
            return false, ('%s has more than %d entries, which is a table rather than a setting')
                :format(path, CisStateRules.LIMITS.ENTRIES)
        end

        local childPath
        if type(k) == 'string' then
            childPath = ('%s.%s'):format(path, k)
        elseif type(k) == 'number' then
            childPath = ('%s[%d]'):format(path, k)
        else
            ancestors[value] = nil
            return false, ('%s is keyed by %s, and keys must be strings or numbers'):format(path, type(k))
        end

        local ok, why = walk(v, depth + 1, childPath, ancestors, budget)
        if not ok then
            ancestors[value] = nil
            return false, why
        end
    end

    ancestors[value] = nil
    return true
end

--- Is this a storable value?
--- @return boolean ok, string|nil reason
function CisStateRules.value(v)
    -- Depth 0 for the ROOT, so `LIMITS.DEPTH = 8` permits eight levels of
    -- nesting rather than seven. The old code started at 1 and only tested
    -- tables, so a document reading "nesting depth 8" admitted seven.
    return walk(v, 0, 'the value', {}, { bytes = 0 })
end

--- Does an ENCODED value fit the column?
---
--- Checked against the encoded form rather than the value, because that is what
--- the column actually holds: a 40-character string of Chinese characters is
--- three bytes each and is 3 KB before any JSON quoting.
function CisStateRules.encodedSize(encoded)
    if type(encoded) ~= 'string' then
        return false, 'the encoder did not return a string'
    end
    if #encoded > CisStateRules.LIMITS.VALUE_BYTES then
        return false, ('the encoded value is %d bytes; the limit is %d'):format(
            encoded and #encoded or 0, CisStateRules.LIMITS.VALUE_BYTES)
    end
    return true
end

--- Both checks, in the order that produces the most useful message.
---
--- Key first: a bad key is the caller's bug at the call site, and a value error
--- message that does not mention which key it was for is half an answer.
function CisStateRules.check(k, v)
    local ok, why = CisStateRules.key(k)
    if not ok then
        return false, why
    end
    return CisStateRules.value(v)
end

return CisStateRules