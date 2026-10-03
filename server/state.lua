-- =============================================================================
--  cis_core -- the state store  (SERVER SIDE ONLY)
--
--  WHY THIS EXISTS
--
--  The roadmap gives this resource four jobs: framework abstraction, state, the
--  database, and configuration. Three of them were here. State was not, and its
--  absence had a specific shape: every product that wanted to remember something
--  across a restart invented its own table, and the platform ended up with the
--  same problem it was built to solve -- a schema nobody has a single view of,
--  dropped when the product is uninstalled.
--
--  So this is the one namespaced, durable key/value store in the platform, and
--  a product that only needs a setting should use it rather than writing a
--  migration. A product with a real schema -- housing, banking, an inventory --
--  still brings its own table and registers it through CisMigrationRunner. The
--  line is: a value that belongs to one product and has no shape is state; a
--  thing with columns, indexes and foreign keys is a schema.
--
--  THE NAMESPACE IS NOT A PARAMETER
--
--  There is no `owner` argument anywhere in the public API. The owner IS
--  `GetInvokingResource()`. That is deliberate and it is the security property
--  of this file: a namespaced store where the namespace is a parameter is a
--  store where any resource can read and write any other resource's state, and
--  the only thing standing between them is a check somebody will eventually
--  forget to write. Deriving it at the boundary means crossing the boundary is
--  the whole of the enforcement -- there is no code path in which one product
--  names another.
--
--  SERVER SIDE ONLY, AND THAT IS NOT AN OMISSION
--
--  A client gets state the way it gets everything else: through a server
--  callback its own resource registers, which is re-validated at the time of
--  the call. There is no client export here because a client export over a
--  shared namespace is a broadcast of whatever that product decided to keep,
--  and the decision about what a player may be told belongs to the product, not
--  to the store.
-- =============================================================================

CisState = {}

local TABLE = 'cis_state'

-- owner -> { [key] = decoded value }
local cache = {}
-- owner -> true, so a namespace with no rows is not re-read on every call.
local loaded = {}

-- One reason, for every caller, so "state is unavailable" is answerable without
-- each of them probing the database themselves.
local function libs()
    return exports['cis_libs']
end

--- Encode and decode through the runtime's JSON, defensively.
---
--- FiveM ships json in both realms, so this is a built-in rather than a
--- dependency -- but it is still called through a pcall, because the one thing
--- it will raise on is exactly the thing this file exists to survive: a value
--- that got past the rules.
local function encode(value)
    local ok, encoded = pcall(json.encode, value)
    if not ok or type(encoded) ~= 'string' then
        return nil, ('the value could not be encoded (%s)'):format(tostring(encoded))
    end
    return encoded
end

local function decode(text)
    if type(text) ~= 'string' then
        return nil
    end
    local ok, value = pcall(json.decode, text)
    if not ok then
        return nil
    end
    return value
end

--- Who is calling. nil from the console, which has no resource behind it.
local function owner()
    local resource = GetInvokingResource()
    if type(resource) ~= 'string' or resource == '' then
        return nil, 'this call came from the console, which has no namespace of its own'
    end
    return resource
end

-- How long to wait before asking the database again after it said no.
--
-- Not zero and not forever. Forever means a database that comes back two
-- minutes into the server's life leaves the state store dead until the next
-- restart, for a fault that has already cleared. Zero means every call from
-- every product pays two round trips against a database that is not there.
-- Five seconds is the number that makes both of those outcomes rare.
local RETRY_MS = 5000

local lastFailureAt = 0
local failureReason = nil

--- Is the store usable at all? The schema is applied by a boot thread, so this
--- is a real question for the first moments of a resource's life and for any
--- server whose database is down.
local function usable()
    if failureReason then
        if (GetGameTimer() - lastFailureAt) < RETRY_MS then
            return false, failureReason
        end
        -- The backoff expired, so this is a retry. If it succeeds the reason is
        -- cleared below and the store comes back on its own.
        failureReason = nil
    end
    if not CisMigrationRunner or not CisMigrationRunner.ready() then
        failureReason = 'the migration ledger is unavailable -- no database provider answered, or cis_libs is not ready'
        lastFailureAt = GetGameTimer()
        return false, failureReason
    end
    return true
end

