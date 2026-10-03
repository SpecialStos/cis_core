# cis_core — documentation

**Version 1.1.0.** This resource holds data. It is the only part of the
platform allowed to own a table, and it owns exactly two: `cis_migrations`,
the ledger, and `cis_state`, the state store.

---

## §0 — Read this first

**`cis_core` is not a library.** It is a product that plugs in behind
`cis_libs`. Everything it does is registered into `cis_libs` as a *capability*,
and `cis_libs` forwards to it.

| Resource | Owns tables | Price | Required by `cis_core`? |
|---|---|---|---|
| `cis_libs` | **never** | free, always | **yes** |
| **`cis_core`** | yes (two: `cis_migrations`, `cis_state`) | free with purchase | this |
| `cis_bridge` | no | free with purchase | no |
| `cis_keys` | yes | paid, private | no |

Five jobs at boot, in this order, and the order is the contract:

1. **Wait for `cis_libs`.** Everything below is a call into it.
2. **Hand over the configuration.** `cis_libs` publishes what the operator
   wrote; every module in the platform reads the copy `cis_libs` holds.
3. **Register the capabilities.** `framework`, `inventory`, `security`.
4. **Announce.** So `cis_debug` has something true to print.
5. **Validate and report.** The config the operator actually wrote, next to
   the platform's answer to it. See §6.

If you are integrating this, the two things that matter are in §2 (the
framework surface) and §5 (migrations and state). The rest is context.

---

## §1 — Install

```cfg
ensure cis_libs
ensure cis_core
```

`cis_core` declares `dependencies { 'cis_libs' }`, so **the start order in your
server.cfg does not matter for this resource.** `cis_libs` must be on disk and
started; which is a much weaker constraint than the one this resource used to
impose on its consumers.

`cis_bridge` and `cis_keys` are optional. Without them you have a framework
bridge, your configuration, the migration ledger, the state store, and no
third-party targets, no database and no doors.

### 1.1 Then run this

```
cis_core_info
```

One line. It is the fastest way to find out whether the resource is working,
and it is safe to paste into a support thread — it carries a version, a
framework name and a count.

---

## §2 — The framework abstraction

One normalized surface over ESX, ESX-LEGACY, QBCore, qbx_core and standalone.

This resource registers itself into `cis_libs` as the `framework` capability,
**on both realms.** Consumers never call it directly — they call
`Cis.framework.*` and `cis_libs` forwards.

### 2.1 Detection

`AUTO` asks the server what is **actually running** rather than trusting the
configured name. This is not a nicety:

> An operator configuring `Type = "QBCORE"` on a server running qbx_core got a
> library that reported itself ready and then returned `nil` for every player,
> with nothing in the console saying why.

Every detection result carries a `reason` in plain words, and that field is
the point. A name alone cannot distinguish *falling through to standalone*
from *correctly standalone*, and that ambiguity was the bug.

| `how` | Meaning |
|---|---|
| `detected` | Found by probing. Trust it. |
| `configured` | The operator named it explicitly and it is (or is not) running. |
| `custom` | An operator-supplied adapter won over everything, including an explicit `Type`. |

The framework table is **ordered most-specific-first**, and the order is
load-bearing: a qbx_core server also has `qb-*` resources on disk, and a naive
"is anything started" scan reports whichever it finds first.

**The client and the server call the same detection function.** They did not
before, and the divergence was a live bug: on a qbx_core that removed
`GetCoreObject`, the client fell through to standalone and `cis_libs:jobUpdated`
never fired, while the server worked fine. Nothing errored; notifications fell
back to the native feed and job tracking simply never started.

**The client registers the capability too.** It did not for most of this
resource's life, so `Cis.framework` was false on the client and every
notification fell to the GTA feed on a configured server.

### 2.2 The server surface

Registered as `CisCoreFramework` and reachable through `Cis.framework`.

