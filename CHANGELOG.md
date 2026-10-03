# Changelog

All notable changes to `cis_core` are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

`api = 1` in `api.lua` is the **contract major**, and is not the product version.
It moves when something a consumer depends on changes shape. It is still 1: this
release adds, and nothing that existed in 1.0.0 changed signature.

---

## [1.1.0] — 2026-10-03

The release that makes the platform say what is wrong with it, and gives it the
state the roadmap has been asking for since it was written.

### Added

- **State store.** `cis_state`, the platform's one namespaced, durable
  key/value store: `StateSet`, `StateGet`, `StateAll`, `StateKeys`,
  `StateDelete`, `StateClear`, `GetStateSummary`. The roadmap gives this
  resource four jobs — framework abstraction, state, database, configuration —
  and three were here. Every product that wanted to remember something across a
  restart invented its own table, which is the problem the platform exists to
  solve, reproduced one product at a time.
- **State value rules** (`server/state_rules.lua`), pure and tested: key length
  and character set, JSON-encodable values only, no cycles, a depth cap, an
  entry cap and an encoded-size cap.
- **Boot-time configuration validator** (`server/validate_config.lua`), pure and
  tested. Every setting this resource reads is checked for type, accepted range
  and known value; unknown keys are reported; every problem carries its fix.
- **`cis_core_info`** — one line: version, detected framework, inventory,
  migration count.
- **`cis_core_doctor`** — the full install report: dependencies, `cis_libs`'s own
  self-check, every capability slot and who holds it, the allow-list, the state
  store, the migrations, and every configuration problem.
- **`GetDoctorReport`** — the same report as data, for a support thread.
- **`CisMigrationRunner`** — the migration runner as a table rather than a pair
  of file-private locals, so `cis_core` can apply its own schema through the
  ledger instead of hand-rolling a `CREATE TABLE` that nothing records.
- **`shared/normalize.lua`** — the shape reading, in both realms, tested.
- **Console commands in the contract.** `api.lua` now declares a `commands`
  table, and `tools/validate-api.js` scans `RegisterCommand` and
  `Cis.command.add` out of the source the way it scans exports. `restricted` is a
  required boolean, because whether a command is safe to mention in public is the
  first thing a reader of it needs to know.
- **Allow-list reporting.** `cis_core_doctor` prints every authorised entry that
  is not installed, and every installed resource missing from the list — whose
  mutating calls are being refused right now.

### Changed

- **`Security.AuthorizedResources` now ships the platform roster** instead of an
  empty list. Every CIsoko product was refused by default, so every install had
  to be repaired by hand before it worked, and the repair is invisible until
  something breaks. An empty list still means nobody; delete the entries you do
  not have. **See §10 of DOCUMENTATION.md before upgrading.**
- **`Security.DropPlayer` now defaults to `false`** — log only — matching
  `cis_libs`' published default. It shipped as `true`, and a platform installed
  for its framework bridge should not remove players from a server as a side
  effect of another resource raising a heuristic. One uncommented line turns it
  back on.
- **The inventory counter and the inventory snapshot agree.** An entry carrying
  both `name` and `item` set to different values used to match the counter as
  either item and appear in the snapshot under `name` — one entry, two
  inventories, one function each way. Both resolve to `name` now.
- **`mysql-async` is no longer accepted** as a database driver name. No adapter
  ever supported it; naming it produced a server that registered an adapter and
  raised on its first query.
- **The test harness is shared and aggregated in `run.js`.** Each suite used to
  call `os.exit(1)` itself, which took the whole Lua state with it: the first
  failing suite ended the run, every suite after it never executed, and the
  output still showed the suites that had already passed — which reads exactly
  like a green run.

### Fixed

- **[SECURITY] A client could make another player receive a job they did not
  have.** Every server-side handler read the player source out of the *event
  payload*, and in FiveM a client can `TriggerServerEvent` with any name and any
  payload — so `esx:playerLoaded` was not an ESX event, it was a name a player
  could type. `PublishJobUpdate` ends in
  `TriggerClientEvent('cis_libs:jobUpdated', src, …)`, so a client naming
  somebody else's source made that player's client receive a job it did not
  have — and this resource's own client stores exactly that event, so the
  poisoned job was the platform's and not only a consumer's. Five handlers were
  affected. See §9 of `DOCUMENTATION.md` and `SECURITY.md` §1.2.
