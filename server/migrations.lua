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
    -- Both queries are CHECKED. The ledger write used to be discarded, so a
    -- database that could not create the table still reported success, the
    -- SELECT below came back empty, and `loaded` was set anyway: every id then
    -- looked unapplied and every migration re-ran on every boot -- which for a
    -- schema migration means either a pile of errors or, worse, a pile of
    -- statements that succeed because they are all idempotent CREATE IF NOT
    -- EXISTS until one of them is not.
    local created = libs():DbQuery(('CREATE TABLE IF NOT EXISTS %s ('
        .. 'id VARCHAR(128) NOT NULL PRIMARY KEY, '
        .. 'applied_at BIGINT NOT NULL, '
        .. 'duration_ms INT NOT NULL DEFAULT 0)'):format(LEDGER), {})
    if created == nil then
        return false, ('could not create the %s ledger: no database provider answered'):format(LEDGER)
    end
    local rows = libs():DbQuery(('SELECT id FROM %s'):format(LEDGER), {})
    if rows == nil then
        return false, ('could not read the %s ledger'):format(LEDGER)
    end
    for _, row in ipairs(rows) do
        if type(row) == 'table' and row.id then
            applied[row.id] = true
        end
    end
    loaded = true
    return true
end

-- One migration's statements, in the order the planner produced them.
local function statementsFor(m)
    local out = {}
    for _, step in ipairs(CisMigrations.plan({ m })) do
        out[#out + 1] = { sql = step.sql, values = step.values }
    end
    return out
end

--- Run the statements and record the id, as one unit where the driver can do
--- it, and one-at-a-time where it cannot.
---
--- The ledger INSERT is the LAST query of the transaction on purpose. It used to
--- be a separate unchecked call after the fact, so a ledger write that failed
--- left the schema applied, the id unrecorded, and the next boot re-running a
--- migration that had already landed. Inside the transaction, the two either
--- both happen or neither does.
---
--- The honest limit: MySQL commits implicitly on DDL, so a transaction does NOT
--- roll back a `CREATE TABLE` or an `ALTER TABLE` that already ran. This makes
--- the DATA statements and the ledger write atomic, and it does not make a
--- schema change atomic. That is why a failure below reports `partial = true`
--- and says so in a sentence -- an operator needs to know which statements
--- landed, and the runner is the only thing in the platform that can tell them.
local function applyOne(m)
    local startedAt = GetGameTimer()
    local steps = statementsFor(m)
    local ledgerSql = ('INSERT INTO %s (id, applied_at, duration_ms) VALUES (?, ?, ?)'):format(LEDGER)

    local queries = {}
    for _, s in ipairs(steps) do
        queries[#queries + 1] = { query = s.sql, values = s.values }
    end

    -- The ledger row is the last query, so a driver with transactions makes the
    -- schema change and its own record one unit.
    local duration = GetGameTimer() - startedAt
    queries[#queries + 1] = { query = ledgerSql, values = { m.id, os.time(), duration } }

    local txOk, txWhy = libs():DbTransaction(queries)
    if txOk == true then
        return true, nil, false, GetGameTimer() - startedAt
    end

    -- No transaction: a driver without one refuses, loudly and with a reason,
    -- which is exactly what we want to hear. Fall through to the sequential
    -- path rather than refusing the migration outright.
    for _, s in ipairs(steps) do
        local ran = libs():DbUpdate(s.sql, s.values)
        if ran == nil then
            return false, ('statement failed: %s'):format(tostring(s.sql)), true
        end
    end
    local recorded = libs():DbUpdate(ledgerSql, { m.id, os.time(), GetGameTimer() - startedAt })
    if recorded == nil then
        return false, 'the statements ran but the ledger write did not; this migration will re-run next boot', true
    end
    if txWhy then
        print(('[cis_core] migration %s ran WITHOUT a transaction (%s)'):format(m.id, tostring(txWhy)))
    end
    return true, nil, false, GetGameTimer() - startedAt
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

    -- Three values, not two. `ensureLedger` answers (true) on success and
    -- (false, reason) on failure, so `pcall` returns (called, ok, why) -- and
    -- taking only two of them reported a failed ledger as the string "false",
    -- which is the one thing an operator reading a boot log cannot act on.
    local called, ledgerOk, ledgerWhy = pcall(ensureLedger)
    if not called then
        return false, { error = ('the migration ledger raised: %s'):format(tostring(ledgerOk)) }
    end
    if ledgerOk ~= true then
        return false, { error = tostring(ledgerWhy or 'the migration ledger is unavailable') }
    end

    local result = { applied = 0, skipped = 0, failed = nil, partial = false, reason = nil }
    for _, m in ipairs(CisMigrations.order(list)) do
        if applied[m.id] then
            result.skipped = result.skipped + 1
        else
            local ran, reason, partial, duration = applyOne(m)
            if not ran then
                result.failed = m.id
                result.reason = reason
                result.partial = partial == true
                print(('[cis_core] migration %s/%s FAILED: %s'):format(
                    tostring(owner), m.id, tostring(reason)))
                if result.partial then
                    print(('[cis_core] migration %s may be PARTIALLY applied -- check the schema by hand before restarting')
                        :format(tostring(m.id)))
                end
                return false, result
            end
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