| Method | Returns | Standalone (`NONE`) answer |
|---|---|---|
| `IsLoaded()` | `boolean` | `false` |
| `GetPlayers()` | table of player objects, or the native `GetPlayers()` | native list |
| `GetPlayer(src)` | player object, or `nil` | `nil` |
| `GetPlayerIdentifier(src)` | `string\|nil` | `nil` |
| `GetPlayerJob(src)` | job table, or `nil` | `nil` |
| `SetPlayerJob(src, job, grade)` | `nil` | no-op |
| `HasPermission(src, permission)` | `boolean` | `false` |
| `GetOnlineJobCount(jobs)` | `number` | `0` |
| `GiveMoney(src, amount, account)` | `boolean` | `false` |
| `RemoveMoney(src, amount, account)` | `boolean` | `false` |
| `GiveItem(src, item, amount)` | `boolean` | `false` |
| `RemoveItem(src, item)` | `boolean` | `false` |
| `Notify(src, message, kind)` | `nil` | falls back to the client feed |
| `CreateCallback(name, cb)` | `nil` | Registers an ESX-shaped callback. **See §2.3.** |
| `NormalizedPlayer(src)` | see below | `{ id = src }` |

**Every method has a no-framework answer, and it is never an exception.** A
server that cannot find a framework boots, prints one line saying so, and serves
everything else. The "provider unavailable" path is a *mode*, not a failure.

#### `NormalizedPlayer(src)`

```lua
{
    id         = 5,           -- server id, always present
    name       = 'string|nil',
    job        = { name = ..., grade = ... } | nil,
    identifier = 'string|nil',   -- the framework's own, e.g. 'license:...'
    money      = { cash = 500, bank = 1200 } | nil,
    metadata   = <raw framework metadata> | nil,
}
```

This is the one shape every product should read. `cis_housing` wants
`identifier`, a robbery wants `money.cash`, a job-gated door wants `job.name` —
and none of them should branch on which framework is running.

`money` is deliberately not normalised further than "a table keyed by account
name": the SQL frameworks hand back a money table and ESX hands back an account
list, and collapsing them to a common currency would mean picking one and losing
information the other carries.

### 2.3 `CreateCallback` is a compat shim, and it is synchronous only

```lua
Framework.CreateCallback(name, function(src, cb, ...) cb(result) end)
```

This wraps an **ESX-shaped** callback (one that takes a reply function) into
`cis_libs`' own callback registry, so an ESX-era consumer keeps compiling on
QBCore.

**It is synchronous only.** It calls the handler, waits for the handler to call
its reply function, and returns whatever came back. A handler that yields — a
database query, an HTTP request, a `Wait` — will not produce an answer, and the
caller gets nothing rather than an error.

**Use `Cis.callback.register` / `Cis.callback.await` instead.** They are
asynchronous, they are the library's own shape, and they work identically on
every framework without a shim in between.

### 2.4 The client surface

Registered as `CisCoreFramework`, plus `CisCoreFrameworkNotify`.

| Method | Notes |
|---|---|
| `GetPlayerData()` | `nil` until the character is loaded. Normal on a fresh connect. |
| `GetPlayerJob()` | The client's cached copy. Valid only while a character is loaded. |
| `ShowNotification(message, kind)` | Falls back to the native text feed. |
| `TriggerServerCallback(name, cb, ...)` | Routes through `cis_libs`' callback layer. |
| `HasItem(item, amount)` | **A hint.** A client-side view, not authority. |
| `CreateVehicle(model, coords, heading, cb)` | `cb(vehicle)`; `vehicle == 0` on model-load failure. |
| `GetOnlineJobCount(jobs, cb)` | `cb(count)`. |

**There is exactly one definition of `ShowNotification`.** There were two, and
the second forwarded to `cis_libs:Notify`, which forwards back to the
`framework` capability's `ShowNotification`. Registering the capability while
both existed would have been unbounded cross-resource recursion waiting to
happen.

### 2.5 Custom adapters

An operator can wire up a framework this library has never heard of:

```lua
Config.Framework.Custom = {
    resource = 'my_framework',
    name = 'MYFRAME',                    -- optional, uppercased
    getPlayer = 'GetPlayer',             -- an export name to probe for
}
```

A custom adapter **wins over everything**, including an explicit
`Config.Framework.Type`. If an operator wired up their own framework, guessing at
a known one instead is never what they meant.

