-- =============================================================================
--  CIsoko Core -- platform services that hold data
--
--  WHAT THIS IS: the half of the platform that owns STATE. It abstracts your
--  framework (ESX / ESX-LEGACY / QBCore / qbx_core / standalone), holds the
--  inventory service, owns the configuration file an operator edits, and runs
--  the schema migrations for anything that stores anything on this platform.
--
--  WHAT IT IS NOT: a library. It owns no primitives of its own. It depends on
--  cis_libs for the boundary -- the naming, the marshalling, the gating, the
--  zones, the callbacks, the logging -- and everything it does is registered
--  into cis_libs as a capability.
--
--      ensure cis_libs        -- first
--      ensure cis_core        -- this
--      ensure cis_bridge      -- then the third-party adapters
--      ensure cis_keys        -- then the products
--
--  Two of the three things it does are answers to questions cis_libs asks:
--
--    * FRAMEWORK.  cis_libs:RegisterCapability('framework', 'cis_core:CisCoreFramework')
--      One normalized surface over four different frameworks and standalone.
--      AUTO detection asks the server what is actually running rather than
--      trusting the configured name -- a server configured for QBCore that is
--      really running qbx_core used to get a bridge that reported itself ready
--      and then returned nil for every player, with nothing in the console
--      saying why.
--
--    * CONFIGURATION.  cis_libs:SetConfig(config, security)
--      The config file lives HERE, because a library has no business shipping
--      an editable file that is simultaneously documentation and load-bearing
--      state. cis_libs states the floor in code; this states what the operator
--      chose.
--
--  The third -- migrations -- is the reason this resource exists separately
--  from cis_bridge. A driver can be swapped; a schema cannot. oxmysql and
--  mysql-connector are adapters you replace, and the table definitions are the
--  one thing that has to survive the swap, so the schema is owned here and
--  reaches the driver only through cis_libs.
--
--  Free with purchase. See LICENSE.md.
-- =============================================================================

fx_version 'cerulean'
game 'gta5'

name "Cisoko - Core - Platform Services"
description "Framework abstraction, state, inventory service, configuration and migrations."
author "Cisoko"
version "1.0.0"
lua54 'yes'

-- A real dependency, and the only one. `dependencies` makes the server start
-- order irrelevant for this resource, which is the difference between "follow
-- the README" and "it works whichever order you paste them in". The cost is
-- that cis_libs must be on disk; that is the point of a platform.
dependencies {
    'cis_libs',
}

shared_scripts {
    'shared/cis.lua',
    'shared/migrations.lua',
}

client_scripts {
    'framework/framework_client.lua',
    'client/inventory.lua',
}

server_scripts {
    'configs/master_config.lua',
    'configs/security_config.lua',
    'configs/discordLogs_config.lua',
    'framework/framework_server.lua',
    'server/inventory.lua',
    'server/migrations.lua',
    'server/initialize.lua',
}
