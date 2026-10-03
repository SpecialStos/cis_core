-- =============================================================================
--  test/framework_env.lua -- a fake FiveM server, for ONE scenario
--
--  WHY THIS EXISTS, AND WHY IT IS NOT "TESTING THE MOCK"
--
--  DOCUMENTATION.md says the framework abstraction is deliberately not
--  unit-tested, because testing a mock proves nothing about the framework.
--  That is true of the ADAPTER and false of the DECISION, and the second test
--  written in this repository (server/authority.lua, whose stubs are the same
--  shape as these) found a shipped vulnerability. So the distinction is worth
--  being precise about:
--
--      NOT modelled here: what QBCore actually does with money, whether an
--      ESX xPlayer has getAccounts, whether qbx_core still fires a legacy
--      event. Those are facts about other people's code, and no stub can be
--      honest about them.
--
--      Modelled here, and under test: WHICH branch cis_core takes for a given
--      world, what it does with the answer, and whether the two halves of the
--      resource agree. That logic is this resource's, it is where every bug
--      found so far in this file has lived, and it is exactly what a stub can
--      be honest about.
--
--  Every stub below answers a question about the WORLD ("is qb-core started",
--  "does this export exist"), never a question about the DECISION. If you find
--  yourself tempted to add a stub that decides which branch the code should
--  take, that is the line, and the test is in the wrong place.
--
--  ONE STATE PER SCENARIO. Each scenario file is loaded into its own Lua state
--  by test/scenarios.js, so `detect()` can be re-run against a different world
--  without the previous scenario's globals surviving it.
-- =============================================================================

FrameworkEnv = {}

-- ---------------------------------------------------------------- the world

local env = {
    -- resource name -> 'started' | 'stopped' | 'missing'
    resources = {},
    -- 'resource:Export' -> function, for every export that EXISTS
    exports = {},
    -- resource name -> { version = '1.2.3' }
    metadata = {},
    -- 1-based list of connected player sources
    players = {},
    -- everything printed, captured
    printed = {},
    -- console commands, captured the way threads are
    commands = {},
    -- threads registered by CreateThread, run explicitly by the scenario
    threads = {},
    -- net events and handlers registered by the file under test
    netEvents = {},
    handlers = {},
    -- exports registered BY the file under test
    registered = {},
    -- the fake clock
    now = 0,
}

FrameworkEnv.env = env

local MAX_WAIT_STEPS = 2000

-- A CLOCK THAT MOVES. `waitResource` polls `GetGameTimer() < deadline` and
-- yields with `Wait(50)`, so a clock that never advances turns "resource never
-- started" into an infinite loop inside the test rather than a failed
-- assertion. Bounded by MAX_WAIT_STEPS so a genuinely stuck loop still fails
-- rather than hangs CI.
function _G.GetGameTimer()
    return env.now
end

function _G.Wait(ms)
    env.now = env.now + (tonumber(ms) or 0)
    if env.now > MAX_WAIT_STEPS * 100 then
        error('the fake clock passed its ceiling: something is polling forever', 2)
    end
end

function _G.GetResourceState(name)
    return env.resources[name] or 'missing'
end

function _G.GetResourceMetadata(name, key)
    local m = env.metadata[name]
    return m and m[key] or nil
end

