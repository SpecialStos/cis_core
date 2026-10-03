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

- **`Security.AdminGroup`** — the group or ACE permission a player needs to run
  `cis_core_info` / `cis_core_doctor` in game. Default `"admin"`, which QBCore
  and qbx_core both grant. ESX's superuser group is `superadmin`, which is not
  the same string, so an ESX server granting `superadmin` could never run these
  in game and received silence — the correct refusal and a baffling symptom at
  once.
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

- **The state size limit bounded structure, not bytes.** 256 entries x 8
  levels of large strings passed every check, was handed to `json.encode` --
  which materialises the whole thing as one string -- and only then reached the
  byte check. Hundreds of megabytes allocated inside one call to reject a value
  the rules had already decided to reject. Bytes are now counted as the walk
  meets them, so the refusal happens at the megabyte that crosses the line.
  `encodedSize` remains as the backstop for JSON quoting.
- **`SetPlayerJob` published a job ESX had refused.** ESX's `setJob` checks
  `DoesJobExist` and returns normally having changed nothing, and the publish
  announced the REQUESTED job regardless -- so the histogram and the player's
  own client learned a job that was never granted. It now publishes what the
  framework actually stored.
- **`GetPlayers()` returned a third shape under `NONE`** -- source-id strings,
  from the native -- on the one branch an operator reaches precisely because
  something is already wrong. It now returns normalised objects like the other
  two branches.
- **A typo fix could name the wrong key.** `Typ` is one edit from both
  `Framework.Type` and `Framework.Database.Type`; the two tied, and
  lexicographic order sent the operator to the DEEPER one. Ties now resolve to
  the shallower path, and the suggestion is stable across runs -- it was
  iterating raw `pairs` order, which is the one place this file's own
  determinism rule did not hold.
- **The state store reported a dropped connection as a key too long.** The
  driver's SELECT answers nil for "no such row" and for "the query failed", and
  the two-call upsert blamed the key -- so an operator with a database outage
  was told to shorten a key that was fine. Both causes are named now.
- **The doctor reported a cis_libs failure as "your framework is not
  started."** `GetCapabilities` raising and a genuinely absent framework looked
  identical, and the printed fix changed nothing. They are separate lines now.
- Duplicate allow-list entries were under-reported (`{A, A, A}` reported one),
  and the edit-distance prune was narrower than the acceptance threshold it
  guarded, so a near-miss key was silently never suggested.
- **[SECURITY] The job histogram was writable by any client.** `resolveSource`
  hardened who an event was *about*; it said nothing about *what* the event
  claimed, and both job-update handlers read the job straight out of the payload.
  `TriggerServerEvent('QBCore:Server:OnJobUpdate', nil, { name = 'police' })`
  put the sender in the police histogram while their actual framework job was
  `unemployed` -- and that histogram is what dispatch balances and
  minimum-staffing are answered from. Worse, `job.name` was only tested for
  truthiness, so a fresh table per call was a new unbounded histogram key while
  decrementing a legitimate count. The job is now DERIVED SERVER-SIDE from the
  framework, exactly as `QBCore:Server:PlayerLoaded` already did. The framework
  is the authority on what job somebody has; an event about it is a
  notification, not an instruction.
- **[SECURITY] The forgery counter was forgeable by anyone.** A client event
  carrying *no* source incremented it, because `nil == netSource` is false.
  A zero-byte `TriggerServerEvent` in a loop was enough, and
  `cis_core_doctor` then told an operator "N spoofed event source(s) refused --
  a client sent an event naming somebody else's source". Nothing was named and
  nothing was refused. A forgery is now a NUMBER that is not the sender, counted
  as one; an event that named nobody is counted separately and is evidence of
  nothing.
- **Every ESX money call with the default account silently did nothing.** The
  default was `'cash'`, which is a QBCore money type. ESX's accounts are
  `bank`, `black_money` and `money` -- there is no `cash` -- so
  `addAccountMoney('cash', 100)` raises inside ESX, the pcall catches it, and
  `GiveMoney(src, 500)` returns `false`. That is byte-identical to "insufficient
  funds", and it is the documented call. The default is now per framework:
  `money` on ESX, `cash` on QBCore and QBOX.
- **The AUTO detection path could claim a framework it had not reached.**
  `provider` is set from the detection result before any branch runs, and the
  QBCORE and ESX branches had no `else`, so a `GetCoreObject` or
  `getSharedObject` that failed left `provider == 'QBCORE'` with `QBCore ==
  nil`: every method answered nil while the console had already printed
  "framework QBCORE -- detected". This is the bug the CONFIGURED branch was
  written to fix, on the path that is the shipped default. Both branches now
  degrade to NONE with a recorded reason.
- **[SECURITY] `Migrate` ran arbitrary SQL for any resource that could call
  it.** Every other export in this resource is namespaced: `StateSet` writes one
  key in the caller's own namespace, and the framework capability returns the
  caller's own player object. `Migrate` takes a LIST OF SQL STRINGS and executes
  them against the platform's connection with no namespace and no ownership
  check -- and the ledger records the `owner` string the caller CHOSE to pass,
  which is data, not proof. So a resource with no database rights of its own
  could read and write anything the connection reaches. It is now gated on
  `Security.AuthorizedResources`, with a refusal that names the setting.
  Deliberately NOT applied to the state exports: those are namespaced by
  construction, and gating them would mean every product that wants to store a
  setting had to be added to a config file first, which is the friction the
  state store exists to remove.
- **The ESX-LEGACY fallback could take the boot thread down.** ESX 1.10.10
  turned `esx:getSharedObject` into an error(): its handler is literally
  `function() error("...this event no longer exists!") end`. The fallback
  triggered it unguarded, so on 1.10.10 an unguarded raise inside a thread
  nobody awaits left the resource half-started and attributed the error to a
  different file in the console. A raise now also STOPS the retry loop rather
  than repeating it 60 times: silence means a build that has not finished
  wiring, and an error means a build that has decided the event is gone.
  Fixed in both the server and the client half.
- **[ESX WAS COMPLETELY BROKEN] Every xPlayer call was missing its `self`.**
  ESX declares its player methods as `function self.addAccountMoney(accountName,
  money, reason)` -- declared against `self`, so `self` is the first DECLARED
  parameter. All seven of them were called here with a dot, which feeds the
  first real argument into `self`: `getGroup()` gets `self = nil` and RAISES;
  `addAccountMoney('cash', 100)` gets `self = 'cash'` and `money = nil`;
  `setJob('police', 3)` gets `newJob` = the number 3; `getName()` and
  `getAccounts()` RAISE. So on ESX, money did not work, job changes did not
  work, permissions raised, and the character name was unavailable.
  `GiveMoney` is wrapped in a pcall and returned false, which reads exactly like
  a declined transaction. QBCore is the OPPOSITE convention -- its `Functions`
  is a table, the implicit self is that table, and a dot call is already
  correct -- which is why this survived: the file had adopted QBCore's rule for
  both frameworks.
- **`NormalizedPlayer().metadata` was nil on every ESX server.** `get('metadata')`
  asks `self.variables['metadata']`, and metadata lives in `self.metadata` --
  two separate tables. The field was present, correctly typed, and always empty,
  so a consumer checking `metadata.hadcuffed` took the "not handcuffed" branch
  forever with nothing saying why.
- **`GetPlayers()` returned two different shapes.** The QBCore branch returned
  player objects; the ESX branch returned `ESX.GetPlayers()`, which since 1.9.2
  *is* the FiveM native and answers source-id strings. One method, two shapes,
  and the bug that produced lived in the consumer, on a platform its author
  never tested.
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