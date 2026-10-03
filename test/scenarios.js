'use strict'

// Runs each file in test/scenarios/ in its OWN Lua state.
//
// WHY A SEPARATE RUNNER AND A SEPARATE STATE
//
// The framework bridge decides everything in a file-local `detect()`, called
// once from a CreateThread. Testing it against four frameworks therefore means
// running `detect()` four times against four different worlds -- and in one
// shared state the first scenario's globals, its registered capability and its
// fake exports all survive into the next one. The result is a suite that passes
// in an order nobody would run it in and fails in a real one.
//
// A fresh state per scenario is the only arrangement where "qbx_core is running
// in this test and not in that one" is true rather than approximately true.
//
// Each scenario is responsible for its own verdict: it ends with Test.report()
// and Test.raiseIfFailed(), so the exit code is the LOAD status. Nothing here
// parses printed output, because a suite that greps its own console is a suite
// that can be satisfied by printing the right words.

const fs = require('fs')
const path = require('path')
const fengari = require('fengari')

const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLua = fengari.to_luastring

const root = path.join(__dirname, '..')
const dir = path.join(__dirname, 'scenarios')

// Loaded into EVERY state, before the scenario. The scenario decides what the
// world looks like; these decide what is available to look at it with.
const DEPS = [
  'shared/normalize.lua',
  // The migration runner is loaded by a scenario that needs it, but its PURE
  // half is shared and every scenario gets it: it defines CisMigrations, and a
  // scenario that does not have it fails inside server/migrations.lua with
  // "attempt to index a nil value (global 'CisMigrations')" -- which reads like
  // a bug in the runner and is a missing line in this list.
  'shared/migrations.lua',
  'server/authority.lua',
  // Same reasoning as shared/migrations.lua: the state store calls it on every
  // write, so a scenario that loads server/state.lua without it fails inside
  // the store with "attempt to index a nil value (global 'CisStateRules')".
  'server/state_rules.lua',
  // fengari has no `json`, and FiveM's is a global in both realms. This is a
  // real encoder and a real decoder for the subset the state rules permit --
  // see the file header for the two rapidjson behaviours it reproduces on
  // purpose, one of which is that NaN does NOT raise.
  'test/fake_json.lua',
  'test/harness.lua',
  'test/framework_env.lua',
]

const scenarios = fs
  .readdirSync(dir)
  .filter((f) => f.endsWith('.lua'))
  .sort()

if (scenarios.length === 0) {
  console.error('no scenarios found; the framework suite would be vacuous')
  process.exit(1)
}

let failedScenarios = 0

for (const name of scenarios) {
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)

  const load = (rel) => {
    const status = lauxlib.luaL_dostring(L, toLua(fs.readFileSync(path.join(root, rel), 'utf8')))
    if (status !== lua.LUA_OK) {
      throw new Error(lua.lua_tojsstring(L, -1))
    }
  }

  try {
    for (const dep of DEPS) load(dep)
    load(path.join('test', 'scenarios', name))
  } catch (err) {
    failedScenarios += 1
    // Best-effort report BEFORE the message. A scenario that dies on an
    // un-indexed nil never reaches its own Test.report(), so without this the
    // most informative part of the run -- the notes the scenario attached
    // about the world it was looking at -- is exactly what gets lost.
    try {
      lauxlib.luaL_dostring(L, toLua('Test.report()'))
    } catch (e) {
      /* the scenario died before Test.begin; there is nothing to report */
    }
    console.log(`  FAIL  scenarios/${name}: ${err.message}`)
    continue
  }
  console.log(`  PASS  scenarios/${name}`)
}

console.log(`scenarios=${scenarios.length} failed=${failedScenarios}`)
if (failedScenarios > 0) process.exit(1)