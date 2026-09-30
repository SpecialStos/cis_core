-- The migration runner, and the one table cis_core owns outright.
--
-- `cis_migrations` is the ledger: one row per applied migration id, with when
-- it was applied and how long it took. It is deliberately the ONLY table in
-- this resource, and that is a constraint rather than an accident -- a product
-- brings its own schema and registers its migrations here, so the platform
-- never grows a table that belongs to one product and gets dropped when that
-- product is uninstalled.
--
-- The runner is idempotent by id. Re-running a boot applies nothing, which is
-- what makes this safe on a server that restarts often, and what makes a
-- partially-failed migration retryable without an operator having to know
-- which half landed.

local LEDGER = 'cis_migrations'
local applied = {}
local loaded = false

-- Published so the boot report can read it without this resource exporting
-- something to itself. Calling yourself through `exports['<own name>']` is the
-- self trap: the exports table is an unbound method and the bracket form
-- swallows the first argument, so a self-call arrives with its arguments
-- shifted and raises nothing.
CisMigrationsApplied = applied

local function libs()
    return exports['cis_libs']
end

-- The ledger itself. Created with IF NOT EXISTS on every boot, which is a no-op
-- after the first and costs one round trip -- cheap next to the alternative of
-- a migration runner that cannot record its own work.
local function ensureLedger()
    if loaded then
        return true
    end
    libs():DbQuery(('CREATE TABLE IF NOT EXISTS %s ('
        .. 'id VARCHAR(128) NOT NULL PRIMARY KEY, '
        .. 'applied_at BIGINT NOT NULL, '
        .. 'duration_ms INT NOT NULL DEFAULT 0)'):format(LEDGER), {})
    local rows = libs():DbQuery(('SELECT id FROM %s'):format(LEDGER), {})
    for _, row in ipairs(rows or {}) do
        if type(row) == 'table' and row.id then
            applied[row.id] = true
        end
    end
    loaded = true
    return true
end

--- Apply a product's migrations.
---
--- @param owner   string  the resource name, used in log lines
--- @param list    table   { { id, statements } }
--- @return boolean ok, table result { applied = n, skipped = n, failed = id|nil }
---
--- Returns rather than raises, always. A product whose schema fails to apply
--- is a product that cannot work, and it needs to be able to say so and carry
--- on booting -- a raised error here would take the whole resource down and
--- leave the operator with a stack trace instead of a sentence.
exports('Migrate', function(owner, list)
    if not CisMigrations.validate(list) then
        return false, { error = 'invalid migration list' }
    end

    local ok, why = pcall(ensureLedger)
    if not ok then
        return false, { error = 'could not read the migration ledger' }
    end

    local result = { applied = 0, skipped = 0, failed = nil }
    for _, m in ipairs(CisMigrations.order(list)) do
        if applied[m.id] then
            result.skipped = result.skipped + 1
        else
            local startedAt = GetGameTimer()
            for _, step in ipairs(CisMigrations.plan({ m })) do
                local ran = libs():DbUpdate(step.sql, step.values)
                -- A nil here is "timed out or no driver", not "no rows". A DDL
                -- statement that returns nil has NOT been applied, and recording
                -- it as applied would mean this migration never runs again --
                -- which is a schema that is silently missing a column for the
                -- life of the server.
                if ran == nil then
                    result.failed = m.id
                    return false, result
                end
            end
            local duration = GetGameTimer() - startedAt
            libs():DbUpdate(
                ('INSERT INTO %s (id, applied_at, duration_ms) VALUES (?, ?, ?)'):format(LEDGER),
                { m.id, os.time(), duration })
            applied[m.id] = true
            result.applied = result.applied + 1
            print(('[cis_core] migration %s/%s applied in %dms'):format(
                tostring(owner), m.id, duration))
        end
    end
    if result.applied == 0 and result.skipped == 0 then
        print(('[cis_core] %s supplied no migrations'):format(tostring(owner)))
    end
    return true, result
end)

--- Which migrations are recorded as applied. For the debug command and for a
--- product that wants to know whether its schema is current without running it.
exports('AppliedMigrations', function()
    pcall(ensureLedger)
    local out = {}
    for id in pairs(applied) do
        out[#out + 1] = id
    end
    table.sort(out)
    return out
end)
