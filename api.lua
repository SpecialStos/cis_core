-- =============================================================================
--  cis_core -- the machine-readable public contract
--
--  This file is DATA. It defines nothing, runs nothing, and is deliberately
--  not listed in fxmanifest.lua: loading it would put a table into every Lua
--  state at every boot for no gain. Read it on demand, and run
--  `npm run test:api` -- which validates it against what the code actually
--  registers and fails on the difference.
--
--  THE DECLARATION IS NOT THE TRUTH. THE TRUTH IS THE SOURCE.
--  tools/lua-exports.js scrapes the real registered surface out of the real
--  files; this file is a claim about it, and the validator holds the two
--  together. A renamed export, a changed parameter list, an undeclared event
--  and a declared-but-missing export are all failures rather than drift.
--
--  WHAT IS AND IS NOT HERE
--
--  Almost nothing in this file is consumer API. A consumer calls `Cis.*`, which
--  resolves to exports on cis_libs, and this resource is behind them. What is
--  here is the seam: the exports cis_libs calls to reach this resource, and the
--  exports a product uses to hand it a schema.
--
--  `api = 1` is the CONTRACT MAJOR, and it is not the product version. It moves
--  when something a consumer depends on changes shape. It is 1 because the
--  split into cis_libs / cis_core / cis_bridge preserved every `Cis.*` name and
--  signature that existed before it -- a consumer's manifest line and its calls
--  did not change. `schema` is the migration set id and is not validated.
-- =============================================================================

