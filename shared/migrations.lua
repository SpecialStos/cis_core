-- Migrations: the ordered, recorded, once-only application of schema changes.
--
-- WHY THIS LIVES IN cis_core AND NOT IN cis_libs
--
-- cis_libs owns zero tables, and that is not a style preference -- it is what
-- makes trying the platform safe, because a server owner can delete a library
-- and lose nothing they cannot reinstall. The moment a library creates a table
-- on someone's database, deleting it becomes a data-loss decision instead of an
-- uninstall, and the whole "safe trial" property is gone.
--
-- So the schema lives here, in the product that is allowed to hold data, and it
-- reaches a driver only through cis_libs. A driver is an adapter you can swap
-- (oxmysql for mysql-connector and the data is untouched); a schema is the one
-- thing that has to survive the swap. Those two facts belong in different
-- places and this is the second one.
--
-- WHAT A MIGRATION IS
--
--   id          a stable string. The ledger is keyed on it, so it must never
--               change once applied -- renaming an applied migration silently
--               re-runs it.
--   statements  SQL, run in order, in one transaction where the driver supports
--               one. A migration that half-applies is worse than one that does
--               not apply at all, because the ledger will not record it and the
--               next boot will try again from the middle.

CisMigrations = {}

--- Parse "001_initial" into a sortable number, falling back to a hash for an id
--- that is not in that shape.
---
--- The fallback matters more than it looks. An id like "add_keys_table" sorts
--- before "001_initial" as a string, so a product that mixes shapes applies its
--- later migration first. Hashing puts unnumbered ids after numbered ones
--- deterministically rather than leaving the order to chance.
function CisMigrations.sortKey(id)
    local number = tostring(id):match('^(%d+)')
    if number then
        return 0, tonumber(number), tostring(id)
    end
    return 1, 0, tostring(id)
end

--- Order a migration list. Numbered ids first in numeric order, then the rest
--- alphabetically -- a stable, predictable order that does not depend on the
--- order the product happened to write them in.
function CisMigrations.order(list)
    local out = {}
    for i = 1, #list do
        out[i] = list[i]
    end
    table.sort(out, function(a, b)
        local ga, na, sa = CisMigrations.sortKey(a.id)
        local gb, nb, sb = CisMigrations.sortKey(b.id)
        if ga ~= gb then
            return ga < gb
        end
        if na ~= nb then
            return na < nb
        end
        return sa < sb
    end)
    return out
end

--- Validate a list before anything is executed.
---
--- The checks are cheap and the failure they prevent is not: a migration with a
--- nil id cannot be recorded, so it re-runs on every single boot, and a
--- migration with no statements silently does nothing while reporting success.
--- Both look fine from the console and are discovered weeks later.
function CisMigrations.validate(list)
    if type(list) ~= 'table' then
        return false, 'migrations must be a table'
    end
    local seen = {}
    for i = 1, #list do
        local m = list[i]
        if type(m) ~= 'table' then
            return false, ('migration %d is not a table'):format(i)
        end
        if type(m.id) ~= 'string' or m.id == '' then
            return false, ('migration %d has no id; it could never be recorded as applied'):format(i)
        end
        if seen[m.id] then
            return false, ('migration id %q appears twice; the second one would never run'):format(m.id)
        end
        seen[m.id] = true
        if type(m.statements) ~= 'table' or #m.statements == 0 then
            return false, ('migration %q has no statements'):format(m.id)
        end
        for s = 1, #m.statements do
            if type(m.statements[s]) ~= 'string' or m.statements[s] == '' then
                return false, ('migration %q statement %d is not a non-empty string'):format(m.id, s)
            end
        end
    end
    return true
end

--- Normalise the two accepted statement shapes into a flat list of
--- { sql, params } entries. A migration may write either
---
---   { id = 'x', statements = { 'CREATE TABLE ...' } }
---   { id = 'x', statements = { { sql = 'INSERT ...', values = { 1 } } } }
---
--- and a product that mixes them within one migration gets an error rather than
--- a half-applied migration.
function CisMigrations.plan(list)
    local out = {}
    for _, m in ipairs(list) do
        for _, s in ipairs(m.statements) do
            if type(s) == 'string' then
                out[#out + 1] = { sql = s, values = {} }
            else
                out[#out + 1] = { sql = s.sql, values = s.values or s.params or {} }
            end
        end
    end
    return out
end
