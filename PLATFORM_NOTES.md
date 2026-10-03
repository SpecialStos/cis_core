# Platform notes

**Where `cis_core` and `cis_libs` disagree, and which side is right.**

This resource is developed without write access to `cis_libs`. Every finding
below was checked against `cis_libs`'s source on disk, not against its
documentation, and the source is what is cited. Findings are marked:

| | Meaning |
|---|---|
| **cis_libs is wrong** | The fix belongs in `cis_libs`. Nothing can be done here. |
| **cis_core deviates, deliberately** | A contract rule that cannot be satisfied from another resource. The reasoning is below. |
| **Verified compatible** | Looks like a mismatch on paper. Checked, and it is not one. |

Review these before changing anything that touches the boundary. Half of them
are one-sided by construction, and a future agent who "fixes" cis_core to match
a stale sentence here will break the platform.

---

## 1. `mysql-async` is in `cis_libs`'s driver table, and no adapter exists for it

**cis_libs is wrong.**

`cis_libs/shared/detect.lua`:

```lua
CisDetect.DATABASES = {
    { name = 'oxmysql',       resource = 'oxmysql' },
    { name = 'mysql-async',   resource = 'mysql-async' },   -- <-- here
    { name = 'ghmattimysql',  resource = 'ghmattimysql' },
    { name = 'mongodb',       resource = 'mongodb' },
}
```

`cis_bridge/adapters/database/` contains exactly four adapters: `oxmysql`,
`mysql-connector`, `ghmattimysql`, `mongodb`. There is no `mysql-async`
adapter and there never has been.

So `DetectDatabase` will select a driver that nothing can serve, on a server
that happens to have a resource by that name — and `mysql-async` shares a name
with `mysql-connector` while sharing none of its exports.

**What `cis_core` does about it.** `configs/master_config.lua` does not list
`mysql-async`, and the boot validator refuses it as a value:

```
Config.Framework.Database.Type is "mysql-async", which is not a value this
resource accepts
  fix: use "AUTO" instead -- nothing in this resource reads "mysql-async", so the
  configured value is ignored and the documented fallback runs
```

**Impact is low today and not zero.** Nothing in the platform calls
`DetectDatabase` — it is exported but unused by `cis_core` and `cis_bridge`. So
the wrong entry is inert unless a consumer adopts it, which is exactly why it
should be corrected rather than relied upon.

---

## 2. `GetFramework()` is deprecated, and it is the only cross-boundary route

**cis_core deviates, deliberately.**

`cis_libs`'s own `api.lua`:

```lua
GetFramework = {
    since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
    use = 'Cis.framework.player(src) on the server; ... **Not an API**: it returns
          a table of callable references',
    realm = 'both',
    signature = '()',
},
```

`cis_core` calls `exports['cis_libs']:GetFramework()` five times.

**Why the deprecation cannot be honoured from another resource.** The suggested
replacement is `Cis.framework.player(src)`. `Cis` is a global in **cis_libs' own
Lua state**, and FiveM gives every resource its own. This is not a theory — it
is the exact defect that milestone 1.1.0's first commit fixed, when
`framework_server.lua` called the bare global `CisDetect` and raised on every
stock install because the global is always nil on this side of the boundary.

The registry does offer `CisRegistry.resolve(slot)`, but that is also cis_libs'
global. Across the boundary there are only exports.

**Checked for an alternative, and there is none.** cis_libs exports
`RegisterCapability`, `UnregisterCapability`, `WaitCapability`, `GetCapabilities`
(a snapshot of slot → owner, not methods), `DetectFramework` and
`GetFramework`. Only `GetFramework` returns the provider's method table.

**The mitigation, not the fix.** Five call sites is the entire exposure, they
are all in `server/`, and all five are wrapped so a nil or a raising table
produces a refusal rather than an error:

| Call site | What it does with the result |
|---|---|
| `server/commands.lua` `isAdmin` | refuses when the table or `HasPermission` is missing |
| `server/inventory.lua` `playerItems` | returns `{}` |
| `server/inventory.lua` `typicalPlayer` | returns nil |
| `server/inventory.lua` `InventoryCount` | falls through to the framework walk |

