# Migrating to `cis_core` 1.1.0

From 1.0.x. Two changes can affect behaviour; both are one line each.

---

## 1. Read this first

| Change | Affects you if |
|---|---|
| **The allow-list now ships the platform roster** | You had edited `Security.AuthorizedResources` to add your own resources. **Your list was replaced by the shipped one — put your own names back.** |
| **`Security.DropPlayer` now defaults to `false`** | You relied on a security violation kicking the player. |

Nothing else changes. No export was renamed, no signature moved, no return
shape changed, no event name changed. `api = 1` in `api.lua` is unchanged.

---

## 2. The allow-list

### What changed

`configs/security_config.lua` shipped `Security.AuthorizedResources = {}`.
An empty list means **nobody**, so on 1.0.x every CIsoko product was refused by
default. A working install of `cis_libs` + `cis_core` + `cis_keys` needed a
hand edit before it worked, and the need was invisible until something broke.

1.1.0 ships the publisher's own products on that list instead — and nothing
else.

### What you need to do

Open `configs/security_config.lua`. If you added your own resource names,
they are gone; put them back:

```lua
Security.AuthorizedResources = {
    'cis_libs',
    'cis_core',
    'cis_bridge',
    -- ... the shipped list ...
    'my_resource',        -- <- yours, back where you left it
}
```

If you had **no** edits, do nothing. The shipped list already covers every
CIsoko product.

### What you might want to do anyway

Delete the entries you do not have. A grant is attached to a *name*, so an entry
for a resource that is not installed grants nothing today but becomes live the
day a different resource is installed under that exact name.

```
cis_core_doctor
```

prints every authorised entry that is **not installed**, so a stale one is
visible rather than latent.

**Empty still means nobody.** `Security.AuthorizedResources = {}` is unchanged
behaviour, for operators who want a fully manual install.

---

## 3. The drop handler

### What changed

`Security.DropPlayer` shipped as `true` — a player was kicked from a platform
they installed to get their framework bridged, on the strength of a heuristic
another resource raised, and the message told them a server owner had been
informed when nothing had been.

1.1.0 defaults to `false`. Log only. This matches `cis_libs`' published default,
and a library does not remove players from a server as a side effect of
reporting something suspicious.

### What you need to do

If you want the kick back, uncomment one line at the bottom of
`configs/security_config.lua`:

```lua
Security.DropPlayer = cisAnticheatDropPlayer
```

The handler function is already defined and already registered with `cis_libs`
as the `security` capability, so this line is the whole of it.

**Keep the message generic if you customise it.** Naming the check that fired
tells a person exactly which guard to look for, and guards are the first thing
somebody wants to find.

---

## 4. The new table

`cis_state` is created by `cis_core`'s own migration, through the ledger, at
boot. Nothing about your existing schema changes.

If you run a read-only database user for your server, grant it:

```sql
CREATE TABLE IF NOT EXISTS cis_state (
    owner      VARCHAR(64) NOT NULL,
    k          VARCHAR(64) NOT NULL,
    v          LONGTEXT    NULL,
    updated_at BIGINT      NOT NULL DEFAULT 0,
    PRIMARY KEY (owner, k)
);
```

Without it, every state export answers `false, reason` and says why at boot. The
store is inert, not broken — nothing else in the platform depends on it.

---

## 5. Smaller things you may notice

- **`mysql-async` is rejected** as a database driver name and now fails
  validation with a fix. No adapter ever supported it; naming it produced a
  server that registered an adapter and then raised on its first query. If that
  is what you had configured, switch to `"oxmysql"`, `"mysql-connector"`,
  `"ghmattimysql"` or `"mongodb"` — or `"AUTO"`.
- **Two new console commands:** `cis_core_info` (one line) and `cis_core_doctor`
  (the full report). Both are console-only or admin. Both print no secrets, so
  `cis_core_doctor` is safe to paste into a support thread whole.
- **A boot block appears** that validates your config. See below.
- **New exports:** `StateSet`, `StateGet`, `StateAll`, `StateKeys`,
  `StateDelete`, `StateClear`, `GetStateSummary`, `GetDoctorReport`. Nothing
  existing changed.

---

## 6. The boot block

If your config is correct you will see one line:

```
cis_core: configuration OK (1 note)
```

If it is not, you will see each problem with its fix:

```
cis_core: configuration: 1 error, 2 warnings, 1 note
  ERROR Config.Framework.Inventory is "ox_inventoryr", which is not a value this resource accepts
    fix: use "ox_inventory" instead -- nothing in this resource reads "ox_inventoryr", so the configured value is ignored and the documented fallback runs
  WARNING Config.Framework.Typ is not a key this resource reads, so it is ignored
    fix: this key lives at Config.Framework.Type -- did you mean that?
  cis_core: carrying on anyway. Every setting above falls back to its documented default.
```

**It never blocks the boot.** A broken setting falls back to its documented
default and says so. A platform service that refuses to serve because one
optional piece is missing turns a config typo into an outage, and the operator
learns the cause from the outage instead of from the sentence that would have
told them.

Notes are counted but not printed at boot — they are correct-as-shipped, and a
block that always has three lines in it is a block people learn to skim.
`cis_core_doctor` prints them.

---

## 7. Verifying

```
cis_core_info
cis_core_doctor
```

`cis_core_info` should report your framework, your inventory, and a migration
count of at least 1 (`cis_core`'s own `001_cis_state`).

`cis_core_doctor` should report no `MISSING` and no `ERROR`. Anything else names
its own fix.

Then, if you use it:

```lua
exports['cis_core']:StateSet('smoke_test', { ok = true })
print(exports['cis_core']:StateGet('smoke_test', nil))
exports['cis_core']:StateDelete('smoke_test')
```

---

## 8. From before 1.0.0

1. Install `cis_core` and add `ensure cis_core` after `ensure cis_libs`.
2. Move your `Config` and `Security` tables from wherever they were into
   `configs/`. Any key you leave out falls back to the default.
3. `Doorlock.*` moved to `cis_keys`. If you had `Doorlock.Persist = true`, that
   key now belongs to `cis_keys`, and an existing `cis_doors` table is adopted
   rather than recreated.
4. `Config.Framework.Database.Type` is read by `cis_bridge`'s adapters, not
   here. Leaving it in your config is correct and harmless.