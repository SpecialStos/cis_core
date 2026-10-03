'use strict'

// Runs every pure-Lua suite under fengari. No FiveM server, no game assets.
//
// WHY THE SUITES ARE AGGREGATED HERE AND NOT IN THE SUITES
//
// Each suite used to print its own result and call os.exit(1) on failure.
// os.exit takes the whole Lua state with it, so the FIRST failing suite ended
// the run and every suite after it never executed -- and a run that stopped
// early still printed the results of the suites that had already passed, which
// reads exactly like a green run. Nothing in the output said "the rest did not
// run".
//
// So the suites report into the shared harness and this file decides the exit
// code, once, after everything has loaded.

const fs = require('fs')
const path = require('path')
const fengari = require('fengari')

const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLua = fengari.to_luastring

const root = path.join(__dirname, '..')
const L = lauxlib.luaL_newstate()
lualib.luaL_openlibs(L)

function runFile(rel) {
  const src = fs.readFileSync(path.join(root, rel), 'utf8')
  const status = lauxlib.luaL_dostring(L, toLua(src))
  if (status !== lua.LUA_OK) {
    const err = lua.lua_tojsstring(L, -1)
    throw new Error(`${rel}: ${err}`)
  }
}

// The files under test, in manifest order. The manifest is the contract and a
// test that loads them in a different order is testing a resource that does
// not exist.
//
// `server/validate_config.lua` is here because it is pure: it defines a table
// and reads no globals, no natives and no exports. That is a design constraint
// it keeps on purpose -- it is what lets the one file an operator can break
// be the one file that is fully testable on every push.
const SOURCES = [
  'shared/cis.lua',
  'shared/migrations.lua',
  'shared/normalize.lua',
  'server/validate_config.lua',
  'server/state_rules.lua',
]

// Every `test/*.lua` file is a suite, and none of them is listed by name. A
// suite added later and not added here is a suite that silently never runs,
// which is the same invisible failure the early-exit above had, one level down.
const SUITES = fs
  .readdirSync(__dirname)
  .filter((f) => f.endsWith('.lua') && f !== 'harness.lua')
  .sort()

for (const rel of SOURCES) {
  runFile(rel)
}
runFile('test/harness.lua')

for (const suite of SUITES) {
  runFile(path.join('test', suite))
}

// The totals are computed IN LUA and turned into a deliberate error, rather
// than read back out through the C API. Fengari's lauxlib does not export a
// `lua_getglobal`, and hand-rolling the registry walk to reach one global is a
// lot of surface for one integer. A raised error is already the one signal
// this file knows how to read, and its message carries the counts.
const FINALISE = `
local passed, failed, suites = Test.totals()
io.write(('suites=%d passed=%d failed=%d\\n'):format(suites, passed, failed))
if failed > 0 then
  error(('%d of %d assertions failed'):format(failed, passed + failed), 0)
end
`
const status = lauxlib.luaL_dostring(L, toLua(FINALISE))
if (status !== lua.LUA_OK) {
  const err = lua.lua_tojsstring(L, -1)
  process.stderr.write(`${err}\n`)
  process.exit(1)
}