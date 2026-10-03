-- =============================================================================
--  cis_core -- console commands
--
--  Two of them, and the split is deliberate.
--
--      cis_core_info     one line. Safe to run any time.
--      cis_core_doctor   the whole report, every problem, every fix.
--
--  The reason there are two is that a diagnostic that prints forty lines is a
--  diagnostic nobody runs, and a diagnostic nobody runs catches nothing. The
--  one-liner is what an operator types when something looks wrong; the full
--  report is what they run once they know it is.
--
--  WHO MAY RUN THEM
--
--  The server console, always -- it arrives as src == 0. In game, an admin, via
--  the same framework permission check cis_libs uses for `cis_debug`. That check
--  is not decoration: `RegisterCommand`'s third argument is FiveM's restricted
--  flag, and a console that forwards a player src, or a restricted flag that is
--  not what it was assumed to be, must not become a way to run a command
--  without permission.
--
--  What these commands print is resource names, booleans and counts. Never a
--  webhook, a connection string, an identifier or a config value -- see the
--  header of server/doctor.lua for why that is a hard rule and not a habit.
-- =============================================================================

-- Frameworks disagree about what "admin" is called, and the answer belongs to
-- the framework, not to this resource. Asking through the capability is also
-- what keeps the permission decision on the server: this file never reads a
-- permission out of a state bag or trusts one a client sent.
local function isAdmin(src)
    if src == 0 then
        return true
    end
    local ok, fw = pcall(function()
        return exports['cis_libs']:GetFramework()
    end)
    if not ok or type(fw) ~= 'table' or type(fw.HasPermission) ~= 'function' then
        return false
    end
    -- TWO values, and the PERMISSION IS THE SECOND. `fw.HasPermission` answers
    -- a plain boolean, so `pcall` succeeding tells you only that nothing
    -- raised -- testing that alone grants the command to every player on the
    -- server, which is the exact inverse of what this check is for.
    --
    -- A missing capability, an unknown player and a framework with no groups
    -- all answer false rather than raising, so a refusal is the normal path.
    local called, allowed = pcall(fw.HasPermission, fw, src, 'admin')
    return called == true and allowed == true
end

-- How many migrations the ledger has recorded. A count is the only thing a
-- one-liner can carry that is worth carrying, and reading it off the module's
-- own table avoids calling this resource's own exports -- see the note on the
-- self trap in server/migrations.lua.
local function migrationCount()
    local n = 0
    for _ in pairs(CisMigrationsApplied or {}) do
        n = n + 1
    end
    return n
end

RegisterCommand('cis_core_info', function(src)
    if not isAdmin(src) then
        return
    end
    local ok, fw = pcall(function()
        return exports['cis_libs']:GetFramework()
    end)
    local loaded = false
    if ok and type(fw) == 'table' and type(fw.IsLoaded) == 'function' then
        local called, result = pcall(fw.IsLoaded, fw)
        loaded = called == true and result == true
    end
    local detected = CisFramework and CisFramework.detected
    print(('cis_core: v%s | framework %s | inventory %s | %d migration(s) recorded')
        :format(
            tostring(GetResourceMetadata(GetCurrentResourceName(), 'version', 0)),
            tostring((type(detected) == 'table' and detected.name)
                or (Config and Config.Framework and Config.Framework.Type) or 'unknown'),
            tostring(Config and Config.Framework and Config.Framework.Inventory or 'unknown'),
            migrationCount()
        ))
    print(('cis_core: framework capability %s | run `cis_core_doctor` for the full report')
        :format(loaded and 'ready' or 'NOT ready'))
end, true)

RegisterCommand('cis_core_doctor', function(src)
    if not isAdmin(src) then
        return
    end
    local lines = CisDoctor.environment()
    local ok, report = CisConfig.validate(Config, Security, DiscordConfig)

    -- The configuration problems are part of the same report rather than a
    -- second thing to remember: an operator asked "is this install healthy?"
    -- wants one answer, and splitting it means they read half of it.
    --
    -- `info` is printed as SET, not INFO. The three severities already mean
    -- MISSING / DEGRADED / SET and a fourth word in the same column would be
    -- one more thing to learn before reading the line.
    for _, bucket in ipairs({ 'error', 'warning', 'info' }) do
        local severity = bucket == 'info' and 'SET' or bucket:upper()
        for _, p in ipairs(report[bucket]) do
            lines[#lines + 1] = {
                severity = severity,
                subject = p.path,
                state = p.message,
                fix = p.fix,
            }
        end
    end

    CisDoctor.printReport(('doctor -- %s'):format(CisConfig.summary(report)), lines)

    if not ok then
        print('cis_core: nothing above blocks the server. The ERROR lines are settings that fell back to a default.')
    end
end, true)