- **[SECURITY] The client listened to a qbx_core event that is not a player's
  job change.** `qbx_core:client:onJobUpdate` is the job *definition* registry
  event — `server/groups.lua` broadcasts it to every client as
  `(jobName, definition)` on every job-definition edit. It was bound to the
  player-job handler, which was harmless only because the first argument is a
  string and the shape reader rejected it. A job definition table has a `name`
  field, so an upstream argument reorder would have stored a definition as the
  player's job with nothing erroring. `qbx_core:client:playerLoaded` does not
  exist in any qbx_core release and its listener was dead from the day it was
  written. Both verified against qbx_core v1.24.0 source.
- **The qbx_core job path was broken.** A qbx_core `playerData` carries a
  character `name` field alongside its `job`, so one payload matched both
  accepted shapes at once. Read as `data.name and data or data.job`, such a
  payload resolved to the whole `playerData` — whose `.name` is the character's
  — and the job was dropped. The client kept a stale job and nothing reported
  it. `.job` is now checked first.
- **Detection called a global that is always nil on this side of the boundary.**
  `CisDetect` is defined in `cis_libs` and FiveM gives every resource its own
  Lua state, so `detect()` raised inside an un-awaited thread on every stock
  install — the framework capability was never registered, no job count was
  claimed, and every player lookup answered nil.
- **The client never registered the framework capability**, so `Cis.framework`
  was false on the client and every notification fell to the GTA feed on a
  configured server.
- **`ShowNotification` was defined twice.** The second definition forwarded to
  `cis_libs:Notify`, which forwards back to the framework capability's
  `ShowNotification`. Registering the capability while both existed would have
  been unbounded cross-resource recursion.
- **The framework's client events were registered against nil handlers.**
  `QBCore:Client:OnJobUpdate`, `qbx_core:client:onJobUpdate`, `esx:setJob` and
  the three playerLoaded events were received and discarded.
- **The webhook config never crossed to `cis_libs`,** which looked for a global
  in its own state. Real webhooks sent nothing, silently.
- **The migration ledger write was unchecked,** so a database that could not
  create the table still reported success and every migration re-ran on every
  boot.
- **The ledger row is now the last query of the transaction,** so a failed record
  no longer leaves applied schema unrecorded. MySQL commits DDL implicitly,
  which is why a failure still reports `partial = true`.
- **`QBOX` configured on `qb-core` left the two halves disagreeing** about which
  framework the server runs, because the config was rewritten only on the `AUTO`
  path. The client — which receives `Config.Framework.Type` verbatim in the
  config payload — took the `QBOX` branch and reached for a resource that is not
  installed.
- **A config with a wrong-typed value on the way to a key validated clean.**
  `Config.Framework.Target = 'ox_target'` could not be walked into, so the absence
  of `Target.Enabled` below it read as "the operator never wrote one".
- **Version drift between `api.lua`, `fxmanifest.lua` and `package.json` is now
  a build failure.** They reached 2.0.0 and 1.0.0 at once, and every operator who
  turned on the update check was told their 2.0.0 install was out of date against
  a 1.0.0 endpoint, forever.

### Test suite

224 assertions, up from 27. Four suites — migrations, normalize, state, config —
plus seven broken fixtures for the contract validator, up from four.

---

## [1.0.0] — 2026-09-30

First release after the platform split.

- Framework abstraction over ESX, ESX-LEGACY, QBCore, qbx_core and standalone,
  registered as the `framework` capability on the server.
- Configuration: the files an operator edits, moved here from `cis_libs`.
- Migrations: the `cis_migrations` ledger and the runner, with ordering,
  validation and idempotency by id.
- Inventory service, registered as the `inventory` capability on the server.
- `GetCoreSummary` for diagnostics.
- A contract validator that holds `api.lua` against the registered surface.