-- Read one namespace into the cache. Returns the cache table.
local function load(ownerName)
    local ok, why = usable()
    if not ok then
        return nil, why
    end
    if loaded[ownerName] then
        return cache[ownerName]
    end

    local rows = libs():DbQuery(
        ('SELECT k, v FROM %s WHERE owner = ?'):format(TABLE), { ownerName })
    if rows == nil then
        return nil, ('the %s table could not be read -- no database provider answered'):format(TABLE)
    end

    local values = {}
    for _, row in ipairs(rows) do
        if type(row) == 'table' and type(row.k) == 'string' then
            -- A row that does not decode is DROPPED from the cache rather than
            -- left as the raw string. Answering the caller with an encoded blob
            -- would be worse than answering with nothing: the value looks like
            -- data and is not, and the bug it causes is somewhere else entirely.
            local decoded = decode(row.v)
            if decoded ~= nil then
                values[row.k] = decoded
            else
                print(('[cis_core] state %s/%s could not be decoded and is treated as absent')
                    :format(ownerName, row.k))
            end
        end
    end

    cache[ownerName] = values
    loaded[ownerName] = true
    return values
end

-- ------------------------------------------------------------- the service

--- Write one value.
--- @return boolean ok, string|nil reason
function CisState.set(ownerName, key, value)
    local ok, why = usable()
    if not ok then
        return false, why
    end
    local valid, reason = CisStateRules.check(key, value)
    if not valid then
        return false, reason
    end

    local encoded, encWhy = encode(value)
    if not encoded then
        return false, encWhy
    end
    local sized, sizeWhy = CisStateRules.encodedSize(encoded)
    if not sized then
        return false, ('%s (key %q)'):format(sizeWhy, key)
    end

    -- An upsert, not an insert-then-update.
    --
    -- MySQL's `ON DUPLICATE KEY UPDATE` would make this one round trip, and it is
    -- deliberately not used: it is MySQL syntax, and cis_core documents MongoDB
    -- as a supported driver, where the equivalent does not exist. The two-branch
    -- form works on both drivers, at the cost of a read before the write.
    --
    -- That cost is a real trade and it is stated rather than waved at. Between
    -- the SELECT and the write another thread can also write the same key, so two
    -- concurrent `StateSet` calls for one key end as last-write-wins rather than
    -- one being rejected. For a key/value store that is the correct semantic --
    -- there is no increment here and nothing is lost that either caller did not
    -- also intend to overwrite. It would NOT be correct for a counter, which is
    -- exactly why counters belong in a product's own schema.
    local now = os.time()
    local existing = libs():DbSingle(
        ('SELECT k FROM %s WHERE owner = ? AND k = ?'):format(TABLE), { ownerName, key })

    if existing then
        local affected = libs():DbUpdate(
            ('UPDATE %s SET v = ?, updated_at = ? WHERE owner = ? AND k = ?'):format(TABLE),
            { encoded, now, ownerName, key })
        if affected == nil then
            return false, 'the value was not written -- the database refused the update'
        end
    else
        local id = libs():DbInsert(
            ('INSERT INTO %s (owner, k, v, updated_at) VALUES (?, ?, ?, ?)'):format(TABLE),
            { ownerName, key, encoded, now })
        if id == nil then
            -- TWO CAUSES, BOTH NAMED, because the driver's SELECT above answers
            -- nil for "no such row" AND for "the query failed" -- one value for
            -- two states. The old message blamed the key, so an operator with a
            -- dropped connection was told to shorten a key that was fine. That
            -- is precisely the "single least useful diagnostic" this file's
            -- header names, and it took a whole two-call upsert to get there.
            return false, ('the value was not written: the row could not be read AND the insert was refused '
                .. '(key %q, %d bytes encoded). Either the SELECT failed -- check the database -- or the driver '
                .. 'refused the insert'):format(key, #encoded)
        end
    end

    local values = load(ownerName)
    if values then
        values[key] = value
    else
        -- The row IS durable; this process's cache is not. Forgetting the
        -- namespace makes the next read re-query rather than answer a stale
        -- fallback for a key that was just written -- read-your-writes is
        -- broken for exactly one call otherwise, and only on a fresh boot
        -- with a database that is having a moment.
        loaded[ownerName] = nil
        cache[ownerName] = nil
        return true, 'written, but the cache could not be refreshed -- the next read will re-query'
    end
    return true
end

--- Read one value, or `fallback` when it is not set.
--- @return any value, string|nil reason
function CisState.get(ownerName, key, fallback)
    local ok, why = usable()
    if not ok then
        return fallback, why
    end
    if not CisStateRules.key(key) then
        return fallback, ('%q is not a usable state key'):format(tostring(key))
    end
    local values, loadWhy = load(ownerName)
    if not values then
        return fallback, loadWhy
    end
    local value = values[key]
    if value == nil then
        return fallback
    end
    return value
end

--- The whole namespace, as a fresh table the caller may mutate freely.
function CisState.all(ownerName)
    local ok, why = usable()
    if not ok then
        return nil, why
    end
    local values, loadWhy = load(ownerName)
    if not values then
        return nil, loadWhy
    end
    local out = {}
    for k, v in pairs(values) do
        out[k] = v
    end
    return out
end

--- The keys, sorted. Sorted so that a caller printing them, or a test asserting
--- on them, gets the same answer twice.
function CisState.keys(ownerName)
    local ok, why = usable()
    if not ok then
        return nil, why
    end
    local values, loadWhy = load(ownerName)
    if not values then
        return nil, loadWhy
    end
    local out = {}
    for k in pairs(values) do
        out[#out + 1] = k
    end
    table.sort(out)
    return out
end

--- Remove one key. Removing something that is not there is `true`, not an error:
--- "make sure this is gone" is the operation most callers actually want, and it
--- should not have to be preceded by a read to find out whether it was.
function CisState.delete(ownerName, key)
    local ok, why = usable()
    if not ok then
        return false, why
    end
    if not CisStateRules.key(key) then
        return false, ('%q is not a usable state key'):format(tostring(key))
    end
    local affected = libs():DbUpdate(
        ('DELETE FROM %s WHERE owner = ? AND k = ?'):format(TABLE), { ownerName, key })
    if affected == nil then
        return false, 'the row was not deleted -- the database refused'
    end
    local values = cache[ownerName]
    if values then
        values[key] = nil
    end
    return true
end

--- Remove the whole namespace. Returns how many rows went.
function CisState.clear(ownerName)
    local ok, why = usable()
    if not ok then
        return 0, why
    end
    local affected = libs():DbUpdate(('DELETE FROM %s WHERE owner = ?'):format(TABLE), { ownerName })
    if affected == nil then
        return 0, 'the namespace was not cleared -- the database refused'
    end
    cache[ownerName] = {}
    loaded[ownerName] = true
    return affected, nil
end

-- ------------------------------------------------------------------ exports
--
-- Every one of them derives the namespace from GetInvokingResource() and takes
-- no owner argument. See the header for why that is the security property rather
-- than a limitation.

exports('StateSet', function(key, value)
    local ownerName, why = owner()
    if not ownerName then
        return false, why
    end
    return CisState.set(ownerName, key, value)
end)

exports('StateGet', function(key, fallback)
    local ownerName, why = owner()
    if not ownerName then
        return fallback, why
    end
    return CisState.get(ownerName, key, fallback)
end)

exports('StateAll', function()
    local ownerName, why = owner()
    if not ownerName then
        return nil, why
    end
    return CisState.all(ownerName)
end)

exports('StateKeys', function()
    local ownerName, why = owner()
    if not ownerName then
        return nil, why
    end
    return CisState.keys(ownerName)
end)

exports('StateDelete', function(key)
    local ownerName, why = owner()
    if not ownerName then
        return false, why
    end
    return CisState.delete(ownerName, key)
end)

exports('StateClear', function()
    local ownerName, why = owner()
    if not ownerName then
        return 0, why
    end
    return CisState.clear(ownerName)
end)

--- Everything about the store that is safe to print: which namespaces exist, how
--- big they are, and whether the schema is actually there.
---
--- Namespace NAMES are resource names the operator already installed, so this is
--- the same information `cis_core_doctor` prints and nothing more. No value is
--- read, so no state is ever exposed by asking about the store.
--- Everything about the store that is safe to print: which namespaces exist, how
--- big they are, and whether the schema is actually there.
---
--- Namespace NAMES are resource names the operator already installed, so this is
--- the same information `cis_core_doctor` prints and nothing more. No value is
--- read, so no state is ever exposed by asking about the store.
---
--- A MODULE FUNCTION, with a thin export in front of it, because the doctor
--- needs this too and the doctor lives in the same resource. Calling your own
--- export is the self trap documented in server/migrations.lua -- the bracket
--- form is an unbound method that swallows the first argument -- and
--- `GetInvokingResource()` inside it is not a thing worth relying on. The
--- export exists for everyone else; everything here calls the function.
function CisState.summary()
    local ok, why = usable()
    local namespaces = {}
    if ok then
        -- FROM THE DATABASE, not from the cache. A summary built out of what
        -- happens to be in memory answers "which products have touched state
        -- since this resource started", which on a freshly restarted server is
        -- an empty list -- so it would report that a server with 400 state rows
        -- has none.
        local rows = libs():DbQuery(
            ('SELECT owner, COUNT(*) AS n FROM %s GROUP BY owner'):format(TABLE), {})
        for _, row in ipairs(rows or {}) do
            if type(row) == 'table' and row.owner then
                namespaces[#namespaces + 1] = {
                    owner = tostring(row.owner),
                    keys = tonumber(row.n) or 0,
                }
            end
        end
        table.sort(namespaces, function(a, b)
            return a.owner < b.owner
        end)
    end
    return {
        available = ok,
        reason = why,
        namespaces = namespaces,
    }
end

exports('GetStateSummary', function()
    return CisState.summary()
end)