`CisCustomFramework` as a raw global is also honoured, and is the form that
works before any config file is read.

---

## §3 — Shape normalisation

`shared/normalize.lua`, loaded in both realms. Six pure functions, each of
which exists because a decision inside an adapter was untestable while it was
written inline.

| Function | Decides |
|---|---|
| `itemEntry(entry)` | Which field is this inventory's item name (`name` or `item`), and which is its amount (`amount` or `count`). |
| `itemCount(list, item)` | The same answer, summed. `0`, never `nil`. |
| `itemSnapshot(list)` | `{ [name] = total }` — the one shape consumers read. |
| `jobFromPayload(data)` | Whether a framework event carries the job itself or a `playerData` wrapping it. |
| `moneyRoute(account)` | Whether an account name is an account or an item. |
| `accountMap(accounts)` | ESX's account *list* into the map QBCore already returns. |

Two things in there are load-bearing and worth stating:

- **`jobFromPayload` checks `.job` before the payload itself.** A qbx_core
  `playerData` carries a character `name` field alongside its `job`, so one
  payload matches *both* accepted shapes at once. Read the other way round, such
  a payload resolves to the whole `playerData` — whose `.name` is the
  character's — and the job is dropped. The client keeps a stale job and nothing
  reports it. That is the shape qbx_core actually sends.
- **`amount = 0` stays `0`.** Written `entry.amount or entry.count or 1`, a zero
  survives (0 is truthy in Lua). Written `if not entry.amount then 1`, it does
  not — and that variant hands a player an item they do not have.

An entry carrying both `name` and `item` set to different values resolves to
`name` everywhere. The counter used to match it as either item while the
snapshot filed it under `name`: one entry, two inventories, one function each
way.

---

## §4 — Configuration

`configs/master_config.lua` is the file an operator edits. It is here rather
than in `cis_libs` because a library has no business shipping an editable file
that is simultaneously its documentation and its load-bearing state.

**Any key you leave out falls back to the library default.** The merge is
recursive, so setting one leaf of `Framework.Target` keeps the rest of that
table rather than blanking out the sections around it.

| Key | Default | Notes |
|---|---|---|
| `CheckVersion` | **`false`** | Off is a security decision. **A commercial product should not phone home.** |
| `VersionCheckUrl` | `api.cisoko.net` | Read only when `CheckVersion` is true. Point it at your own mirror for zero contact. Never paste a real hostname to "test" it on a live server — the response body is printed. |
| `CallbackTimeout` | `10000` | Raising is safe. **Lowering is the risky direction** — below 500 ms a slow client turns every callback into a timeout, and a nil that means "too early" is indistinguishable from a nil that means "no such thing". |
| `UpdateInterval` | 1000 each | Event-driven with a timer as a safety net. 2000–3000 is usually indistinguishable in game. |
| `AimingCheckType` | `"default"` | `IsPlayerFreeAiming()`. `"configFlag"` is **not** the aiming state on current builds. |
| `Framework.Type` | `"AUTO"` | `AUTO` probes. |
| `Framework.Inventory` | `"ox_inventory"` | Advisory. If not started, counts fall back to the framework's own table, which is usually empty. |
| `Framework.Zones.Enabled` | `true` | `false` makes every zone export return `false, 'zones disabled by config'`. |
| `Framework.Target.*` | `ox_target` | Consumed by `cis_bridge`'s adapters. |
| `Framework.Database.Type` | `"AUTO"` | `"mysql-async"` is **not** accepted and has no adapter; naming it produced a server that registered an adapter and then raised on its first query. |
| `Framework.Database.Timeout` | `15000` | Raising only makes a stalled query hang longer. |
| `Sync.Enabled` | `true` | |
| `Printing.Debug` | `false` | Verbose by design. |
| `Printing.UseDiscordLogs` | **`false`** | **The master switch for everything outbound.** While false nothing is sent anywhere, so a placeholder webhook is inert no matter what it contains. |

### 4.1 Security

`configs/security_config.lua`.