function _G.GetPlayers()
    local out = {}
    for _, src in ipairs(env.players) do
        out[#out + 1] = tostring(src)
    end
    return out
end

function _G.GetPlayerName(src)
    for _, p in ipairs(env.players) do
        if p == src then
            return ('player_%d'):format(src)
        end
    end
    return nil
end

function _G.GetMaxPlayers()
    return 64
end

function _G.GetCurrentResourceName()
    return 'cis_core'
end

function _G.GetInvokingResource()
    -- Settable, because the state store's whole security property is derived
    -- from this answer and a scenario has to be able to be a DIFFERENT
    -- resource to prove that two of them cannot see each other.
    return env.invokingResource or 'cis_core'
end

function _G.DropPlayer(src, reason)
    env.dropped = { src = src, reason = reason }
end

function _G.IsDuplicityVersion()
    return true
end

function _G.print(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        parts[i] = tostring((select(i, ...)))
    end
    env.printed[#env.printed + 1] = table.concat(parts, '\t')
end

-- Threads are CAPTURED, not run. A scenario decides when the boot thread runs,
-- because the order is what several of these tests are about -- and a
-- CreateThread that ran eagerly would make every scenario's timing identical
-- and therefore untestable.
function _G.CreateThread(fn)
    env.threads[#env.threads + 1] = fn
    return #env.threads
end

function _G.RegisterCommand(name, handler, restricted)
  env.commands[#env.commands + 1] = { name = name, handler = handler, restricted = restricted }
end

--- Fire a captured console command the way the runtime does.
---
--- `restricted` is passed back to the caller so a scenario can assert on the
--- flag the command was REGISTERED with, not only on what it does. A command
--- that gates on the caller is still worth marking restricted, because the
--- flag is what stops the command appearing in a player's help list.
function FrameworkEnv.runCommand(name, src)
  for _, entry in ipairs(env.commands) do
    if entry.name == name then
      entry.handler(src, {}, 0)
      return true
    end
  end
  return false
end

function FrameworkEnv.commandNamed(name)
  for _, entry in ipairs(env.commands) do
    if entry.name == name then return entry end
  end
  return nil
end

function _G.RegisterNetEvent(name, handler)
    env.netEvents[#env.netEvents + 1] = { name = name, handler = handler or env.netEvents[#env.netEvents + 1] }
end

function _G.AddEventHandler(name, handler)
    env.handlers[#env.handlers + 1] = { name = name, handler = handler }
end

function _G.TriggerEvent() end
function _G.TriggerClientEvent() end
function _G.TriggerServerEvent() end

-- ------------------------------------------------------------- the exports

-- The proxy. Indexing a resource name yields a table; indexing an export name
-- on THAT yields a CALLABLE the scenario declared, or nil.
--
-- THE WRAPPER IS THE WHOLE POINT, and getting it wrong makes every scenario
-- test the wrong thing.
--
-- In Lua, `exports['r']:Foo(x)` evaluates as `exports['r'].Foo(exports['r'], x)` --
-- the `self` is the first argument. FiveM's export proxy consumes it: the export
-- receives `(x)`. So the mock returns a closure that DROPS the first argument.
--
-- Without that, `DetectFramework` in cis_core arrives with the exports table as
-- its `configured` parameter, `(configured or 'AUTO'):upper()` raises on a table,
-- and the scenario fails with "attempt to call a nil value (method 'upper')" --
-- which reads like a bug in cis_core and is a bug in the mock. That failure is
-- what this comment was written after seeing.
--
-- A consequence worth stating: because the wrapper is installed through
-- `__index`, the `exports['r']['Foo'](x)` form also drops its first argument
-- here, where in FiveM it does not. So this mock CANNOT detect the self trap
-- documented in init.lua -- both call shapes reach the export the same way. The
-- CI grep is what covers that, and it is why the grep exists rather than a
-- test.
--
-- nil is the other half of it. A declared-absent export indexes to nil, so
-- calling it raises "attempt to call a nil value", which is what a real FiveM
-- `exports.resource.missingName()` does and what the code under test pcalls
-- against. Modelling it as "return a function that returns nil" instead would
-- make every existence probe in cis_core look correct.
local resourcesMt = {
    __index = function(_, exportName)
        -- Third-party exports the scenario declared...
        local declared = env.exports[exportName]
        -- ...and THIS RESOURCE'S OWN, which the file under test registered with
        -- `exports('Name', fn)`. It has to resolve too: the state store is
        -- exercised through `exports['cis_core']:StateSet(...)` exactly as a
        -- product would call it, and a resource's own exports ARE callable
        -- from inside itself in FiveM.
        if declared == nil then
            for _, entry in ipairs(env.registered) do
                if entry.name == exportName then
                    declared = entry.fn
                    break
                end
            end
        end
        if declared == nil then
            return nil
        end
        return function(_, ...)
            return declared(...)
        end
    end,
}

_G.exports = setmetatable({}, {
    -- `exports('Name', fn)` -- the REGISTRATION form, used by the file under test
    __call = function(_, name, fn)
        env.registered[#env.registered + 1] = { name = name, fn = fn }
    end,
    -- `exports['resource']` -- the CALL form
    __index = function(_, resourceName)
        return setmetatable({}, resourcesMt)
    end,
})

-- ================================================================== helpers

--- Declare a resource as started, with an optional version.
--- Declare the players who are connected.
---
--- A helper rather than `Env.env.players = {...}` because a scenario reaching
--- into `FrameworkEnv` for a field that lives on the world table sets a NEW
--- field, silently, and the world keeps its empty list. That happened: the
--- first QBCore scenario reported a connected player and had none, and the
--- symptom was four unrelated assertion failures rather than one obvious one.
function FrameworkEnv.connect(sources)
    env.players = {}
    for i, src in ipairs(sources) do
        env.players[i] = tonumber(src)
    end
    return env.players
end

-- A fake database, because the state store is the one thing here that has to
-- be tested against something that behaves like a driver rather than against a
-- return value.
--
-- It is deliberately NOT a SQL engine. It answers the five shapes the runner
-- and the store actually emit -- CREATE, SELECT, INSERT, UPDATE, DELETE -- and
-- it answers them the way oxmysql does, including the parts that matter:
-- DbUpdate returns AFFECTED ROWS, and nil means "no driver answered" rather
-- than "no rows". A stub that returned true for everything would leave every
-- failure path in server/state.lua untested, which is the opposite of the
-- point.
--
-- THE CONSTRAINT, stated rather than discovered: the only SQL in this resource
-- is the SQL in server/migrations.lua and server/state.lua. Every WHERE is a
-- list of `col = ?` joined by AND, and every SET is a list of `col = ?` joined
-- by a comma. Neither `=` nor `?` contains a comma, so splitting on commas and
-- on " AND " is exact rather than approximate -- which is also why this is a
-- fake and not a parser.
function FrameworkEnv.installFakeDb(options)
    local opts = options or {}
    local db = {
        tables = {},
        calls = {},
        -- Flipped mid-scenario to simulate a driver that has gone away: a state
        -- the store has to survive WITHOUT latching off for the life of the
        -- server.
        broken = false,
        autoIncrement = 1,
    }

    -- Backticks are STRIPPED, and that is not a nicety.
    --
    -- The first version of this fake spelled the optional backtick as `` `? ``,
    -- which is the trap every Lua pattern has: there is no `?` quantifier, so
    -- that reads as "a backtick followed by a literal question mark" and matches
    -- nothing at all. Every SELECT therefore parsed as unknown and answered
    -- nil, which reached the migration runner as "could not read the ledger".
    --
    -- cis_core emits no backticks at all -- server/state.lua and
    -- server/migrations.lua interpolate a constant table name with %s -- so
    -- stripping is both correct and simpler than writing every pattern twice.
    -- IDENTIFIERS ARE `[%w_]+`, NOT `%w+`. There is no `_` in `%w` -- Lua's
    -- word class is letters and digits ONLY -- so `(%w+)` captures `cis` from
    -- `cis_migrations` and every pattern anchored on a table name then failed to
    -- match the rest of the line. Every SELECT parsed as unknown, answered nil,
    -- and reached the migration runner as "could not read the ledger".
    --
    -- The same trap is why the backticks are stripped rather than made
    -- optional: `?` is not a quantifier in a Lua pattern, so `` `? `` means
    -- "a backtick followed by a literal question mark" and matches nothing.
    -- cis_core emits no backticks at all, so stripping is correct and simpler.

    local function trim(s)
        local v = tostring(s):gsub('^%s+', ''):gsub('%s+$', '')
        return v
    end

    -- `owner = ? AND k = ?` -> { 'owner = ?', 'k = ?' }
    local function splitAnd(where)
        local out = {}
        if not where then return out end
        for part in (where .. ' AND '):gmatch('(.-)%s+AND%s+') do
            out[#out + 1] = trim(part)
        end
        return out
    end

    -- `owner = ?, k = ?, v = ?` -> { 'owner', 'k', 'v' }
    local function splitSet(setPart)
        local out = {}
        for part in tostring(setPart):gmatch('[^,]+') do
            local column = trim(part):match('([%w_]+)%s*=')
            if column then out[#out + 1] = column end
        end
        return out
    end

    -- EVERY PATTERN IS DESTRUCTURED INTO ONE VARIABLE PER CAPTURE, and that is
    -- the third version of this function, each one fixing the last.
    --
    -- `local a, b = s:match(p)` where `p` has THREE captures does not give you
    -- "a and b" -- it gives you the FIRST TWO and throws the third away, with no
    -- error. Written as `local where = s:match(threeCaptures)` you get the
    -- FIRST capture, which is the SELECT list, which is a string, which is
    -- truthy -- so the branch fires and every field after it is wrong.
    --
    -- That is what happened here twice: `SELECT k FROM cis_state WHERE owner =
    -- ?` parsed with `table = "k"` and a WHERE clause of "k", matched no rows,
    -- and the store's read-before-write upsert took the INSERT path every
    -- time. A duplicate row is the one thing an upsert must not produce, and
    -- the fake was the thing producing it.
    local function parse(sql)
        local s = trim(sql)

        local createTable = s:match('^CREATE TABLE IF NOT EXISTS%s+([%w_]+)')
        if createTable then return { kind = 'create', table = createTable } end

        local insertTable, insertColumns = s:match('^INSERT INTO%s+([%w_]+)%s*%(([^%)]*)%)')
        if insertColumns then
            local cols = {}
            for column in insertColumns:gmatch('[^,]+') do
                cols[#cols + 1] = trim(column)
            end
            return { kind = 'insert', table = insertTable, columns = cols }
        end

        local updateTable, updateSet, updateWhere =
            s:match('^UPDATE%s+([%w_]+)%s+SET%s+(.-)%s+WHERE%s+(.*)$')
        if updateWhere then
            return { kind = 'update', table = updateTable, set = splitSet(updateSet), where = splitAnd(updateWhere) }
        end

        local deleteTable, deleteWhere = s:match('^DELETE FROM%s+([%w_]+)%s+WHERE%s+(.*)$')
        if deleteWhere then
            return { kind = 'delete', table = deleteTable, where = splitAnd(deleteWhere) }
        end
        local deleteAll = s:match('^DELETE FROM%s+([%w_]+)$')
        if deleteAll then return { kind = 'delete', table = deleteAll, where = {} } end

        local groupList, groupTable, groupCol =
            s:match('^SELECT%s+(.-)%s+FROM%s+([%w_]+)%s+GROUP BY%s+(.*)$')
        if groupCol then
            return { kind = 'select', table = groupTable, where = {}, selectList = groupList, grouped = true }
        end

        local selList, selTable, selWhere =
            s:match('^SELECT%s+(.-)%s+FROM%s+([%w_]+)%s+WHERE%s+(.*)$')
        if selWhere then
            return { kind = 'select', table = selTable, where = splitAnd(selWhere), selectList = selList }
        end

        local plainList, plainTable = s:match('^SELECT%s+(.-)%s+FROM%s+([%w_]+)$')
        if plainTable then
            return { kind = 'select', table = plainTable, where = {}, selectList = plainList }
        end

        return { kind = 'unknown', sql = s }
    end

    -- `from` is HOW MANY placeholders come before the WHERE: 0 for a bare
    -- WHERE, and the SET column count for an UPDATE.
    --
    -- `i = from + 1`, not `from`. Lua's `params` is 1-BASED, and starting the
    -- index at `from` makes every WHERE read one placeholder too early: the
    -- first clause compares correctly and the second compares the WHERE value
    -- against a SET value, so nothing ever matches. That is why the store's
    -- read-before-write upsert took the INSERT path on every call and produced
    -- a duplicate row -- which is the one thing an upsert must never do.
    local function matches(row, where, params, from)
        if not where or #where == 0 then return true end
        local i = (from or 0) + 1
        for _, clause in ipairs(where) do
            local column = clause:match('([%w_]+)%s*=%s*%?')
            if not column then return false end
            if row[column] ~= params[i] then return false end
            i = i + 1
        end
        return true
    end

    -- Every export records its call and refuses while the driver is "broken",
    -- which is how the store's failure path gets exercised at all.
    local function note(kind, sql)
        db.calls[#db.calls + 1] = { kind = kind, sql = trim(sql) }
        return not db.broken
    end

    FrameworkEnv.export('DbQuery', function(sql, params)
        local live = note('query', sql)
        if not live then return nil end
        local p = parse(sql)
        local values = params or {}
        if p.kind == 'create' then
            db.tables[p.table] = db.tables[p.table] or {}
            return {}
        end
        if p.kind ~= 'select' then return nil end
        local out = {}
        for _, row in ipairs(db.tables[p.table] or {}) do
            if matches(row, p.where, values, 0) then out[#out + 1] = row end
        end
        if p.grouped then
            -- GROUP BY owner, collapsing to one row per owner.
            local grouped = {}
            local order = {}
            for _, row in ipairs(out) do
                if grouped[row.owner] == nil then
                    order[#order + 1] = row.owner
                    grouped[row.owner] = { owner = row.owner, n = 0 }
                end
                grouped[row.owner].n = grouped[row.owner].n + 1
            end
            local counts = {}
            for _, owner in ipairs(order) do
                counts[#counts + 1] = { owner = owner, n = grouped[owner].n }
            end
            return counts
        end
        return out
    end)

    FrameworkEnv.export('DbSingle', function(sql, params)
        local live = note('single', sql)
        if not live then return nil end
        local p = parse(sql)
        if p.kind ~= 'select' then return nil end
        for _, row in ipairs(db.tables[p.table] or {}) do
            if matches(row, p.where, params or {}, 0) then return row end
        end
        return nil
    end)

    local function insertRow(p, values)
        if opts.refuseInserts then return nil end
        local rows = db.tables[p.table] or {}
        db.tables[p.table] = rows
        local row = {}
        for index, column in ipairs(p.columns) do
            row[column] = values[index]
        end
        rows[#rows + 1] = row
        return db.autoIncrement
    end

    FrameworkEnv.export('DbInsert', function(sql, params)
        local live = note('insert', sql)
        if not live then return nil end
        local p = parse(sql)
        if p.kind ~= 'insert' then return nil end
        local id = insertRow(p, params or {})
        if id == nil then return nil end
        db.autoIncrement = db.autoIncrement + 1
        return id
    end)

    FrameworkEnv.export('DbUpdate', function(sql, params)
        local live = note('update', sql)
        if not live then return nil end
        local p = parse(sql)
        local values = params or {}

        -- The ledger's own INSERT, for a driver that arrives here instead of at
        -- DbInsert.
        if p.kind == 'insert' then
            return insertRow(p, values) and 1 or nil
        end

        -- DDL AND DELETE ARRIVE HERE TOO, and a fake that refuses them is not
        -- faithful. `applyOne` in server/migrations.lua runs every statement
        -- through DbUpdate when the driver has no transaction, so the schema
        -- migrations -- which are all CREATE TABLE -- go down this path. The
        -- first version of this fake rejected them, the cis_state migration
        -- failed with "statement failed: CREATE TABLE ...", and the scenario
        -- reported a broken resource when the resource was fine.
        if p.kind == 'create' then
            db.tables[p.table] = db.tables[p.table] or {}
            return 0
        end
        if p.kind == 'delete' then
            local kept = {}
            for _, row in ipairs(db.tables[p.table] or {}) do
                if not matches(row, p.where, values, 0) then
                    kept[#kept + 1] = row
                end
            end
            local removed = #(db.tables[p.table] or {}) - #kept
            db.tables[p.table] = kept
            return removed
        end
        if p.kind ~= 'update' then return nil end

        local rows = db.tables[p.table] or {}
        local affected = 0
        for _, row in ipairs(rows) do
            if matches(row, p.where, values, #p.set) then
                for index, column in ipairs(p.set) do
                    row[column] = values[index]
                end
                affected = affected + 1
            end
        end
        return affected
    end)

    FrameworkEnv.export('DbDelete', function(sql, params)
        local live = note('delete', sql)
        if not live then return nil end
        return nil
    end)

    -- Transactions are OFF by default, because only oxmysql supports one. A
    -- fake that pretends otherwise is how driver-specific behaviour becomes
    -- load-bearing without anybody having decided it should be.
    FrameworkEnv.export('DbTransaction', function(queries)
        note('transaction', ('%s queries'):format(type(queries) == 'table' and #queries or 0))
        if db.broken then return false, 'no database provider answered' end
        if not opts.transactions then return false, 'this driver has no transaction support' end
        return true
    end)

    return db
end

--- Who GetInvokingResource() answers for. The state store's whole security
--- property is derived from this answer, so a scenario has to be able to be a
--- DIFFERENT resource in order to prove that two of them cannot see each other.
function FrameworkEnv.invokingAs(resource)
    FrameworkEnv.env.invokingResource = resource
end

function FrameworkEnv.resource(name, version)
    env.resources[name] = 'started'
    env.metadata[name] = { version = version }
end

--- Declare a resource as present but NOT started.
function FrameworkEnv.stoppedResource(name)
    env.resources[name] = 'stopped'
end

--- Declare an export that exists. `fn` is the behaviour under test's
--- dependency, so it should answer what the REAL export answers -- or, for a
--- scenario about a framework that changed, what it used to answer.
function FrameworkEnv.export(name, fn)
    env.exports[name] = fn
end

--- A framework object shaped the way QBCore/qbx_core hands one back.
---
--- NOT a mock of QBCore's behaviour. A shape, and nothing else: the tests
--- assert which fields cis_core READS, so the shape must be the real one and
--- the methods must do nothing clever.
-- NOT A CONSTRUCTOR LITERAL, AND THAT IS THE POINT.
--
-- The obvious way to write this is `local p = { Functions = { AddMoney =
-- function() ... p.PlayerData ... end } }`, and it does not work: the scope of a
-- local begins AFTER its declaration statement, so `p` inside the constructor
-- is the outer one -- a GLOBAL here. Every stub that closed over `p` raised
-- "attempt to index a nil value (global 'p')", which reads like a bug in the
-- framework bridge and is a bug in the mock.
--
-- Declare, then assign. `local p` alone puts the local in scope for everything
-- that follows, including a constructor that mentions it.

function FrameworkEnv.qbPlayer(overrides)
    local p
    p = {
        PlayerData = {
            source = 1,
            citizenid = 'ABC12345',
            license = 'license:0000',
            charinfo = { firstname = 'John', lastname = 'Doe' },
            job = { name = 'police', grade = 3 },
            money = { cash = 500, bank = 1200 },
            items = { { name = 'water', amount = 2, slot = 1 } },
            metadata = { handcuffed = false },
        },
        -- NO leading `_` for self, and that is deliberate.
        --
        -- QBCore declares these as `function Player.Functions.AddMoney(moneytype,
        -- amount, reason)` -- declared with a dot, so the implicit first
        -- parameter is the Functions table and the CALLER passes only the real
        -- arguments. cis_core therefore calls `player.Functions.AddMoney(moneyType,
        -- amount)` with a dot, and that is CORRECT.
        --
        -- The first version of this stub took `(_, moneyType, amount)`, so
        -- amount arrived nil and the scenario died with "attempt to compare
        -- number with nil" -- which reads like a bug in the money path and was a
        -- bug in the mock. It is recorded here because the instinct to "fix"
        -- cis_core's dot call into a colon call is exactly the mistake this
        -- comment exists to stop, and it would pass every test in the file.
        -- `QBCore.Functions.GetPlayers()` returns SOURCE IDS -- see the note in
        -- framework_server.lua. The fixture used to return player objects,
        -- which is how a shape bug survived: the fixture was written to match
        -- the code rather than the framework. It is now faithful, and the
        -- scenario that depends on it asserts the resolved shape.
        Functions = {
            GetPlayers = function() return { 1, 2 } end,
            AddMoney = function(moneyType, amount) return tonumber(amount) and amount > 0 end,
            RemoveMoney = function(moneyType, amount) return tonumber(amount) and amount > 0 end,
            HasPermission = function() return true end,
        },
    }
    p.Functions.SetJob = function(job, grade)
        p.PlayerData.job = { name = job, grade = grade }
    end
    for k, v in pairs(overrides or {}) do
        p[k] = v
    end
    return p
end

function FrameworkEnv.esxPlayer(overrides)
    local p
    p = {
        identifier = 'license:0000',
        -- ESX's account store, so the stubs below can decide what is a real
        -- account rather than accepting every string.
        accounts = { cash = 500, bank = 1200 },
        job = { name = 'police', grade = 3 },
        -- The parentheses are REQUIRED and not stylistic: a table constructor
        -- is a simpleexp and cannot begin an index chain, so `{...}[key]` is a
        -- syntax error and `({...})[key]` is the only way to index a literal.
        get = function(key) return ({ handcuffed = false })[key] end,
    }

    -- EVERY method below takes `self` FIRST, because ESX declares them as
    -- `function self.addAccountMoney(accountName, money, reason)` -- so a
    -- caller must use a COLON. The QBCore factory above is the opposite, and
    -- getting either one wrong makes the scenario pass while the bridge is
    -- broken, which is the whole reason this note exists.

    -- Faithful to es_extended/server/classes/player.lua, which RAISES on an
    -- unknown account and on a non-positive amount from 1.8.5 onward. A stub
    -- that accepted anything would make cis_core's pcall-based success check
    -- look correct when it had never actually been exercised.
    function p.addAccountMoney(self, account, amount)
        if type(account) ~= 'string' or p.accounts[account] == nil then
            error(('Tried To Add To Invalid Account %s For Player %s!'):format(
                tostring(account), tostring(self.source)), 2)
        end
        if type(amount) ~= 'number' or amount <= 0 then
            error('Cannot add a non-positive amount', 2)
        end
        p.accounts[account] = p.accounts[account] + amount
        return true
    end

    function p.removeAccountMoney(self, account, amount)
        if type(account) ~= 'string' or p.accounts[account] == nil then
            error(('Tried To Remove From Invalid Account %s For Player %s!'):format(
                tostring(account), tostring(self.source)), 2)
        end
        if type(amount) ~= 'number' or amount <= 0 then
            error('Cannot remove a non-positive amount', 2)
        end
        p.accounts[account] = p.accounts[account] - amount
        return true
    end

    function p.setJob(self, job, grade)
        p.job = { name = job, grade = grade }
    end

    function p.getGroup(self)
        -- Never nil in real ESX: the DB defaults the group to 'user'. Returning
        -- a group rather than nil is what makes the permission check meaningful
        -- and what stops a bridge from treating "no group" as "superadmin".
        return 'user'
    end

    function p.getName(self)
        return 'JohnDoe'
    end

    function p.getAccounts(self)
        return { { name = 'cash', money = 500 }, { name = 'bank', money = 1200 } }
    end

    for k, v in pairs(overrides or {}) do
        p[k] = v
    end
    return p
end

--- Declare the players who are connected.
function FrameworkEnv.runThreads()
    for i = 1, #env.threads do
        env.threads[i]()
    end
end

--- Find a handler across BOTH registration lists.
---
--- `RegisterNetEvent` and `AddEventHandler` are two doors into the same room: in
--- FiveM a TriggerEvent reaches handlers registered either way, and so does a
--- client-triggered net event. Searching one list and calling the helper "fire
--- it as the server would" is how a scenario reports that a handler never fired
--- when it is registered through the other door -- which is exactly what
--- happened the first time this ran.
local function findHandler(name)
    local found = nil
    for _, e in ipairs(env.netEvents) do
        if e.name == name then
            found = e.handler
        end
    end
    for _, e in ipairs(env.handlers) do
        if e.name == name then
            found = e.handler
        end
    end
    return found
end

--- Fire a registered event as a CLIENT would, with `source` set to the player.
function FrameworkEnv.triggerNet(name, from, ...)
    local handler = findHandler(name)
    if not handler then
        return false, 'no handler registered for ' .. name
    end
    _G.source = from
    local ok, err = pcall(handler, ...)
    _G.source = 0
    if not ok then
        return false, err
    end
    return true
end

--- Fire a registered event as the SERVER would (`source` is 0).
function FrameworkEnv.triggerServer(name, ...)
    local handler = findHandler(name)
    if not handler then
        return false, 'no handler registered for ' .. name
    end
    _G.source = 0
    local ok, err = pcall(handler, ...)
    _G.source = 0
    if not ok then
        return false, err
    end
    return true
end

function FrameworkEnv.printedMatching(needle)
    local n = 0
    for _, line in ipairs(env.printed) do
        if line:find(needle, 1, true) then
            n = n + 1
        end
    end
    return n
end

function FrameworkEnv.reset()
    env.resources = {}
    env.exports = {}
    env.metadata = {}
    env.players = {}
    env.printed = {}
    env.commands = {}
    env.threads = {}
    env.netEvents = {}
    env.handlers = {}
    env.registered = {}
    env.now = 0
    env.dropped = nil
end

-- =============================================================================
--  cis_libs's DetectFramework, modelled
--
--  cis_core CALLS this across the boundary -- it cannot share cis_libs's Lua
--  state, which is the whole of the bug fixed in 1.1.0's first commit (a bare
--  `CisDetect` global is nil here, always). So the scenarios have to supply it.
--
--  This is a MODEL of cis_libs/shared/detect.lua, transcribed from it, not a
--  copy of it: cis_core is its own repository and its CI checks out only
--  cis_core, so `dofile('../cis_libs/...')` would work on this machine and fail
--  on every push.
--
--  THE COUPLING THIS CREATES IS REAL AND IS NOT HIDDEN: if cis_libs changes its
--  framework table, these scenarios keep passing while production changes. What
--  they DO prove is everything on cis_core's side of the boundary -- which
--  branch it takes, what it does with the answer, and whether the two realms
--  agree -- and that is where every bug found so far in this file has lived.
--
--  Transcribed from cis_libs at the time of writing; see PLATFORM_NOTES.md.
-- =============================================================================

-- cis_libs `CisDetect.FRAMEWORKS`, most specific first. The ORDER is the
-- contract: a qbx_core server also has qb-* resources on disk, and a naive
-- "is anything started" scan reports whichever it finds first.
local FRAMEWORKS = {
    { name = 'QBOX', resource = 'qbx_core', probe = 'GetPlayer' },
    { name = 'QBCORE', resource = 'qb-core', probe = 'GetCoreObject' },
    { name = 'ESX', resource = 'es_extended', probe = 'getSharedObject' },
}

--- Install the cis_libs exports cis_core's boot path calls, modelling
--- cis_libs's real implementations. A scenario overrides any of them after
--- this call, and that override is the scenario's statement about the world.
function FrameworkEnv.installCisLibs()
    local function isStarted(name)
        return (env.resources[name] or 'missing') == 'started'
    end

    local function version(name)
        local m = env.metadata[name]
        return m and m.version or nil
    end

    -- cis_core's own probeExport: resolve the reference, do not call it.
    local function probe(resource, exportName)
        if type(exportName) ~= 'string' or exportName == '' then
            return true
        end
        local ok, fn = pcall(function()
            return exports[resource][exportName]
        end)
        if not ok or fn == nil then
            return false
        end
        if type(fn) == 'function' then
            return true
        end
        return type(fn) == 'table' and rawget(fn, '__cfx_functionReference') ~= nil
    end

    FrameworkEnv.export('DetectFramework', function(configured, custom)
        configured = (configured or 'AUTO'):upper()
        if type(custom) == 'table' and type(custom.resource) == 'string' and custom.resource ~= '' then
            if not isStarted(custom.resource) then
                return { name = 'NONE', how = 'custom', resource = nil, version = nil,
                    reason = ('custom framework %q is not started'):format(custom.resource) }
            end
            local exportName = custom.getPlayer or custom.probe
            if type(exportName) == 'string' and exportName ~= '' and not probe(custom.resource, exportName) then
                return { name = 'NONE', how = 'custom', resource = nil, version = nil,
                    reason = ('custom framework %q exposes no %q export'):format(custom.resource, exportName) }
            end
            return { name = (custom.name or 'CUSTOM'):upper(), resource = custom.resource,
                version = version(custom.resource), how = 'custom',
                reason = ('custom framework %q'):format(custom.resource) }
        end
        if configured ~= 'AUTO' and configured ~= 'NONE' then
            for _, known in ipairs(FRAMEWORKS) do
                if known.name == configured then
                    local up = isStarted(known.resource)
                    return { name = known.name, resource = up and known.resource or nil,
                        version = up and version(known.resource) or nil, how = 'configured', wanted = true,
                        reason = up and ('configured as %s'):format(known.name)
                            or ('configured as %s but %q is not started'):format(known.name, known.resource) }
                end
            end
            local up = isStarted(configured)
            return { name = up and configured or 'NONE', resource = up and configured or nil,
                version = up and version(configured) or nil, how = 'configured',
                reason = up and ('configured as %s'):format(configured)
                    or ('configured as %s, which is not a known framework and is not started'):format(configured) }
        end
        if configured == 'NONE' then
            return { name = 'NONE', how = 'configured', resource = nil, version = nil,
                reason = 'configured as NONE; no framework is used' }
        end
        for _, known in ipairs(FRAMEWORKS) do
            if isStarted(known.resource) and probe(known.resource, known.probe) then
                return { name = known.name, resource = known.resource, version = version(known.resource),
                    how = 'detected',
                    reason = ('detected %s (%s) running'):format(known.resource, tostring(version(known.resource))) }
            end
        end
        return { name = 'NONE', how = 'detected', resource = nil, version = nil,
            reason = 'no supported framework is started' }
    end)

    -- Everything else cis_core calls that the framework scenarios exercise.
    -- Answering "not ready" is the honest default: a scenario that wants
    -- readiness says so.
    -- Ready by default. A scenario that is NOT about readiness should not have
    -- to say so, and a boot thread that returns early because WaitReady said
    -- no looks exactly like a resource that did nothing -- which is the shape
    -- the first run of the state-store scenario had: zero database calls and
    -- two assertions failing for a reason that was in the harness.
    FrameworkEnv.export('WaitReady', function() return true end)
    FrameworkEnv.export('SetConfig', function() return true end)
    FrameworkEnv.export('SetDropPlayerHandler', function() return true end)
    FrameworkEnv.export('RegisterCapability', function() return true end)
    FrameworkEnv.export('RegisterCallback', function() return true end)
    FrameworkEnv.export('PublishJobUpdate', function() return true end)
    FrameworkEnv.export('PublishInventory', function() return true end)
    -- Faithful to the real path, which is what makes a scenario's answer mean
    -- something: the inventory service falls back to the FRAMEWORK's player
    -- object, so with no framework there is nothing to add to and it answers
    -- false. A stub that returned an unconditional true made "GiveItem answers
    -- false in standalone mode" fail -- and it was the stub that was wrong, not
    -- the resource, which is exactly the sort of thing these tests exist to
    -- settle.
    local function hasPlayer(src)
        return CisFramework ~= nil and CisFramework.GetPlayer(src) ~= nil
    end
    FrameworkEnv.export('InventoryAdd', function(src) return hasPlayer(src) end)
    FrameworkEnv.export('InventoryRemove', function(src) return hasPlayer(src) end)
    FrameworkEnv.export('InventoryHas', function() return false end)
    FrameworkEnv.export('GetOnlineJobCount', function() return 0 end)
    FrameworkEnv.export('GetCapabilities', function() return {} end)
    FrameworkEnv.export('GetSelfCheck', function() return { ok = true, problems = {} } end)
    -- `CisFramework`, not `Framework`: the server file aliases the capability
    -- table to a FILE-LOCAL named `Framework`, and the global `Framework` only
    -- exists on the client. Reaching for the wrong one is an error at load time.
    FrameworkEnv.export('GetFramework', function() return CisFramework end)
    FrameworkEnv.export('NotifyClient', function() return true end)
    FrameworkEnv.export('DbQuery', function() return nil end)
    FrameworkEnv.export('DbSingle', function() return nil end)
    FrameworkEnv.export('DbUpdate', function() return nil end)
    FrameworkEnv.export('DbInsert', function() return nil end)
    FrameworkEnv.export('DbTransaction', function() return false, 'no transactions here' end)
end

return FrameworkEnv