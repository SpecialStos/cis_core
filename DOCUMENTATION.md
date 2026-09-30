# cis_core — documentation

**Version 1.0.0.** This resource holds data. It is the only part of the
platform that is allowed to own a table, and it owns exactly one of its own.

---

## §0 — Read this first

**`cis_core` is not a library.** It is a product that plugs in behind
`cis_libs`. Everything it does is registered into `cis_libs` as a *capability*,
and `cis_libs` forwards to it.

| Resource | Owns tables | Price | Required by `cis_core`? |
|---|---|---|---|
| `cis_libs` | **never** | free, always | **yes** |
| **`cis_core`** | yes (one: `cis_migrations`) | free with purchase | this |
| `cis_bridge` | no | free with purchase | no |
| `cis_keys` | yes | paid, private | no |

Three jobs, in this order, and the order is the contract:

1. **Wait for `cis_libs`.** Everything below is a call into it.
2. **Hand over the configuration.** `cis_libs` publishes what the operator
   wrote; every module in the platform reads the copy `cis_libs` holds.
3. **Register the capabilities.** `framework`, `inventory`, `security`.

If you are integrating this, the two things that matter are in §2 (the
framework surface) and §5 (migrations). The rest is context.

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
bridge, your configuration, and the migration ledger, and no third-party
targets, no database and no doors.

---

## §2 — The framework abstraction

One normalized surface over ESX, ESX-LEGACY, QBCore, qbx_core and standalone.

This resource registers itself into `cis_libs` as the `framework` capability.
Consumers never call it directly — they call `Cis.framework.*` and `cis_libs`
forwards.

### 2.1 Detection

`AUTO` asks the server what is **actually running** rather than trusting the
configured name. This is not a nicety:

> An operator configuring `Type = "QBCORE"` on a server running qbx_core got a
> library that reported itself ready and then returned `nil` for every player,
> with nothing in the console saying why.

Every detection result carries a `reason` in plain words, and that field is the
point. A name alone cannot distinguish *falling through to standalone* from
*correctly standalone*, and that ambiguity was the bug.

```lua
-- what GetConfigSummary returns
framework        = 'QBCORE'                 -- the CONFIGURED name
frameworkDetail  = {                        -- what detection concluded
    name = 'QBOX', resource = 'qbx_core', version = '1.9.4',
    how = 'detected',                        -- detected | configured | custom
    reason = 'detected qbx_core (1.9.4) running',
}
```

| `how` | Meaning |
|---|---|
| `detected` | Found by probing. Trust it. |
| `configured` | The operator named it explicitly and it is (or is not) running. |
| `custom` | An operator-supplied adapter won over everything, including an explicit `Type`. |

The framework table is **ordered most-specific-first**, and the order is
load-bearing: a qbx_core server also has `qb-*` resources on disk, and a naive
"is anything started" scan reports whichever it finds first. That table is
shared with `cis_libs` and read from there, so a product cannot disagree with
the debug output about what is running.

**The client and the server now call the same detection function.** They did not
before, and the divergence was a live bug: the client defaulted to `NONE` where
the server defaulted to `AUTO`, and the client had no `GetPlayer` fallback. On a
qbx_core that removed `GetCoreObject`, the client silently dropped to
standalone and `cis_libs:jobUpdated` never fired — while the server worked
fine. Nothing errored; notifications fell back to the native feed and job
tracking simply never started.

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
| `RemoveItem(src, item, amount)` | `boolean` | `false` |
| `HasItem(src, item)` | `boolean` | `false` |
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

## §3 — Configuration

`configs/master_config.lua` is the file an operator edits. It is here rather
than in `cis_libs` because a library has no business shipping an editable file
that is simultaneously its documentation and its load-bearing state: every
consumer who copies one out of a support thread has silently forked the
library's behaviour.

**Any key you leave out falls back to the library default.** The merge is
recursive, so setting one leaf of `Framework.Target` keeps the rest of that
table rather than inheriting a table with a single key in it — which is what
naive `or` chains produce and why a half-written config used to blank out
unrelated settings.