| Key | Default | Notes |
|---|---|---|
| `Security.EventPrefix` | `"cis_libs"` | **Keep it.** Changing it moves every event name; any resource triggering them directly must change in the same edit, and the failure is silence, not an error. |
| `Security.AuthorizedResources` | the platform roster | §4.2. |
| `Security.DropPlayer` | **`false`** | Log only. §4.3. |
| `Security.Debug` | `false` | Reserved, unread. Do not build on it. |

### 4.2 The allow-list

An authorised resource may call the **mutating** half of `cis_libs`: add a door,
break a door, write a sync record, supply a capability.

**It ships with the publisher's own products on it, and nothing else.** There is
no wildcard, no prefix match, and no "any resource whose name starts with
`cis_`", so a third-party resource cannot inherit a grant by being named
similarly.

It used to ship **empty**, on the reasoning that a new server has no authorised
callers and "nobody" is the honest answer. That reasoning was sound and the
outcome was not: every CIsoko product was refused by default, which means every
install had to be repaired by hand before it worked, and the repair is invisible
until something breaks. A secure default that has to be edited before the
product functions is not a secure default — it is a broken install with a good
story.

**An empty list still means nobody.** That behaviour is unchanged. Set
`Security.AuthorizedResources = {}` for a fully manual install and add names as
you go.

**One residual risk, stated plainly.** An entry that is not installed grants
nothing today, but a grant is attached to a *name* — so a stale entry becomes
live the day a different resource is installed under that exact name. `cis_core_doctor`
prints every entry that is authorised but not started, so a stale entry is
visible rather than latent. Delete the entries you do not have.

To add your own resource:

```lua
Security.AuthorizedResources = {
    'cis_housing',
    'my_resource',
}
```

A resource can ask before it acts rather than guessing:

```lua
if exports['cis_libs']:InvokingAllowed() then ... end
```

**What an entry buys, precisely:** the right to call mutating exports. Not money,
not inventory, not database access, and nothing at all in the client payload — a
player can never read this list.

### 4.3 The drop handler

`Security.DropPlayer` defaults to **`false` — log only**.

It shipped as `true`, and that was wrong for a resource whose headline feature
is a framework abstraction: a player got kicked from a platform they installed to
get their framework bridged, on the strength of a heuristic another resource
raised, and they were told a server owner had been informed when nothing had
been. `cis_libs` documents this default as `false`, and every other resource in
the platform should match it. A library does not remove players from a server as
a side effect of reporting something suspicious.

To enforce, one line at the bottom of `configs/security_config.lua`:

```lua
Security.DropPlayer = cisAnticheatDropPlayer
```

**A function cannot be sent** across the exports boundary; it arrives as `nil`.
So the function that implements a drop is registered as a *capability*:

```lua
exports['cis_libs']:SetDropPlayerHandler('cis_core:CisCoreDropPlayer')
```

The result is exactly one line in the whole platform that can drop a player for
a security report, and it is auditable.

**Keep the message generic.** Naming the check that fired tells a person exactly
which guard to look for, and guards are the first thing somebody wants to find.

### 4.4 What a client is told

A hand-built whitelist, not a copy with secrets removed. A key added to the
config does not reach a client until someone adds it to the whitelist. No
webhook, no database block, no allow-list, no kick handler.

---

## §5 — Data: migrations and state

### 5.1 Migrations

`cis_core` owns `cis_migrations`, the ledger: one row per applied migration id,
with when it was applied and how long it took.

**A product with a real schema brings its own table** and registers it here, so
the platform never grows a table that belongs to one product and gets dropped
when that product is uninstalled.

```lua
exports['cis_core']:Migrate('my_resource', {
    { id = '001_shops',   statements = { 'CREATE TABLE shops (id INT)' } },
    { id = '002_shops_x', statements = { { sql = 'ALTER TABLE shops ADD x INT', values = {} } } },
})
```

| Field | Meaning |
|---|---|
| `id` | A stable string. **Never change one once applied** — the ledger is keyed on it, so renaming re-runs the migration. |
| `statements` | SQL strings, or `{ sql = ..., values = ... }`. Run in order. |

