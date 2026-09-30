# cis_core

**Platform services that hold data.** Free with purchase.

This is the half of the CIsoko platform allowed to own tables, and it owns
exactly one of its own: `cis_migrations`, the ledger. Everything else is a
product's schema, declared by that product and applied through this ledger.

| Resource | What it is | Price |
|---|---|---|
| `cis_libs` | The shared boundary. Owns no table, no config, no framework. | Free, always |
| **`cis_core`** | **This.** Framework abstraction, state, inventory service, config, migrations. | Free with purchase |
| `cis_bridge` | One adapter + one conformance test per third-party target. | Free with purchase |
| `cis_keys` | Doors, keys, PINs, guest passes, access ledger. | Paid, private |

## Install

```cfg
ensure cis_libs
ensure cis_core
```

`cis_core` declares a real dependency on `cis_libs`, so the start order in your
server.cfg does not matter for this resource.

## What it does

**Framework abstraction** over ESX, ESX-LEGACY, QBCore, qbx_core and
standalone, behind one normalized surface. `AUTO` asks the server what is
actually running rather than trusting the configured name — an operator who
configured QBCore on a qbx_core server used to get a bridge that reported itself
ready and then returned nil for every player, with nothing in the console saying
why. `reason` comes back with every detection result for exactly that reason.

The client and server halves now call the **same** detection function over the
same ordered table. They did not before, and the divergence was a live bug: on a
qbx_core that removed `GetCoreObject`, the client fell through to standalone
and `cis_libs:jobUpdated` never fired, while the server worked fine.

**Configuration.** `configs/master_config.lua` is the file you edit. Any key you
leave out falls back to the library default, so a partial config is safe and does
not blank out the sections around it. The copy handed to clients is a whitelist:
no webhook, no connection detail, no allow-list.

**Migrations.** Ordered, recorded, once-only, and idempotent by id.

```lua
exports['cis_core']:Migrate('my_resource', {
    { id = '001_shops',   statements = { 'CREATE TABLE shops (id INT)' } },
    { id = '002_shops_x', statements = { { sql = 'ALTER TABLE shops ADD x INT', values = {} } } },
})
```

Numbered ids sort numerically, so `9_thing` runs before `10_thing` — which a
string sort gets backwards. Unnumbered ids run last, in alphabetical order. An
id that is missing, duplicated, or empty is refused before anything executes,
because a migration with no id can never be recorded as applied and re-runs on
every boot, while one with no statements silently does nothing and reports
success.

**Inventory service.** The `name -> amount` normalisation every consumer depends
on, with the framework as its fallback. The third-party adapters behind it live
in `cis_bridge` and register separately, so either can be replaced alone.

## Tests

```
npm install
npm test          # 27 assertions, no FiveM server required
npm run test:all
```

---

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> · **Discord:** <https://discord.gg/cisoko>