| Key | Default | Notes |
|---|---|---|
| `CheckVersion` | **`false`** | Off is a security decision, not an oversight. When on, every boot fires an HTTPS GET to a hardcoded host with no operator opt-in. **A commercial product should not phone home.** |
| `VersionCheckUrl` | `api.cisoko.net` | Read only when `CheckVersion` is true. Point it at your own mirror for zero contact with the publisher. Never paste a real hostname "to test it" on a live server — the response body is printed into your console. |
| `CallbackTimeout` | `10000` | Raising is safe. **Lowering is the risky direction.** |
| `UpdateInterval` | 1000 each | Event-driven with a timer as a safety net. ~10 natives plus a vector4 per player per tick. 2000–3000 is usually indistinguishable in game. |
| `AimingCheckType` | `"default"` | `IsPlayerFreeAiming()`. `"configFlag"` is **not** the aiming state on current builds and reports false almost always. |
| `Framework.Type` | `"AUTO"` | `AUTO` probes. |
| `Framework.Inventory` | `"ox_inventory"` | Advisory. If not started, counts fall back to the framework's own table, which is usually empty. |
| `Framework.Zones.Enabled` | `true` | `false` makes every zone export return `false, 'zones disabled by config'`. |
| `Framework.Target.*` | `ox_target` | Consumed by `cis_bridge`'s adapters. |
| `Framework.Database.Type` | `"AUTO"` | Consumed by `cis_bridge`'s adapters. |
| `Framework.Database.Timeout` | `15000` | Raising only makes a stalled query hang longer. |
| `Sync.Enabled` | `true` | |
| `Printing.Debug` | `false` | Verbose by design; some of it is per-zone and per-entity. |
| `Printing.UseDiscordLogs` | **`false`** | **The master switch for everything outbound.** While false nothing is sent anywhere, so a placeholder webhook is inert no matter what it contains. Turning it on makes those URLs a live secret. |

### 3.1 Security

`configs/security_config.lua`.

| Key | Default | Notes |
|---|---|---|
| `Security.EventPrefix` | `"cis_libs"` | **Keep it.** Changing it moves every event name; any resource triggering them directly must change in the same edit, and the failure is silence, not an error. |
| `Security.AuthorizedResources` | `{}` | **Empty means nobody.** See §3.2. |
| `Security.DropPlayer` | a handler function | Cannot cross the exports boundary — see §3.3. |
| `Security.Debug` | `false` | Reserved, unread. Do not build on it. |

### 3.2 The empty allow-list

`Security.AuthorizedResources = {}` means **no resource but the platform itself**
may add a door, break a door, or write a sync record. Every attempt from
another resource is refused, and the refusal is announced in the console with
the fix.

That is the intended default and it is not a bug. A new server has no authorised
callers yet, and the honest answer to "who may mutate doors?" is nobody.
Defaulting to allow-all helps nobody during setup and leaves the exposure in
place afterwards, which is the part that matters at 3am.

**What it costs you:** a housing, robbery or garage resource whose calls start
returning `false`. That is a five-line fix:

```lua
Security.AuthorizedResources = {
    'cis_storeRobberies',
    'cis_housing',
}
```

A resource can ask before it acts rather than guessing:

```lua
if exports['cis_libs']:InvokingAllowed() then ... end
```

**One exception, for existing installs.** If the library has already run on this
server — a config file it wrote, or a store that already has rows — the empty
list keeps the older permissive behaviour, so an upgrade does not break a
working server overnight. `cis_debug` prints which way you fell, on every boot.

### 3.3 The drop handler cannot travel in the config

A **function cannot be sent** across the exports boundary; it arrives as `nil`.
So `Security.DropPlayer` is a boolean in the table that crosses, and the
function that implements it is registered as a *capability*:

```lua
-- server/initialize.lua, at boot
exports['cis_libs']:SetDropPlayerHandler('cis_core:CisCoreDropPlayer')
```

The result is exactly one line in the whole platform that can drop a player for
a security report, and it is auditable.

**Keep the message generic.** The shipped default tells the player to contact
the server owner and names no check. Naming the check that fired tells a person
exactly which guard to look for, and guards are the first thing somebody wants
to find.

### 3.4 What a client is told

A hand-built whitelist, not a copy with secrets removed. A key added to this
file does not reach a client until someone adds it to the whitelist. No
webhook, no database block, no allow-list, no kick handler.

`cis_debug` asserts this every boot and prints the answer. Expected output is
`false`; `true` means the whitelist drifted and something server-side is going
to every connected player.

---

## §4 — The inventory service

Registered into `cis_libs` as the `inventory` capability, on both realms.