**When cis_libs 3.0.0 removes it**, the fix belongs here: those four sites
become one call to a new, non-deprecated export. Do not remove the calls before
that export exists.

---

## 3. The published contract describes a different API than the one on disk

**Neither is "wrong"; this is a warning about building from the document.**

`CIS_LIBS_API_CONTRACT.md` (labelled `cis_libs 2.2.0`, `api = 1`) describes a
`Cis.*` namespace reached as `Cis.framework.player(src)`, `Cis.db.query(...)`,
`Cis.registry.resolve(...)`, `Cis.require('lru')`, `Cis.ui.notify(...)`.

The `cis_libs` on disk exposes the **flat-export** API:
`exports['cis_libs']:DbQuery(...)`, `DetectFramework(...)`,
`RegisterCapability(...)`.

**A consumer written from the contract document will not run.** Every call in
it needs a change, and the failure at runtime is a nil index on `Cis`, which
points nowhere near the cause — the same failure mode as the `CisDetect` bug
above.

**What to build against:** the `exports['cis_libs']:` surface, which is what
every existing resource in this platform uses and what `cis_libs`'s own
`api.lua` describes as its exported surface. When the `Cis.*` namespace
actually ships, it will be an addition — the deprecation note in §2 is the
migration path, not a swap.

---

## 4. The capability method names match. Verified, and it looks like they do not.

**Verified compatible.** Recorded because it reads as a mismatch and someone
will eventually try to "fix" it.

`cis_libs/api.lua` says the framework surface is reached as
`Cis.framework.player(src)` — lowercase, and nothing in `cis_core` provides a
method called `player`.

The operative contract is `cis_libs`'s registry, `shared/registry.lua`:

```lua
CisRegistry.SLOTS = {
    framework = {
        get = 'CisCoreFramework() -> the normalized API table',
        NormalizedPlayer = ..., Notify = ..., ShowNotification = ...,
        IsLoaded = ..., HasPermission = ..., GetPlayerJob = ...,
    },
    inventory = {
        count = ..., add = ..., remove = ..., has = ...,
    },
```

The framework slot is **capitalised by design**, and `cis_core`'s capability
tables match it exactly: `NormalizedPlayer`, `Notify`, `ShowNotification`,
`IsLoaded`, `HasPermission`, `GetPlayerJob`, and `get` resolved through
`CisCoreFramework`.

The inventory slot is lowercase and `cis_core` provides `Count`, `Add`,
`Remove`, `Has`, `Snapshot`. That resolves through `CisRegistry.lookup`, which
tries the declared name and then flips the first letter — `'count'` → `'Count'`.
It works, but it works through a **fallback**, not through an exact match. If
that lookup order ever changes, the inventory capability breaks silently.

**Worth doing on the cis_libs side:** declare the inventory slot capitalised, or
provide both spellings. Not urgent — it is covered by the current lookup.

---

## 5. Verified: the exports `cis_core` calls all match their real signatures

Checked one by one against the implementations in `cis_libs/server/` and
`client/`. No mismatches.

| Called | Declared | |
|---|---|---|
| `DetectFramework(configured, custom)` | `function(configured, custom)` | ✓ |
| `SetConfig(config, security, discord)` | `function(config, security, discord)` | ✓ |
| `RegisterCapability(slot, provider)` | `function(slot, provider)` | ✓ |
| `RegisterCallback(name, fn)` | `function(name, handler)` | ✓ |
| `PublishJobUpdate(job, src)` | `function(job, src)` | ✓ |
| `PublishInventory(src)` | `function(src)` | ✓ |
| `InventoryAdd(src, item, amount, metadata)` | same | ✓ |
| `InventoryRemove(src, item, amount)` | same | ✓ |
| `InventoryHas(src, item, amount)` | same | ✓ |
| `WaitReady(timeout)` | `function(timeout)` | ✓ |
| `GetCapabilities()` | `function()` | ✓ |
| `GetSelfCheck()` | `function()` | ✓ |
| `NotifyClient(src, message, kind)` | same | ✓ |
| `SetDropPlayerHandler(provider)` | `function(provider)` | ✓ |
| `GetOnlineJobCount(jobs)` | `CisJobCount` | ✓ |

