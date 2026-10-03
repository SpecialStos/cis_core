# cis_core

**Platform services that hold data.** Free with purchase.

This is the half of the CIsoko platform allowed to own tables, and it owns
exactly two of its own: `cis_migrations`, the ledger, and `cis_state`, the state
store. Everything else is a product's schema, declared by that product and
applied through the ledger.

| Resource | What it is | Price |
|---|---|---|
| `cis_libs` | The shared boundary. Owns no table, no config, no framework. | Free, always |
| **`cis_core`** | **This.** Framework abstraction, state, config, migrations. | Free with purchase |
| `cis_bridge` | One adapter + one conformance test per third-party target. | Free with purchase |
| `cis_keys` | Doors, keys, PINs, guest passes, access ledger. | Paid, private |

## Install

```cfg
ensure cis_libs
ensure cis_core
```

`cis_core` declares a real dependency on `cis_libs`, so the start order in your
server.cfg does not matter for this resource. Then, in the server console:

```
cis_core_info
```

One line. It is the fastest way to know the resource is working, and it is safe
to paste into a support thread.

## What it does

**Framework abstraction** over ESX, ESX-LEGACY, QBCore, qbx_core and
standalone, behind one normalized surface, registered on **both** realms.
`AUTO` asks the server what is actually running rather than trusting the
configured name — an operator who configured QBCore on a qbx_core server used to
get a bridge that reported itself ready and then returned nil for every player,
with nothing in the console saying why. `reason` comes back with every detection
result for exactly that reason.

The client and server halves call the **same** detection function over the same
ordered table. They did not before, and the divergence was a live bug: on a
qbx_core that removed `GetCoreObject`, the client fell through to standalone and
`cis_libs:jobUpdated` never fired, while the server worked fine.

**Configuration, validated at boot.** A config file is the one piece of this
platform an operator writes by hand, and a typo in it has no symptom. Every
setting is checked for type, range and known value, and every problem is
printed with its fix:

```
cis_core: configuration: 1 error, 1 warning, 1 note
  ERROR Config.Framework.Inventory is "ox_inventoryr", which is not a value this resource accepts
    fix: use "ox_inventory" instead -- nothing in this resource reads "ox_inventoryr", so the configured value is ignored and the documented fallback runs
  WARNING Config.Framework.Typ is not a key this resource reads, so it is ignored
    fix: this key lives at Config.Framework.Type -- did you mean that?
  cis_core: carrying on anyway. Every setting above falls back to its documented default.
```

Unknown keys are reported too, because a key nothing reads is invisible
otherwise. `cis_core_doctor` prints the same report on demand, plus which
capabilities are held, which authorised resources are actually running, and
whether the state store is available.

**State.** One namespaced, durable key/value store, so a product that only needs
a setting does not have to invent a table:

```lua
exports['cis_core']:StateSet('last_treatment', { at = 1712345678, by = 'medic_station' })
local record = exports['cis_core']:StateGet('last_treatment', nil)
```

There is no `owner` argument anywhere in that API — the namespace *is*
`GetInvokingResource()`. A namespaced store where the namespace is a parameter
is a store any resource can read and write for any other.

**Migrations.** Ordered, recorded, once-only, and idempotent by id.

```lua
exports['cis_core']:Migrate('my_resource', {
    { id = '001_shops',   statements = { 'CREATE TABLE shops (id INT)' } },
    { id = '002_shops_x', statements = { { sql = 'ALTER TABLE shops ADD x INT', values = {} } } },
})
```

Numbered ids sort numerically, so `9_thing` runs before `10_thing` — which a
string sort gets backwards. An id that is missing, duplicated, or empty is
refused before anything executes, because a migration with no id can never be
recorded as applied and re-runs on every boot, while one with no statements
silently does nothing and reports success.

**Inventory service.** The `name -> amount` normalisation every consumer depends
on, with the framework as its fallback. The third-party adapters behind it live
in `cis_bridge` and register separately, so either can be replaced alone.

## Tests

```
npm install
npm test          # 277 assertions in the pure suites, plus 12 framework scenarios
npm run test:all  # + syntax, contract validation, docs staleness
```

Two halves, and the split matters. The pure suites cover the logic;
`test/scenarios/` runs each framework world in **its own Lua state**, because a
suite that shares a state passes in an order nobody would run it in. The ESX
self-argument bug, the QBCore `GetPlayers` shape and the inventory zero bug were
all found by the scenarios and by none of the other suites.

Both counts move. `npm test` prints the current totals, and `npm run test:docs`
fails the build if the number quoted here has drifted from what the suite runs.

`api.lua` is the machine-readable contract — every export, net event and console
command — and `npm run test:api` fails if it ever drifts from what the code
actually registers.

---

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> · **Discord:** <https://discord.gg/cisoko>

## Documents

| | |
|---|---|
| [`CALLBACKS.md`](CALLBACKS.md) | **Generated** from `api.lua`; every export, event and command. CI fails if it is stale |
| [`DOCUMENTATION.md`](DOCUMENTATION.md) | Every capability, config key and contract |
| [`sql/cis_core.sql`](sql/cis_core.sql) | The two tables, for provisioning by hand |
| [`MIGRATION.md`](MIGRATION.md) | Upgrading from 1.0.x, and what it costs you |
| [`CHANGELOG.md`](CHANGELOG.md) | Keep a Changelog format, with the reasoning |
| [`SECURITY.md`](SECURITY.md) | Trust model, what is enforced, how to report |
| [`PLATFORM_NOTES.md`](PLATFORM_NOTES.md) | Where `cis_core` and `cis_libs` disagree, and which side is right |
| [`LICENSE.md`](LICENSE.md) | MIT. The attribution notice must be retained in every copy |
