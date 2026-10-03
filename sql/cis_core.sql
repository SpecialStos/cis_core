-- =============================================================================
--  cis_core -- schema
--
--  cis_core creates both of these tables ITSELF, through the migration ledger
--  in server/migrations.lua, on every boot. This file exists for two other
--  reasons and no others:
--
--    1. An operator who provisions by hand -- a managed database, a migration
--       pipeline, a DBA who does not let a game server hold DDL rights. The
--       runner's statements are `CREATE TABLE IF NOT EXISTS`, so running this
--       first and giving the game user SELECT/INSERT/UPDATE/DELETE on the two
--       tables changes nothing about the boot.
--
--    2. A reviewer who wants to see the schema without reading Lua. It is two
--       tables and that is the whole of what this platform owns.
--
--  WHAT THIS RESOURCE DOES NOT OWN, and will not create:
--
--    * A product's schema. `cis_housing` brings a housing table, `cis_economy`
--      brings a ledger. They register through
--      `exports['cis_core']:Migrate(owner, list)` and the ledger records what
--      ran, so a table is never created by code that cannot tell whether it
--      already exists.
--    * Anything for a driver other than MySQL. The column types below are the
--      ones the ledger uses and they are MySQL's.
--
--  ENCODING. `utf8mb4` explicitly. The server's default charset is frequently
--  latin1 or utf8, and a player name that a framework stores happily is then
--  truncated on the way into this schema -- silently, on write, for one player.
-- =============================================================================

-- -----------------------------------------------------------------------------
--  cis_migrations -- the ledger
--
--  One row per applied migration id, with when it was applied and how long it
--  took. `duration_ms` is there so a slow migration is visible BEFORE it becomes
--  a slow boot: a row that has grown from 4ms to 4000ms is the early warning.
--
--  Ids are keyed, never renumbered. Renaming an applied id makes it look
--  unapplied, and the migration re-runs against a schema that already has it.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `cis_migrations` (
    `id`          VARCHAR(128) NOT NULL,
    `applied_at`  BIGINT       NOT NULL,
    `duration_ms` INT          NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
--  cis_state -- the namespaced key/value store
--
--  `owner` is the RESOURCE NAME, taken from GetInvokingResource() at the moment
--  of the call. It is not a parameter and it is not a foreign key to anything:
--  the platform deliberately has no table of resources, because a resource can
--  be uninstalled and a row that outlives its owner is a row nobody cleans up.
--
--  The composite primary key is the index: every read is `WHERE owner = ?`, which
--  is a prefix of the key, so there is nothing extra to add. A separate index
--  on `owner` would be a second copy of the same left-hand prefix and would make
--  writes slower to buy a lookup the key already answers.
--
--  `v` holds an ENCODED value, and the encoding is cis_core's business rather
--  than the schema's -- which is why it is LONGTEXT and not JSON. A JSON column
--  truncates over some drivers' limits and hard-errors on others, and the
--  symptom is a state value that comes back empty for one player and not the
--  next.
--
--  `updated_at` is not decoration: it is what makes "this server was restored
--  from four hours ago" answerable, and the only way to tell a stale cache from
--  a stale row.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `cis_state` (
    `owner`      VARCHAR(64) NOT NULL,
    `k`          VARCHAR(64) NOT NULL,
    `v`          LONGTEXT    NULL,
    `updated_at` BIGINT      NOT NULL DEFAULT 0,
    PRIMARY KEY (`owner`, `k`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- -----------------------------------------------------------------------------
--  PRIVILEGES, if you are provisioning by hand
--
--  SELECT, INSERT, UPDATE, DELETE on the two tables above. NOT CREATE, NOT
--  DROP, NOT ALTER.
--
--  Giving the game user DDL rights is the normal FiveM arrangement and it is
--  the reason the ledger exists at all. Taking it away is better, and the cost
--  is one step: run this file once, by hand, and give the game user only DML.
--  The runner's statements are all `IF NOT EXISTS`, so every boot afterwards is
--  a no-op against a schema that is already correct.
--
--  GRANT SELECT, INSERT, UPDATE, DELETE ON `yourdb`.`cis_migrations` TO 'game'@'localhost';
--  GRANT SELECT, INSERT, UPDATE, DELETE ON `yourdb`.`cis_state`       TO 'game'@'localhost';
--  FLUSH PRIVILEGES;
-- =============================================================================