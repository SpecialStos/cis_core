-- =============================================================================
--  cis_core -- security configuration  (SERVER SIDE ONLY)
--
--  Everything in this file is a SECURITY decision. The defaults below were
--  chosen so that a fresh clone is closed by default, and so that a stranger
--  who drops this on a live server without reading a word is not exposed.
--
--  Of the three keys here, one matters more than the other two combined:
--
--      Security.AuthorizedResources
--
--  Read the block under it before you run this on anything real.
--
--  Nothing in this file is a secret, and none of it reaches the client: the
--  authorised-resource list and the kick handler are stripped from the payload
--  the server sends out, so a player can never read either back.
-- =============================================================================

Security = {}

-- ------------------------------------------------------------------ IDENTITY
-- The prefix on every net event the library uses, on both sides:
--     "<prefix>:doorlock:addDoor", "<prefix>:doorlock:requestState", ...
--
-- SAFE DEFAULT: "cis_libs". Keep it. It is the name this library publishes its
-- events under, and the compiled-in fallback in client/ and server/ is the same
-- string.
-- IF YOU CHANGE IT: every event name changes with it. Any companion resource
-- that triggers these events directly must be changed to match in the same
-- edit, or it will silently stop working -- the trigger is not refused, it
-- simply never arrives. Only change it if two cis_libs-derived resources must
-- coexist on one server and their event sets would otherwise collide.
Security.EventPrefix = "cis_libs"

-- RESERVED. Nothing in this resource reads it; `Config.Printing.Debug` is the
-- flag that is actually wired up. It is kept so an existing config keeps
-- loading, but DO NOT BUILD ANYTHING ON IT: setting it true will not turn
-- anything on. For diagnostics, use Config.Printing.Debug in master_config.lua.
Security.Debug = false

-- =============================================================================
--  SECURITY.AuthorizedResources  --  READ THIS
--
--  WHAT IS IN THIS LIST, AND WHY IT IS NOT EMPTY
--
--  An authorised resource may call the MUTATING half of cis_libs: add a door,
--  break a door, write a sync record, supply a capability. This list ships with
--  the publisher's own products on it and nothing else, so a working install of
--  cis_libs + cis_core + cis_keys works the moment you paste the `ensure`
--  lines -- with no second edit, and with no support ticket about why your doors
--  stopped responding.
--
--  It used to ship EMPTY, on the reasoning that a new server has no authorised
--  callers and "nobody" is the honest answer. That reasoning was sound and the
--  outcome was not: every CIsoko product was refused by default, which means
--  every install had to be repaired by hand before it worked, and the repair is
--  invisible until something breaks. A secure default that has to be edited
--  before the product functions is not a secure default, it is a broken
--  install with a good story.
--
--  THE LINE IS VENDOR PRODUCTS, NOT "THINGS THAT LOOK LIKE THEM"
--
--  Everything below is ours, and everything below is either started or is a name
--  no one else is using. That is the whole boundary. There is no wildcard, no
--  prefix match and no "any resource whose name starts with cis_", so a
--  third-party resource can never inherit a grant by being named similarly.
--
--  WHAT AN ENTRY BUYS, PRECISELY: the right to call mutating exports, and
--  nothing else. It does not grant money, inventory or database access, it does
--  not make the resource trusted by cis_core's config validator, and it does
--  not survive into the client payload -- a player can never read this list.
--
--  ONE RESIDUAL RISK, STATED PLAINLY: an entry that is not installed grants
--  nothing today, but if a DIFFERENT resource is later installed under that
--  exact name it inherits the grant. That is why the list is our products and
--  not "resources you might install later" -- and why `cis_core_doctor` prints
--  every entry that is authorised but not started, so a stale entry is visible
--  rather than latent.
--
--  TO TIGHTEN IT: delete the entries you do not have. To add your own resource,
--  add one string per resource name:
--
--      Security.AuthorizedResources = {
--          "cis_housing",
--          "my_resource",
--      }
--
--  To remove every grant -- a fully manual install -- set it to {} and add
--  names as you install each one. This needs no restart of the resources being
--  listed -- only of cis_libs.
--
--  A resource can ask before it acts, rather than guessing:
--      if exports["cis_libs"]:InvokingAllowed() then ... end
--  and that call returns false rather than refusing mid-action, so you can warn
--  the player properly.
-- =============================================================================
Security.AuthorizedResources = {
    -- ------------------------------------------------------------ platform
    'cis_libs',
    'cis_core',
    'cis_bridge',

    -- ----------------------------------------------------------- wave 1
    'cis_keys',
    'cis_signal',
    'cis_weather',
    'cis_evidence',
    'cis_identity',
    'cis_dispatch',
    'cis_medic',
    'cis_electricity',

    -- ----------------------------------------------------------- wave 2
    'cis_inventory',
    'cis_economy',
    'cis_business',
    'cis_stores',
    'cis_dealership',
    'cis_mechanic',
    'cis_housing',

    -- ----------------------------------------------------------- waves 3-4
    'cis_phone',
    'cis_drugs',
    'cis_skills',
    'cis_migrate',
    'cis_admin',
}

-- ------------------------------------------------------------------- KICKING
-- What happens when the library decides a player is cheating: either a boolean
-- or a function(src, reason) for a kick of your own design.
--
-- SAFE DEFAULT: false. LOG ONLY.
--
-- It shipped as `true`, and it was wrong for a resource whose headline feature
-- is a framework abstraction. A player gets kicked from a platform they
-- installed to get their framework bridged, on the strength of a heuristic
-- another resource raised, and they were told a server owner had been informed
-- when nothing had been. cis_libs documents this default as false and every
-- other resource in the platform should match it: a library does not remove
-- players from a server as a side effect of reporting something suspicious.
--
-- If you run an anti-cheat that wants enforcement, this is the one line:
--
--      Security.DropPlayer = cisAnticheatDropPlayer
--
-- It is written out at the bottom of this file, uncommented, so turning it on
-- is one edit rather than a lookup.
--
-- A note on the message: it is deliberately generic, and it deliberately tells
-- the player to contact the server owner. Naming the check that fired tells a
-- person exactly which guard to look for, and guards are the first thing
-- somebody wants to find. If you customise it, keep it that way.
--
-- With false, nothing stops the player at all -- only the log entry survives, and
-- it is written wherever your logging goes. Ban on your own terms elsewhere, or
-- read the log before you decide.
--
-- `src` is the player's server id, and `reason` is a short internal string.
-- Whatever you return is ignored; the library records the kick as having
-- happened either way.
Security.DropPlayer = false

function cisAnticheatDropPlayer(src, reason)
    DropPlayer(src, "cis_libs: Kicked. If you believe this is a mistake, please contact the server owner.")
end

-- TO ENFORCE: uncomment the line below. It is the whole of it.
-- Security.DropPlayer = cisAnticheatDropPlayer