`RegisterCallback` accepts **any** non-empty name, including one in cis_libs's
own namespace, and records the owner from `GetInvokingResource()` — so a
callback registered here is released when this resource stops, and does not
squat the name against anyone else.

---

## 6. Registering in cis_libs's namespace is legal but not free

`cis_libs`'s `api.lua` §7 lists exactly two documented seams: the door state
request event, and `chat:addSuggestion`. Everything else under `cis_libs:*` is
internal.

`cis_core` registers **no** events and **triggers** none — verified by grep. It
LISTENS to `cis_libs:jobUpdated`, `cis_libs:playerLoaded` and
`cis_libs:client:inventory`, which is consuming, not publishing.

A dead `RegisterCallback('cis_libs:inventoryCount', ...)` did squat a name in
cis_libs's namespace; it was removed in 1.1.0. Nothing else crosses that way.

---

## 7. Verified runtime facts this resource now depends on

Checked against the CfxLua scheduler (`data/shared/citizen/scripting/lua/scheduler.lua`).

| Fact | Consequence here |
|---|---|
| `exports[r][n]` returns a **function** (a closure), always | The `__cfx_functionReference` fallback in the deleted `probeExport` was dead code — `rawget` on a function is always nil |
| `exports[r][n]` **resolves** the export by firing an event; it does not call it | A `pcall` around it is a valid existence probe |
| A missing resource and a missing export produce the **same** error | A probe cannot tell them apart |
| `exports[r][n](a, b)` swallows `a` as `self` | Always use the colon form. CI greps for the bracket form |
| `source` is the **player id** for a net event, a number for internal-net, and an **empty string** for a server-side `TriggerEvent` | `CisAuthority.isPlayer` rejects non-numbers, so a server trigger lands on the server-side branch |
| `source` is restored after a handler yields | Read it into a local on the first line of a handler |
| `safeForNet` is keyed by event NAME, per Lua state | `RegisterNetEvent` is what makes a handler net-reachable. Never rely on `AddEventHandler` alone |
| `json.encode` does **not** raise on NaN or Infinity — it emits invalid JSON | `CisStateRules` rejects both before encoding. Load-bearing |
| `json.decode` **raises** on malformed input; it never returns `nil, err` | Every decode is wrapped |
| `GetPlayerName(src)` returns `nil` for a disconnected player on the server | This is the gate in `CisAuthority.isPlayer` |
| `GetMaxPlayers` could **not** be verified to exist on every build | Probed, never required |
| `GetResourceState` can return `uninitialized` | Every check is `== 'started'`, never `~= 'missing'` |

---

## 8. What `cis_core` assumes about `cis_libs`, and would break if it changed

1. **`DetectFramework` returns `{ name, resource, version, how, reason }`** and
   its `name` is one of `QBCORE`, `QBOX`, `ESX`, `NONE`, or the custom adapter's
   uppercased name. `detect()` branches on exactly those.
2. **The framework table is ordered most-specific-first** (`qbx_core` before
   `qb-core`). qbx_core declares `provide 'qb-core'`, so a qbx_core server can
   report both as started; the ordering is what keeps that unambiguous.
3. **No `Cis.*` globals cross the boundary.** Every call is `exports['cis_libs']`.
4. **`PublishJobUpdate` returns `false` for a non-table job**, so cis_core
   guards the call rather than forwarding nil.
5. **`CisJobCount` is in-memory.** The job histogram is lost on a cis_libs
   restart; `cis_core` does not persist it and does not try to.

---

**Reviewed:** 2026-10-03, against `cis_libs` branch `cis_libs-2.2`.
Re-check when cis_libs moves to 3.0.0, and before the first `Cis.*` release.