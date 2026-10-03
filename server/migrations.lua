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

-- The runner itself, as a table rather than a pair of locals.
--
-- It used to be `exports('Migrate', ...)` with everything above it private to
-- this file, which meant cis_core could only apply migrations by calling its own
-- export -- and calling your own export is the self trap documented above. So
-- the resource that OWNS a table could not create that table through the code
-- that is supposed to create it, and the only alternative was for server/state.lua
-- to hand-roll its own CREATE TABLE outside the ledger. That table would then
-- not be in the ledger, so it would not be recorded, so it would be created
-- again on every boot by code that had no idea whether it already existed.
--
-- `exports('Migrate', ...)` is now a two-line forwarder to this. The exported
-- name and signature are unchanged, so no consumer sees a difference.
CisMigrationRunner = {}

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
--- Apply a product's migrations. See `CisMigrationRunner.run`.
function CisMigrationRunner.run(owner, list)
    local valid, why = CisMigrations.validate(list)
    if not valid then
        return false, { error = ('invalid migration list: %s'):format(tostring(why)) }
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
end

--- Whether the ledger could be read. The state store asks this rather than
--- assuming, so a server with no database answers "unavailable" instead of
--- writing to a table it assumed existed.
function CisMigrationRunner.ready()
    local called, ok = pcall(ensureLedger)
    return called == true and ok == true
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
--- Is the CALLER on Security.AuthorizedResources?
---
--- This is the same posture cis_libs applies to its own mutating exports, and
--- it exists here for a specific reason: **Migrate runs arbitrary SQL.**
---
--- Every other export in this resource is namespaced. StateSet writes one key in
--- the caller's own namespace; the framework capability returns the caller's
--- own player object. Migrate takes a LIST OF SQL STRINGS and executes them
--- against the platform's connection, with no namespace, no ownership check and
--- no way to tell afterwards which resource issued them -- the ledger records
--- the `owner` string the caller CHOSE to pass, which is data, not proof.
---
--- So a resource with no database rights of its own could call this and read
--- and write anything the connection can reach. That is a real escalation, and
--- it is cheap to close: the caller has to be a name the operator wrote down.
---
--- NOT applied to the state exports, deliberately. Those are namespaced by
--- construction -- a caller can only ever reach its own rows -- and gating them
--- would mean every product that wants to store a setting had to be added to a
--- config file first, which is exactly the friction the state store exists to
--- remove. Arbitrary cross-namespace SQL is a different thing from writing your
--- own key.
local function invokingAllowed()
    local resource = GetInvokingResource()
    if type(resource) ~= 'string' or resource == '' then
        return false, 'this call came from the console, which has no resource behind it'
    end
    local list = Security and Security.AuthorizedResources
    if type(list) ~= 'table' then
        return false, 'Security.AuthorizedResources is not a table in configs/security_config.lua'
    end
    for _, name in ipairs(list) do
        if name == resource then
            return true
        end
    end
    return false, ('%s is not on Security.AuthorizedResources, and Migrate runs arbitrary SQL: '
        .. 'add it to configs/security_config.lua if you trust it with your database'):format(resource)
end

exports('Migrate', function(owner, list)
    local allowed, why = invokingAllowed()
    if not allowed then
        -- Refused, and said so. Not a silent no-op: a product whose schema did
        -- not apply will boot and behave as though it did, and the operator
        -- needs this line to know why.
        print(('[cis_core] migration from %s REFUSED: %s'):format(tostring(owner), tostring(why)))
        return false, { error = tostring(why) }
    end
    return CisMigrationRunner.run(owner, list)
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

-- =============================================================================
--  cis_core's OWN schema
--
--  This resource is the part of the platform allowed to hold data, and it holds
--  two things: the ledger above, and the state store below. Both are declared
--  HERE rather than in a CREATE TABLE inside the module that needs them, because
--  a table created outside the ledger is a table nothing records -- so it is
--  recreated on every boot by code that cannot tell whether it already exists,
--  and an operator who drops it by hand gets it back with no event.
--
--  Ids are numbered and stable. An id that is renamed after it has been applied
--  silently re-runs that migration, which is why the number is in the string and
--  not in a comment.
-- =============================================================================
local OWN_MIGRATIONS = {
    {
        id = '001_cis_state',
        statements = {
            -- The value is LONGTEXT, not JSON: the column holds an ENCODED value
            -- and the encoding is this resource's business, not the schema's. A
            -- JSON column would silently truncate anything over the driver's
            -- limit on some versions and hard-error on others, and the symptom
            -- would be a state value that comes back empty for one player and not
            -- the next.
            --
            -- updated_at is not decoration: it is what makes "this server was
            -- restored from four hours ago" answerable, and it is the only way to
            -- tell a stale cache from a stale row.
            'CREATE TABLE IF NOT EXISTS cis_state ('
                .. 'owner VARCHAR(64) NOT NULL, '
                .. 'k VARCHAR(64) NOT NULL, '
                .. 'v LONGTEXT NULL, '
                .. 'updated_at BIGINT NOT NULL DEFAULT 0, '
                .. 'PRIMARY KEY (owner, k)'
                .. ') DEFAULT CHARSET=utf8mb4',
        },
    },
}

CreateThread(function()
    if not exports['cis_libs']:WaitReady(15000) then
        print('[cis_core] cis_libs never became ready; the state store schema will not be applied')
        return
    end
    local ok, result = CisMigrationRunner.run('cis_core', OWN_MIGRATIONS)
    if not ok then
        -- Said plainly, because everything downstream depends on it. A state
        -- write against a missing table does not raise -- the driver answers nil
        -- -- so without this line the store simply stops working with no event.
        print(('[cis_core] the state store is NOT available: %s'):format(
            tostring(result and (result.error or result.reason) or 'unknown reason')))
        print('[cis_core] exports.StateSet / StateGet / StateAll will answer false until this is fixed')
        return
    end
    print(('[cis_core] state store schema ready (%d applied, %d already current)'):format(
        result.applied, result.skipped))
end)