return {
    name = 'cis_core',
    version = '1.1.0',
    api = 1,
    schema = 0,

    exports = {
        -- ------------------------------------------------------- the seam
        -- Registered as a REFERENCE by cis_libs, not sent: a function cannot be
        -- sent across the exports boundary, and a capability is a thing you ask
        -- cis_libs for by name.
        CisCoreFramework = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Registered into cis_libs as the `framework` capability. Returns the normalized API table: GetPlayer, GetPlayers, GiveMoney, RemoveMoney, GetPlayerIdentifier, GetPlayerJob, SetPlayerJob, HasPermission, GetOnlineJobCount, Notify, NormalizedPlayer, IsLoaded',
            realm = 'both',
            signature = '()',
        },
        CisCoreFrameworkNotify = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Called by cis_libs when no framework capability is registered. Shows the native feed',
            realm = 'client',
            signature = '(message, kind)',
        },
        CisCoreDropPlayer = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Registered into cis_libs as the `security` capability. The one place a security report can drop a player',
            realm = 'server',
            signature = '(src, reason)',
        },
        GetCoreSummary = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Resolved, non-secret state for diagnostics: configApplied, framework, inventory, providers, applied migrations',
            realm = 'server',
            signature = '()',
        },
        GetDoctorReport = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The full install report as data: every environment line and every configuration problem, each with its fix. Same content as the `cis_core_doctor` console command. Carries no secret -- resource names, booleans, counts and reasons only',
            realm = 'server',
            signature = '()',
        },

        -- -------------------------------------------------------- inventory
        CisCoreInventory = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Registered into cis_libs as the `inventory` capability. Returns { Count, Add, Remove, Has, Snapshot }',
            realm = 'server',
            signature = '()',
        },
        CisCoreInventoryClient = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Registered into cis_libs as the client `inventory` capability. Returns { Count, Has } -- no src, and answered from a pushed snapshot',
            realm = 'client',
            signature = '()',
        },

        -- Registered into cis_libs as the `inventory` capability, which is the
        -- SERVICE: the name -> amount normalisation every consumer depends on.
        -- The third-party adapters behind it register as `inventoryProvider`
        -- from cis_bridge, so the service and the adapter are separate things
        -- and either can be replaced alone.

        -- -------------------------------------------------------- migrations
        Migrate = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports["cis_core"]:Migrate(owner, { { id = "001_x", statements = { ... } } }). Idempotent by id. Applies in numeric order then alphabetical',
            realm = 'server',
            signature = '(owner, list)',
        },
        AppliedMigrations = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The sorted list of migration ids recorded as applied, for diagnostics',
            realm = 'server',
            signature = '()',
        },

        -- ---------------------------------------------------------- state
        -- Every one of these derives its namespace from GetInvokingResource()
        -- and takes no owner argument. That is the security property, not a
        -- limitation: a store whose namespace is a parameter is a store any
        -- resource can read and write for any other, and the only thing standing
        -- between them is a check somebody eventually forgets to write.
        StateSet = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports["cis_core"]:StateSet(key, value). Writes one JSON value into the calling resource\'s namespace. Returns true, or false and a reason: an unencodable value, an oversized one, or no database',
            realm = 'server',
            signature = '(key, value)',
        },
        StateGet = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports["cis_core"]:StateGet(key, fallback). The value, or `fallback` when unset. The fallback is returned on failure too, so an unavailable store answers the default rather than nil',
            realm = 'server',
            signature = '(key, fallback)',
        },
        StateAll = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports["cis_core"]:StateAll(). A fresh table of the calling resource\'s whole namespace, which the caller may mutate freely. nil and a reason when the store is unavailable',
            realm = 'server',
            signature = '()',
        },
        StateKeys = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports["cis_core"]:StateKeys(). The namespace\'s keys, sorted, so two calls answer the same way',
            realm = 'server',
            signature = '()',
        },
        StateDelete = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports["cis_core"]:StateDelete(key). Removing a key that is not set is true, not an error -- "make sure this is gone" is the operation most callers actually want',
            realm = 'server',
            signature = '(key)',
        },
        StateClear = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports["cis_core"]:StateClear(). Removes the whole namespace and returns how many rows went',
            realm = 'server',
            signature = '()',
        },
        GetStateSummary = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'exports["cis_core"]:GetStateSummary(). { available, reason, namespaces = { { owner, keys } } }, read from the database rather than from memory, so a restarted server reports what is really stored. No value is read, so no state is exposed by asking',
            realm = 'server',
            signature = '()',
        },
    },

    -- Events this resource LISTENS for. It publishes none of its own, and
    -- that is a deliberate division:
    --
    --   * The framework names below are third-party. This is the resource that
    --     knows which framework is installed, so this is where they belong, and
    --     declaring them here is what lets an operator see, in one file, every
    --     external event this platform depends on.
    --   * The `cis_libs:*` names are the library's, and they are declared in
    --     cis_libs's api.lua because a NAME is part of the published contract
    --     and a name that moves between resources is one a product can rename
    --     without anyone noticing until a consumer stops hearing about it.
    --     They appear here too, as DEPENDENCIES: this resource consumes them.
    --
    -- Nothing is TRIGGERED here. A product asking this library to show a
    -- notification or push an inventory goes through an export, so the wire
    -- stays in the one place that owns it.
    events = {
        ['esx:playerLoaded'] = {
            since = '1.0.0',
            payload = 'ESX to server: (player). Drives PublishPlayerLoaded and PublishInventory',
        },
        ['esx:setJob'] = {
            since = '1.0.0',
            payload = 'ESX to server: (src, job). Drives PublishJobUpdate',
        },
        ['QBCore:Server:PlayerLoaded'] = {
            since = '1.0.0',
            payload = 'QBCore to server: (player). qbx_core re-fires this for compatibility, so one handler covers both',
        },
        ['QBCore:Server:OnJobUpdate'] = {
            since = '1.0.0',
            payload = 'QBCore to server: (src, job)',
        },
        ['QBCore:Client:OnPlayerLoaded'] = {
            since = '1.0.0',
            payload = 'QBCore to client: (playerData)',
        },
        ['QBCore:Client:OnJobUpdate'] = {
            since = '1.0.0',
            payload = 'QBCore to client: (job)',
        },
        ['QBCore:Player:SetPlayerData'] = {
            since = '1.0.0',
            payload = 'QBCore to client: ({ items }). Refreshes the client inventory counts',
        },
        ['qbx_core:client:playerLoaded'] = {
            since = '1.0.0',
            payload = 'qbx_core to client: (playerData)',
        },
        ['qbx_core:client:onJobUpdate'] = {
            since = '1.0.0',
            payload = 'qbx_core to client: (job)',
        },
        -- cis_libs-owned, consumed here. Listed so the dependency is visible.
        ['cis_libs:jobUpdated'] = {
            since = '2.0.0',
            payload = 'cis_libs to client: ({ name, grade }). This resource LISTENS; cis_libs fires it',
        },
        ['cis_libs:playerLoaded'] = {
            since = '2.0.0',
            payload = 'cis_libs to client: (job). This resource LISTENS; cis_libs fires it',
        },
        ['cis_libs:client:inventory'] = {
            since = '2.0.0',
            payload = 'cis_libs to client: ({ [itemName] = count }). This resource LISTENS; cis_libs fires it',
        },
    },
}