Returns `ok, result` where `result` is
`{ applied = n, skipped = n, failed = id, partial = bool, reason = string }`.
**It returns rather than raises, always.** A product whose schema fails is a
product that cannot work, and it needs to be able to say so and carry on
booting.

**Ordering.** Numbered ids sort **numerically**, so `9_thing` runs before
`10_thing` — which a plain string sort gets backwards. Unnumbered ids run last,
alphabetically. The order is stable regardless of the order you wrote the list
in, which is the property that matters.

**Refused before anything executes:** no `id` (it can never be recorded, so it
re-runs on *every boot*), duplicate `id` (the second silently never runs), no
`statements` (it does nothing and reports success), an empty statement (same,
for one step of a multi-step migration). All four look fine from the console and
are discovered weeks later, which is why they are caught here.

**Atomicity, honestly.** The ledger `INSERT` is the last query of the
transaction, so a driver with transactions makes the schema change and its own
record one unit. MySQL commits implicitly on DDL, so a transaction does **not**
roll back a `CREATE TABLE` that already ran. That is why a failure reports
`partial = true` and says so in a sentence — an operator needs to know which
statements landed, and the runner is the only thing in the platform that can
tell them.

```sql
CREATE TABLE IF NOT EXISTS cis_migrations (
    id          VARCHAR(128) NOT NULL PRIMARY KEY,
    applied_at  BIGINT NOT NULL,
    duration_ms INT NOT NULL DEFAULT 0
)
```

### 5.2 State

`cis_core` also owns `cis_state`: the platform's one namespaced, durable
key/value store.

The roadmap gives this resource four jobs — framework abstraction, state, the
database, configuration — and three were here. The absence had a specific shape:
every product that wanted to remember something across a restart invented its own
table, which is the same problem the platform was built to solve, except with no
single view of it.

**The line between state and schema:** a value that belongs to one product and
has no shape is state; a thing with columns, indexes and foreign keys is a
schema. `cis_housing` brings a housing table. `cis_medic` stores "the last
time this player was treated" here.

```lua
exports['cis_core']:StateSet('last_treatment', { at = 1712345678, by = 'medic_station' })
local record = exports['cis_core']:StateGet('last_treatment', nil)
local all    = exports['cis_core']:StateAll()
local keys   = exports['cis_core']:StateKeys()
exports['cis_core']:StateDelete('last_treatment')
local removed = exports['cis_core']:StateClear()
```

| Export | Returns |
|---|---|
| `StateSet(key, value)` | `true`, or `false, reason` |
| `StateGet(key, fallback)` | the value, or `fallback`. **The fallback is returned on failure too**, so an unavailable store answers the default rather than `nil`. |
| `StateAll()` | a fresh table of the whole namespace, which the caller may mutate freely |
| `StateKeys()` | the keys, sorted, so two calls answer the same way |
| `StateDelete(key)` | `true`. Removing a key that is not set is `true`, not an error — "make sure this is gone" is what most callers actually want. |
| `StateClear()` | how many rows went |
| `GetStateSummary()` | `{ available, reason, namespaces }`, **read from the database** rather than from memory, so a restarted server reports what is really stored. No value is read, so no state is exposed by asking. |

**There is no `owner` argument anywhere in the public API.** The namespace *is*
`GetInvokingResource()`. That is the security property of this store and not a
limitation: a namespaced store where the namespace is a parameter is a store
where any resource can read and write any other resource's state, and the only
thing standing between them is a check somebody will eventually forget to
write. Deriving it at the boundary means crossing the boundary is the whole of
the enforcement — there is no code path in which one product names another.

**Server side only, and that is not an omission.** A client gets state the way
it gets everything else: through a server callback its own resource registers,
which is re-validated at the time of the call. There is no client export because
a client export over a shared namespace is a broadcast of whatever that product
decided to keep, and the decision about what a player may be told belongs to the
product, not to the store.

**Limits**, all enforced in `server/state_rules.lua` before anything is written:

| Limit | Value | Why |
|---|---|---|
| Key length | 64 | the column is `VARCHAR(64)`; longer is truncated by one driver and refused by another |
| Encoded value | 16 KB | a bigger value is a schema, a file or a log — `cis_migrate` is the tool for a real import |
| Nesting depth | 8 | past this it is a data structure, not a setting |
| Entries per table | 256 | without it one key can make a single write a very long request |