This is the **service**, not a third-party adapter: the `name -> amount`
normalisation every consumer depends on, with the framework as its fallback.
The adapters behind it live in `cis_bridge` and register as `inventoryProvider`,
so the service and the adapter can each be replaced alone.

| Method | Signature | Returns |
|---|---|---|
| `Count` | `(src, item)` / `(item)` | `number`. **0, never nil** — a count is always a number. |
| `Add` | `(src, item, amount, metadata)` | `boolean` |
| `Remove` | `(src, item, amount)` | `boolean` |
| `Has` | `(src, item, amount)` / `(item, amount)` | `boolean` |
| `Snapshot` | `(src)` | `{ [itemName] = count }` — server only |

`Cis.inventory.count` is the one name that exists on **both** realms with a
different signature. A consumer sharing a helper between realms has to branch on
`IsDuplicityVersion()` rather than on the function.

**A client count is a hint and always was.** It is a snapshot the server pushed,
up to one inventory event stale. Never gate a server-side action on it: the
server re-checks, and a player holding a gun at the moment of the check is
holding it regardless of what their client last reported.

The provider is consulted first and the framework is the fallback. A missing
provider is therefore a *degraded* inventory, not a broken one — and the symptom
is "HasItem always says no", never a crash.

---

## §5 — Migrations

`cis_core` owns `cis_migrations`, the ledger. It is **the only table this
resource owns**, and that is a constraint rather than an accident: a product
brings its own schema and registers its migrations here, so the platform never
grows a table that belongs to one product and gets dropped when that product is
uninstalled.

### 5.1 Why the schema lives here and the driver does not

A driver is an adapter you can swap — oxmysql for mysql-connector and the data
is untouched. A schema is the one thing that has to survive the swap. Those two
facts belong in different places, and this is the second one. The drivers are in
`cis_bridge`; the tables are here.

### 5.2 Using it

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

Returns `ok, result` where `result` is `{ applied = n, skipped = n, failed = id }`.
**It returns rather than raises, always.** A product whose schema fails is a
product that cannot work, and it needs to say so and carry on booting; a raised
error would take the resource down and leave the operator with a stack trace
instead of a sentence.

### 5.3 Ordering

Numbered ids sort **numerically**, so `9_thing` runs before `10_thing` — which a
plain string sort gets backwards. Unnumbered ids run last, alphabetically. The
order is stable regardless of the order you wrote the list in, which is the
property that matters: the same list written differently must not apply
differently.

### 5.4 What is refused before anything executes

| Refusal | Why |
|---|---|
| No `id` | It can never be recorded as applied, so it re-runs on **every boot**. |
| Duplicate `id` | The second one would silently never run. |
| No `statements` | It does nothing and reports success. |
| An empty statement | Same, for one step of a multi-step migration. |

All four look fine from the console and are discovered weeks later, which is
why they are caught here.

### 5.5 The table

```sql
CREATE TABLE IF NOT EXISTS cis_migrations (
    id          VARCHAR(128) NOT NULL PRIMARY KEY,
    applied_at  BIGINT NOT NULL,
    duration_ms INT NOT NULL DEFAULT 0
)
```

`duration_ms` is there so a slow migration is visible before it becomes a slow
boot.

### 5.6 If a migration half-applies

It is not recorded, so the next boot retries it from the start. A DDL statement
that returns `nil` is treated as **not applied** and the migration fails — the
alternative is recording it as applied and leaving a server permanently missing
a column.

---

## §6 — Events

`cis_core` publishes **no** net events. It listens for:

| Event | From | Drives |
|---|---|---|
| `esx:playerLoaded` | ESX | `PublishPlayerLoaded`, `PublishInventory` |
| `esx:setJob` | ESX | `PublishJobUpdate` |
| `QBCore:Server:PlayerLoaded` | QBCore / qbx_core | `PublishPlayerLoaded`, `PublishInventory` |
| `QBCore:Server:OnJobUpdate` | QBCore | `PublishJobUpdate` |
| `QBCore:Client:OnPlayerLoaded` | QBCore | client job cache |
| `QBCore:Client:OnJobUpdate` | QBCore | client job cache |
| `QBCore:Player:SetPlayerData` | QBCore | client inventory counts |
| `qbx_core:client:playerLoaded` | qbx_core | client job cache |
| `qbx_core:client:onJobUpdate` | qbx_core | client job cache |
| `cis_libs:jobUpdated` | `cis_libs` | client job cache |
| `cis_libs:playerLoaded` | `cis_libs` | client job cache |
| `cis_libs:client:inventory` | `cis_libs` | client inventory counts |

