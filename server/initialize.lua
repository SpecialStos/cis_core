-- Boot. Four jobs, in this order, and the order is the contract:
--
--   1. wait for cis_libs       -- everything below is a call into it
--   2. hand over the config    -- cis_libs publishes what the operator wrote
--   3. register the handlers   -- the drop function, which cannot travel in a
--                                 config table because a function cannot be
--                                 SENT across the exports boundary
--   4. announce and report     -- so `cis_debug` has something true to print
--
-- Step 2 before step 3 because a config carrying a webhook URL is a config the
-- client payload must be built from, and step 3 before step 4 because a
-- capability that appears after the report reads as a failed registration.

-- Whether our config was the one that took effect. Kept here rather than
-- re-derived, because the answer depends on a race with another resource and
-- a later read of `Config` cannot tell us which of us won.
local configApplied = false

CreateThread(function()
    -- cis_libs is a declared dependency, so it is started, but "started" and
    -- "ready" are different facts and only the second one means its exports
    -- answer.
    if not exports['cis_libs']:WaitReady(15000) then
        print('cis_core: cis_libs never became ready; check that it is started and not erroring')
        return
    end

    -- ---------------------------------------------------------------- config
    -- The tables, by value. Functions are stripped on the far side, which is
    -- why Security.DropPlayer arrives as a boolean and the code that implements
    -- it arrives in step 3.
    local ok, why = exports['cis_libs']:SetConfig(Config, Security)
    configApplied = ok == true
    if not ok then
        -- First supplier wins, and this one lost. Say so and carry on with the
        -- local tables rather than exiting: a server with two things claiming
        -- to configure it is misconfigured, not unbootable, and the operator
        -- can see both names in the console and fix it in ten seconds.
        print(('cis_core: configuration NOT applied -- %s'):format(tostring(why)))
    end

    -- ------------------------------------------------------- drop handler
    -- A function cannot be sent across the exports boundary, so the custom
    -- handler in configs/security_config.lua cannot travel inside the config
    -- table. It is registered as a capability instead, which is a reference
    -- rather than a value.
    --
    -- The default handler is deliberately generic: it tells the player to
    -- contact the server owner and names no check. Naming the check that fired
    -- tells a person exactly which guard to look for, and guards are the first
    -- thing somebody wants to find.
    exports['cis_libs']:SetDropPlayerHandler('cis_core:CisCoreDropPlayer')

    -- The inventory service, on both sides. Server and client are registered
    -- separately because they are genuinely different -- the client's has no
    -- src and answers from a pushed snapshot -- and registering one table for
    -- both would mean one of the two realms is always being handed an argument
    -- that means nothing on its side.
    exports['cis_libs']:RegisterCapability('inventory', 'cis_core:CisCoreInventory')

    -- ------------------------------------------------------------- announce
    print(('cis_core: ready. Configuration: %s'):format(
        tostring(ok and 'applied' or 'NOT applied')))
    print(('cis_core:   framework %s, inventory %s, target %s, database %s'):format(
        tostring(Config.Framework.Type),
        tostring(Config.Framework.Inventory),
        tostring(Config.Framework.Target and Config.Framework.Target.Type),
        tostring(Config.Framework.Database and Config.Framework.Database.Type)))
end)

--- The custom drop handler. Reached only through the capability registered
--- above, so there is exactly one line in the whole platform that can drop a
--- player for a security report, and it is this one.
exports('CisCoreDropPlayer', function(src, reason)
    local handler = rawget(_G, 'cisAnticheatDropPlayer')
    if type(handler) == 'function' then
        handler(src, reason)
        return
    end
    -- The handler function cannot be sent, but the MESSAGE is a string and
    -- travels fine, so the shipped default is repeated here as a value. One
    -- sentence, generic on purpose.
    DropPlayer(src, 'cis_libs: Kicked. If you believe this is a mistake, please contact the server owner.')
end)

--- A plain summary for cis_core's own diagnostics and for a support thread.
--- Everything here is a resolved value or a boolean -- no config table, no
--- allow-list, no connection detail.
exports('GetCoreSummary', function()
    local caps = exports['cis_libs']:GetCapabilities()
    return {
        configApplied = configApplied,
        framework = Config.Framework.Type,
        inventory = Config.Framework.Inventory,
        targetProvider = caps.target and caps.target.owner or nil,
        databaseProvider = caps.database and caps.database.owner or nil,
        -- Read straight off the migration module's own table rather than
        -- through `exports['cis_core']`. Calling yourself by resource name is
        -- the self trap: the exports table is an unbound method, and the
        -- bracket form silently swallows the first argument. CI greps for it.
        migrations = CisMigrationsApplied,
    }
end)