The rules **walk** the value rather than letting the encoder raise. `json.encode`
does refuse a function, but it refuses it deep inside a C routine with a message
about an internal type tag and no key on the stack. The pre-check answers *"the
value's `metadata.callback` is a function"*, which names the offending element.

A **self-referential table** is refused as *itself* rather than as "nested too
deep", because the depth cap alone reports the second thing about a value that
is one deep and loops — sending the reader to the wrong place. The same table
referenced twice is **not** a cycle and is accepted; a store that refused that
would be refusing a normal shape.

```sql
CREATE TABLE IF NOT EXISTS cis_state (
    owner      VARCHAR(64) NOT NULL,
    k          VARCHAR(64) NOT NULL,
    v          LONGTEXT    NULL,
    updated_at BIGINT      NOT NULL DEFAULT 0,
    PRIMARY KEY (owner, k)
)
```

`updated_at` is not decoration: it is what makes "this server was restored from
four hours ago" answerable, and the only way to tell a stale cache from a stale
row.

**When there is no database**, every state export answers `false, reason` and
says why. The check retries every five seconds rather than latching — a database
that comes back two minutes into the server's life must not leave the store dead
until the next restart.

---

## §6 — Diagnostics

The largest single cost saving in this resource. A config typo is a support
ticket; a boot line is not.

### 6.1 At boot

Every setting this resource reads is validated for type, accepted range and
known value, and **every problem is printed with the fix next to it**.

Real output, from a config with three mistakes in it:

```
cis_core: configuration: 1 error, 2 warnings, 1 note
  ERROR Config.Framework.Inventory is "ox_inventoryr", which is not a value this resource accepts
    fix: use "ox_inventory" instead -- nothing in this resource reads "ox_inventoryr", so the configured value is ignored and the documented fallback runs
  WARNING Config.Framework.Typ is not a key this resource reads, so it is ignored
    fix: this key lives at Config.Framework.Type -- did you mean that?
  WARNING Security.AuthorizedResources is not set, which this resource reads as an empty list
    fix: an empty list means NOBODY: every mutating call from another resource is refused, with the fix printed. List the resources you own if you have any.
  cis_core: carrying on anyway. Every setting above falls back to its documented default.
```

Notes are counted but not printed at boot — they are correct-as-shipped, and a
block that always has three lines in it is a block people learn to skim, which
is the one thing this block cannot afford. `cis_core_doctor` prints them.

Checked, among others:

- **Unknown keys.** A key nothing reads is invisible otherwise, because Lua
  accepts the assignment and says nothing. The fix names where that key actually
  lives, so `Config.Zones` points at `Config.Framework.Zones` rather than saying
  "remove it".
- **A value on the way to a key.** `Config.Framework.Target = 'ox_target'`
  validated clean until this was written: the walk cannot descend into a string,
  gives up, and the absence of `Target.Enabled` below it was indistinguishable
  from an operator who never wrote one. A correct config and a broken one
  produced the same report.
- **An allow-list written as a map.** `{ cis_keys = true }` is a natural thing to
  write and it authorises nothing at all, because the reader is `ipairs`.
- **A placeholder webhook.** Safe — the queue refuses it — but *silent*. "I
  turned logging on and nothing arrives" is a ticket; this line answers it
  before the ticket exists.

**The validator never raises and never blocks a boot.** A validator that crashes
on the malformed config it exists to explain is the one failure this feature has
to avoid; and a platform service that refuses to serve because one optional piece
is missing turns a config typo into an outage.

### 6.2 On demand

| Command | Prints |
|---|---|
| `cis_core_info` | one line: version, detected framework, inventory, migration count |
| `cis_core_doctor` | the whole report |

`cis_core_doctor` covers dependencies, `cis_libs`'s own self-check, every
capability slot and who holds it, the allow-list (authorised-and-running versus
authorised-but-not-installed), the state store, the migrations, and every
configuration problem. Each line is one of three severities:

