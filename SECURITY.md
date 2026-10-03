# Security

**Scope.** `cis_core` 1.1.0, and the assumptions it makes about everything
around it.

---

## 1. The trust model

There are three boundaries in this resource, and they are not equally
trustworthy. Knowing which is which is the whole of a useful security posture
here.

### 1.1 The client — not trusted, and not worth defending against directly

A player controls their client entirely. Anything a client sends is a request,
never an instruction, and anything a client reads can be read by the player's
own machine.

There is no client-side export in this resource that mutates anything. `StateSet`,
`StateDelete` and `StateClear` are server exports with no client counterpart,
and that is not an oversight: a client export over a shared namespace is a
broadcast of whatever a product decided to keep, and the decision about what a
player may be told belongs to the product, not to the store.

**A cheat executor can already do everything a locked-down client export could
prevent.** It runs inside the client, can call `TriggerClientEvent` with any
payload this resource sends, and can draw whatever it likes over the top.
Refusing one export to code that can skip the entire platform is a lock on a
door that is not there. The work worth doing on the client side is not
tamper-resistance; it is not *trusting* the client, and that is done on the
server.

### 1.2 Other resources — trusted to a named, explicit list

`Security.AuthorizedResources` decides which resources may call the **mutating**
half of `cis_libs`: add a door, break a door, write a sync record, supply a
capability.

- The list is checked **before** the capability is consulted, so a provider
  added later inherits the check rather than bypassing it.
- There is no wildcard, no prefix match, and no "starts with `cis_`". The list
  ships with the publisher's own products and nothing else, so a third-party
  resource cannot inherit a grant by being named similarly.
- **An entry buys exactly one thing**: the right to call mutating exports. Not
  money, not inventory, not database access, and nothing in the client payload.
  A player can never read this list.
- **Empty means nobody.** That is the documented behaviour, not a failure state.

**The residual risk, stated plainly.** A grant is attached to a *name*. An entry
for a resource that is not installed grants nothing today, but it becomes live
the day a different resource is installed under that exact name — which is not
hypothetical on a server where resources get renamed while moving between
frameworks. `cis_core_doctor` prints every authorised entry that is not
installed, so a stale entry is visible rather than latent. **Delete the entries
you do not have.**

### 1.3 The operator's own configuration — the weakest link, by design

`configs/` is operator-authored and it is load-bearing. There is no signature,
no schema file the operator cannot edit, and no way to tell a hand-edited config
from a shipped one at runtime.

So `cis_core` does not try to make the configuration safe. It makes the
configuration **legible**: every value is validated at boot, every wrong value is
named, and every problem carries the fix. The threat is not a hostile operator —
it is a tired one at 3am, and the defence is a sentence rather than a traceback.

---

## 2. What this resource enforces

| Control | Where | What it does |
|---|---|---|
| Server-authoritative state | `server/state.lua` | The state store is server-side only, with no client export |
| Namespaced by derivation | `server/state.lua` | The namespace **is** `GetInvokingResource()`. There is no `owner` parameter anywhere in the public API, so there is no code path in which one product names another |
| Value rules before write | `server/state_rules.lua` | Keys restricted to a closed character set and length; values walked for JSON-encodability, cycles, depth, width and encoded size before anything is written |
| No unbounded writes | `server/state_rules.lua` | 64-character keys, 16 KB encoded values, depth 8, 256 entries per table |
| Config validation | `server/validate_config.lua` | Type, range and known-value checks; unknown keys reported; every problem carries its fix |
| Never raises | `server/validate_config.lua` | The validator's body is wrapped and a raise inside it is reported as a bug rather than propagated — a validator that crashes on the malformed config it exists to explain is the one failure this feature has to avoid |
| Never blocks a boot | `server/initialize.lua` | A broken setting falls back to its documented default and says so |
| Drop handler | `server/initialize.lua` | One capability, one line in the whole platform that can drop a player for a security report. **Off by default** |
| Client redaction | handed to `cis_libs` | A hand-built whitelist, not a copy with secrets removed. A key added to the config does not reach a client until someone adds it to the whitelist |
| Secret-free diagnostics | `server/doctor.lua`, `server/commands.lua` | Resource names, booleans, counts and reasons only. No webhook, no connection string, no identifier, no config value — enforced by there being no code path in the report builder that can put one in |
| Command authorisation | `server/commands.lua` | `cis_core_info` and `cis_core_doctor` are console-only or admin. A refusal is **silence**, not a message that tells a stranger what this server runs |
| Encoded SQL | `server/migrations.lua` | Values always go through placeholders. The only interpolated SQL is the table name, which is a constant in this file |
| Contract drift | `tools/validate-api.js` | An export, net event or console command in the source and not in `api.lua` fails the build — an undeclared command is a capability with no documented permission model |

---

## 3. What this resource does not defend against

- **Anything in your `server.cfg`.** It already has every permission you have.
  These controls are against accidents and sloppy code, and they log loudly when
  they fire.
- **A hostile operator.** Someone who can edit `server.cfg` can edit
  `configs/` too.
- **Supply-chain compromise of a third-party resource.** `cis_libs` is checked for
  a hardcoded third-party version host in CI and `CheckVersion` is `false` by
  default; that is the same posture taken here and it is worth re-taking whenever
  a new dependency is added.
- **Exploits of the database server itself.** If someone has your MySQL
  credentials they do not need this resource.
- **Players reading their own client.** Covered in §1.1: it is not worth
  defending against, and pretending otherwise produces security theatre.

---

## 4. Reporting a vulnerability

**Do not open a public issue.** Use the private channel linked on the product
page, or contact the publisher directly.

Please include:

- the version, from `cis_core_info` or `GetResourceMetadata`;
- the framework, inventory and database resources in use, from
  `cis_core_doctor` — it prints no secrets, so pasting it whole is safe;
- the reproduction: what you did, what you expected, what happened.

**What is in scope:** anything in this resource that lets a client or an
unauthorised resource affect server state, read a secret, or bypass a check it
was supposed to pass.

**What is out of scope:** findings that require an attacker who already has
console access or `server.cfg` write access, and the client-side limitations in
§1.1.

**Response:** acknowledged within 72 hours, with a decision either way. Confirmed
issues get a fix, a credit if you want one, and an entry in `CHANGELOG.md` that
names what was wrong — the same discipline the rest of this platform runs on.

---

**Author:** Cisoko · **Discord:** <https://discord.gg/cisoko>