The third-party names are declared **here** because this is the resource that
knows which framework is installed, so this is where an operator looks to see
every external event the platform depends on. The `cis_libs:*` names are
declared in `cis_libs`'s contract, because a name is part of the published
contract and a name that moves between resources is one a product can rename
without anyone noticing until a consumer stops hearing about it. They appear
here as *dependencies*.

**Nothing is triggered here.** A product asking for a notification or an
inventory push goes through an export, so the wire stays in the one place that
owns it.

### 6.1 The re-publish pattern

`cis_libs:jobUpdated` used to be a **local** client event derived from the
client's own framework event. It is now broadcast by the server.

That is the better shape and the reason is worth stating: one server-side
decision, one event, and a client whose framework events fire at a different
moment from everyone else's still ends up consistent — because it is listening
to the same wire rather than re-deriving the same conclusion.

---

## §7 — Diagnostics

```lua
exports['cis_core']:GetCoreSummary()
-- {
--   configApplied    = true,
--   framework        = 'QBOX',
--   inventory        = 'ox_inventory',
--   targetProvider   = 'cis_bridge',      -- who, not what
--   databaseProvider = 'cis_bridge',
--   migrations       = { '001_shops', '002_shops_x' },
-- }
```

`GetConfigSummary()` on `cis_libs` carries the framework, database and
inventory detail, the resolved provider for each, and a `missing` list of
capability slots nothing has registered.

Run `cis_debug` in the server console for the full picture. It prints derived
state only — no config values, no webhook URLs, no identifiers.

---

## §8 — Security notes

| Control | What it does |
|---|---|
| Config sanitising | Functions dropped at any depth; recursion capped at 12, because an unbounded recursive copy of a caller-supplied table is a denial-of-service surface |
| Drop handler | One capability, one line in the platform that can drop a player |
| Client redaction | Whitelist, asserted on every boot |
| Allow-list | Checked **before** the capability is consulted, so a provider added later inherits the check |
| Version check | Off by default, and pointing at a host the operator controls |
| Detection | Probes, never guesses; a `nil` framework is a stated mode, not a silent one |

**What is deliberately not defended against:** anything in your `server.cfg`
already has every permission you have. These controls are against accidents and
sloppy code, and they log loudly when they fire.

---

## §9 — Upgrading

1. Install `cis_core` and add `ensure cis_core` after `ensure cis_libs`.
2. Move your `Config` and `Security` tables from wherever they were into
   `configs/`. Any key you leave out falls back to the default.
3. `Doorlock.*` moved to `cis_keys` — see the `cis_keys` documentation.
4. If you had `Doorlock.Persist = true`, that key now belongs to `cis_keys`.
   An existing `cis_doors` table is adopted, not recreated.
5. `Config.Framework.Database.Type` is read by `cis_bridge`'s adapters, not
   here. Leaving it in your config is correct and harmless.

---

## §10 — Tests

```
npm install
npm test          # 27 assertions, no FiveM server required
npm run test:all  # + syntax check + the api contract self-test
```

`api.lua` at the resource root is the machine-readable contract. It is plain
data, not a script, and `tools/validate-api.js` fails if it ever drifts from
what the code actually registers.

The framework abstraction and the inventory service are adapters around natives
and third-party exports, and are deliberately **not** unit-tested against a
mock — testing the mock proves nothing about the framework. What is tested is
the pure half: migration ordering, validation, planning, and the config
accessor's behaviour when the library is absent.

---

## §11 — Layout

```
fxmanifest.lua        depends on cis_libs
api.lua               data. the contract. not loaded at runtime
configs/              the files an operator edits
shared/
  cis.lua             the seam: the client config accessor
  migrations.lua      the PURE half -- ordering, validation, planning
framework/
  framework_server.lua  detection, the normalized surface, the capability table
  framework_client.lua  the same surface, client side
server/
  inventory.lua       the inventory service and its capability table
  migrations.lua      the runner and cis_migrations
  initialize.lua      boot, config handover, capability registration
client/
  inventory.lua       the client count cache
test/  tools/
```

---

## §12 — Licence

MIT. See `LICENSE.md`. The attribution notice must be retained in every copy.

---

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> ·
**Discord:** <https://discord.gg/cisoko>