| | Meaning |
|---|---|
| `MISSING` | something this resource needs is not there |
| `DEGRADED` | it is there, but not doing what the config asked for |
| `SET` | a decision an operator should know about |

**Both commands are console-only or admin.** The check is not decoration:
`RegisterCommand`'s third argument is FiveM's restricted flag, and a console that
forwards a player src — or a restricted flag that is not what it was assumed to
be — must not become a way to run a command without permission. A refusal is
**silence**, not a message that tells a stranger what this server runs.

**Nothing either command prints is a secret.** No webhook, no connection string,
no identifier, no config value. Resource names, booleans, counts and reasons
only. A diagnostic command that dumps config puts every secret on an operator's
screen and into their client log, and a support thread that quotes one has
leaked it.

### 6.3 As data

```lua
exports['cis_core']:GetDoctorReport()
-- { version = '1.1.0', environment = { ... }, config = { ok = bool, errors = {...}, warnings = {...}, info = {...} } }

exports['cis_core']:GetCoreSummary()
-- { configApplied, framework, inventory, targetProvider, databaseProvider, migrations }
```

---

## §7 — Inventory service

Registered into `cis_libs` as the `inventory` capability, on both realms.

This is the **service**, not a third-party adapter: the `name -> amount`
normalisation every consumer depends on, with the framework as its fallback.
The adapters behind it live in `cis_bridge`.

| Method | Signature | Returns |
|---|---|---|
| `Count` | `(src, item)` / `(item)` | `number`. **0, never nil** — a count is always a number. |
| `Add` | `(src, item, amount, metadata)` | `boolean` |
| `Remove` | `(src, item, amount)` | `boolean` |
| `Has` | `(src, item, amount)` / `(item, amount)` | `boolean` |
| `Snapshot` | `(src)` | `{ [itemName] = count }` — server only |

**A client count is a hint and always was.** It is a snapshot the server pushed,
up to one inventory event stale. Never gate a server-side action on it.

The provider is consulted first and the framework is the fallback. A missing
provider is therefore a *degraded* inventory, not a broken one — and the symptom
is "HasItem always says no", never a crash.

---

## §8 — Events

`cis_core` publishes **no** net events. It listens for:

| Event | From | Drives |
|---|---|---|
| `esx:playerLoaded` | ESX | `PublishJobUpdate`, `PublishInventory` |
| `esx:setJob` | ESX | `PublishJobUpdate` |
| `QBCore:Server:PlayerLoaded` | QBCore / qbx_core | `PublishJobUpdate`, `PublishInventory` |
| `QBCore:Server:OnJobUpdate` | QBCore | `PublishJobUpdate` |
| `QBCore:Client:OnPlayerLoaded` | QBCore | client job cache |
| `QBCore:Client:OnJobUpdate` | QBCore | client job cache |
| `QBCore:Player:SetPlayerData` | QBCore | client inventory counts |
| `qbx_core:client:playerLoaded` | qbx_core | client job cache |
| `qbx_core:client:onJobUpdate` | qbx_core | client job cache |
| `cis_libs:jobUpdated` | `cis_libs` | client job cache |
| `cis_libs:playerLoaded` | `cis_libs` | client job cache |
| `cis_libs:client:inventory` | `cis_libs` | client inventory counts |
| `ox_inventory:openedInventory` | ox_inventory | server inventory re-push |

The third-party names are declared **here** because this is the resource that
knows which framework is installed, so this is where an operator looks to see
every external event the platform depends on. The `cis_libs:*` names are declared
in `cis_libs`'s contract, because a name that moves between resources is one a
product can rename without anyone noticing until a consumer stops hearing about
it. They appear here as *dependencies*.

**Nothing is triggered here.** A product asking for a notification or an
inventory push goes through an export, so the wire stays in the one place that
owns it.

---

## §9 — Security notes

| Control | What it does |
|---|---|
| Config validation | Every value checked for type, range and known value at boot, with the fix printed |
| Event authority | `server/authority.lua`. A player source read out of an event payload is only believed when no networked sender can contradict it. Forgery is counted and reported by `cis_core_doctor`, logged once per boot |
| Unknown-key detection | A key nothing reads is reported; it is otherwise invisible |
| Namespaced state | The namespace is `GetInvokingResource()`. There is no code path in which one product names another |
| State rules | Key and value walked before write: no function, no cycle, no depth bomb, no unbounded table |
| Drop handler | One capability, one line in the platform that can drop a player. **Off by default** |
| Client redaction | Whitelist, not a copy with secrets removed |
| Allow-list | Names only, no wildcard. Stale entries reported |
| Version check | Off by default, and pointing at a host the operator controls |
| Detection | Probes, never guesses; a `nil` framework is a stated mode, not a silent one |
| Diagnostics | Resource names, booleans, counts and reasons. Never a secret |

**What is deliberately not defended against:** anything in your `server.cfg`
already has every permission you have. These controls are against accidents and
sloppy code, and they log loudly when they fire.

See `SECURITY.md` for the trust model and the report process.

---

## §10 — Upgrading from 1.0.x

1. **`Security.AuthorizedResources` now ships the platform roster** instead of an
   empty list. If you had edited it, your list is replaced by the shipped one —
   **put your own resource names back into `configs/security_config.lua`.** This
   is the one change in 1.1.0 that can affect behaviour.
2. **`Security.DropPlayer` now defaults to `false`.** If you relied on the kick,
   uncomment the one line at the bottom of `configs/security_config.lua`.
3. **A second table, `cis_state`, is created** by `cis_core`'s own migration
   through the ledger. Nothing else about your schema changes.
4. **`mysql-async` is no longer accepted** as a database driver name. No adapter
   ever supported it; naming it produced a server that registered an adapter and
   raised on its first query.
5. Two console commands are new: `cis_core_info` and `cis_core_doctor`.
6. `Migrate` and `AppliedMigrations` are unchanged. The runner moved behind
   `CisMigrationRunner` so `cis_core` could apply its own schema; the exported
   name and signature did not change, so no consumer sees a difference.

---

## §11 — Tests

```
npm install
npm test          # 224 assertions, no FiveM server required
npm run test:all  # + syntax check + the api contract self-test
```

| Suite | Covers |
|---|---|
| `migrations` | ordering, validation, planning, the config accessor with no library |
| `normalize` | every shape reading in §3, on every payload shape in the wild |
| `state` | the value rules: JSON types, cycles, depth, width, size |
| `config` | the validator, including every malformed input that must not raise |
| `authority` | the event-authority rule, with `source`, `GetMaxPlayers` and `GetPlayerName` stubbed and the rule itself not |

`api.lua` at the resource root is the machine-readable contract. It is plain
data, not a script, and `tools/validate-api.js` fails if it ever drifts from
what the code actually registers — **exports, net events and console commands
alike**.

The framework abstraction and the inventory service are adapters around natives
and third-party exports, and are deliberately **not** unit-tested against a mock
— testing the mock proves nothing about the framework. What is tested is the part
that is genuinely pure and genuinely has bitten us: the ordering, the
normalisation, the value rules, and the validator.

---

## §12 — Layout

```
fxmanifest.lua        depends on cis_libs
api.lua               data. the contract. not loaded at runtime
configs/              the files an operator edits
shared/
  cis.lua             the seam: the client config accessor
  migrations.lua      the PURE half -- ordering, validation, planning
  normalize.lua       the shape reading, both realms, pure
framework/
  framework_server.lua  detection, the normalized surface, the capability table
  framework_client.lua  the same surface, client side
server/
  validate_config.lua   the boot-time validator. pure
  authority.lua         who an event is really about
  state_rules.lua       the state value rules. pure
  inventory.lua         the inventory service and its capability table
  migrations.lua        the runner, cis_migrations, and cis_core's own schema
  state.lua             the state store, namespaced by the calling resource
  doctor.lua            the report, as lines and as data
  commands.lua          cis_core_info, cis_core_doctor
  initialize.lua        boot, config handover, capability registration
client/
  inventory.lua       the client count cache
test/  tools/
```

---

## §13 — Licence

MIT. See `LICENSE.md`. The attribution notice must be retained in every copy.

---

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> ·
**Discord:** <https://discord.gg/cisoko>