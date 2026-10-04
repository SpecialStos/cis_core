'use strict'

// Checks the DOCUMENTATION against the contract and the tree.
//
// WHY THIS IS A TOOL AND NOT A REVIEW
//
// The roadmap's third permanent commitment is "one contract, several consumers.
// Docs, types, changelogs, the storefront and the support bot are all generated
// from the same source." CALLBACKS.md is now generated from api.lua. This is the
// other half: the PROSE documents, which cannot be generated because prose is
// the point of them, but which drift silently anyway.
//
// It drifted. During one session `CisCoreInventory` and `CisCoreInventoryClient`
// were never named in DOCUMENTATION.md at all -- the inventory capability was
// described in prose and a consumer reading the docs had no way to find the
// export to call. The layout section listed nine of the eleven files. The README
// quoted an assertion count that was two hundred behind. None of that is
// visible by reading, and all of it is the failure the commitment names.
//
// So: every export, every command, every event and every shipped file has to
// appear in the documentation, and the numbers in the prose have to match
// reality. Findings FAIL the build, for the same reason a broken fixture fails:
// a check that reports drift nobody acts on is a check that has stopped
// working.
//
// Usage:  node tools/doc-check.js

const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..')

const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8')

const DOCS = ['README.md', 'DOCUMENTATION.md', 'MIGRATION.md', 'SECURITY.md', 'PLATFORM_NOTES.md', 'CHANGELOG.md']
const docs = {}
for (const d of DOCS) {
  if (!fs.existsSync(path.join(root, d))) {
    console.error(`doc-check: ${d} does not exist`)
    process.exit(1)
  }
  docs[d] = read(d)
}
const all = DOCS.map((d) => docs[d]).join('\n')

// The document the checks score against. It is a FIELD rather than a module
// constant so the self-test can swap in a broken fixture and put the real one
// back -- which means a fixture exercises the same code path the build does,
// rather than a parallel one that can drift from it.
docs.DOCUMENTATION_ORIGINAL = docs['DOCUMENTATION.md']

// Every finding carries a CODE as well as a place and a fix, because the
// self-test has to assert that a SPECIFIC defect was detected rather than that
// "something" was -- and a finding with no code cannot be asserted against.
// Built rather than written: a newline inside a quoted string is exactly what
// gets collapsed by whatever quotes the patch that introduced it.
const NL = String.fromCharCode(10)

const CODE = {
  UNMENTIONED: 'DOC_unmentioned',
  LAYOUT: 'DOC_layout',
  STALE_COUNT: 'DOC_stale_count',
  DEAD_LINK: 'DOC_dead_link',
  VERSION: 'DOC_version',
  STALE_CLAIM: 'DOC_stale_claim',
}


const findings = []
const finding = (code, where, what, fix) => findings.push({ code, where, what, fix })

// ---------------------------------------------------------------------------
// api.lua, read structurally rather than by regex. It is Lua data, and fengari
// already knows how to load it -- the same path tools/gen-docs.js takes.
// ---------------------------------------------------------------------------
const fengari = require('fengari')
const { lua, lauxlib, lualib } = fengari
const toLua = fengari.to_luastring

const L = lauxlib.luaL_newstate()
lualib.luaL_openlibs(L)
{
  const status = lauxlib.luaL_loadbuffer(L, toLua(read('api.lua')), null, toLua('api.lua'))
  if (status !== lua.LUA_OK) {
    console.error(`doc-check: api.lua did not load: ${lua.lua_tojsstring(L, -1)}`)
    process.exit(1)
  }
  lua.lua_call(L, 0, 1)
}

function readValue(index) {
  const type = lua.lua_type(L, index)
  if (type === lua.LUA_TNIL || type === lua.LUA_TNONE) return null
  if (type === lua.LUA_TBOOLEAN) return lua.lua_toboolean(L, index) === true
  if (type === lua.LUA_TNUMBER) return lua.lua_tonumber(L, index)
  if (type === lua.LUA_TSTRING) return lua.lua_tojsstring(L, index)
  if (type !== lua.LUA_TTABLE) return null
  const out = {}
  const abs = lua.lua_absindex(L, index)
  lua.lua_pushnil(L)
  while (lua.lua_next(L, abs) !== 0) {
    const key = lua.lua_tojsstring(L, -2)
    out[key] = readValue(-1)
    lua.lua_settop(L, -2)
  }
  return out
}

const api = readValue(-1)
if (!api || !api.exports) {
  console.error('doc-check: api.lua has no exports table')
  process.exit(1)
}

// Word boundaries at BOTH ends -- except after a non-word character.
//
// `\bconfigs/` never matches, because `/` is not a word character and so there
// is no boundary between it and the space that follows. The layout section says
// `configs/              the files an operator edits`, so every file under it was
// reported as missing from a section that lists it.
const mentions = (haystack, name) => {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const start = /^\w/.test(name) ? '\\b' : ''
  const end = /\w$/.test(name) ? '\\b' : ''
  return new RegExp(`${start}${escaped}${end}`).test(haystack)
}

// Every shipped .lua file, minus the test and tooling trees -- the layout
// section maps the RESOURCE, and a reader looking for where a config key is
// read does not want a list of test runners.
function luaFiles(dir, acc = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['node_modules', '.git', 'test', 'tools'].includes(e.name)) continue
    const full = path.join(dir, e.name)
    if (e.isDirectory()) luaFiles(full, acc)
    else if (e.name.endsWith('.lua')) acc.push(full)
  }
  return acc
}

// AND ONLY LOCAL FILES get their references resolved. These documents cite
// cis_libs, qbx_core and the CfxLua scheduler by path, and those citations are
// the evidence for every claim they make -- checking them against cis_core's own
// tree reports a dozen "missing files" that are correctly cited paths in
// someone else's repository.
//
// So a reference is checked when it points HERE: a repo-relative directory that
// exists, or a file at the root. The alternative is a checker that cries wolf on
// exactly the references a technical reader most needs to be able to follow.
const LOCAL_PREFIXES = ['configs/', 'server/', 'shared/', 'client/', 'framework/', 'test/', 'tools/', 'sql/']

const looksLocal = (ref) => {
  if (!ref.includes('.') && !ref.includes('/')) return false
  if (LOCAL_PREFIXES.some((p) => ref.startsWith(p))) return true
  return !ref.includes('/') && fs.existsSync(path.join(root, ref))
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

// The self-test runs FIRST when asked, and it is the same reason the contract
// validator has one: a checker that has only ever been seen to pass has not been
// tested.
//
// Each fixture in test/docs/broken/ is broken on purpose and must still produce
// its own code. The NEGATIVE matters just as much -- a fixture whose defects are
// in someone ELSE's repository, or in a comment, must come back clean -- because
// without it all three could pass by reporting everything.
if (process.argv.includes('--selftest')) {
  const dir = path.join(root, 'test', 'docs', 'broken')
  if (!fs.existsSync(dir)) {
    console.error('doc-check self-test: no broken fixtures, so the run would be vacuous')
    process.exit(1)
  }
// Fixtures MUTATE THE REAL DOCUMENT rather than replacing it, because a
  // standalone fixture is a tiny document that omits everything and therefore
  // raises every code at once -- which proves the checker fires and proves
  // nothing about WHICH check fired.
  //
  // One defect per fixture, so "did it raise MY code" is a real question.
  const CASES = [
    {
      name: 'unmentioned.md',
      code: CODE.UNMENTIONED,
      // A whole paragraph, because the export name appears in more than one
      // place and removing one occurrence would not remove the export.
      mutation: { remove: /## §6 — Diagnostics[\s\S]*?(?=\n---)/ },
    },
    {
      name: 'stale-count.md',
      code: CODE.STALE_COUNT,
      mutation: { replace: [/277 assertions/, '41 assertions'] },
    },
    {
      name: 'dead-link.md',
      code: CODE.DEAD_LINK,
      mutation: { append: NL + NL + 'See [the install guide](sql/definitely-not-here.md) for setup.' + NL },
    },
    {
      name: 'no-layout.md',
      code: CODE.LAYOUT,
      mutation: { remove: /## §12 — Layout[\s\S]*?(?=\n---)/ },
    },
    {
      name: 'claims-untested.md',
      code: CODE.STALE_CLAIM,
      mutation: { append: NL + NL + 'The framework bridge is deliberately not unit-tested.' + NL },
    },
  ]

  console.log('doc-check self-test')
  let ok = true
  const real = docs.DOCUMENTATION_ORIGINAL

  for (const c of CASES) {
    let mutated = real
    const m = c.mutation
    if (m.replace) mutated = mutated.replace(m.replace[0], m.replace[1])
    if (m.remove) mutated = mutated.replace(m.remove, '')
    if (m.append) mutated = mutated + m.append
    if (mutated === real && m.remove) {
      // A removal that matched nothing is indistinguishable from a defect that
      // was never there, so it is refused rather than silently scoring zero.
      console.log(`  FAIL  broken/${c.name}: the removal matched nothing, so the fixture tests nothing`)
      ok = false
      continue
    }

    findings.length = 0
    docs.DOCUMENTATION_ORIGINAL = mutated
    runAll()
    const got = findings.map((f) => f.code)
    docs.DOCUMENTATION_ORIGINAL = real

    const stray = got.filter((x) => x !== c.code)
    if (!got.includes(c.code)) {
      console.log(`  FAIL  broken/${c.name} did not raise ${c.code}; got ${[...new Set(got)].join(', ') || 'nothing'}`)
      ok = false
      continue
    }
    if (stray.length > 0) {
      console.log(`  FAIL  broken/${c.name} raised ${c.code} but also ${[...new Set(stray)].join(', ')} -- one defect, one finding`)
      ok = false
      continue
    }
    console.log(`  PASS  broken/${c.name} raises exactly ${c.code}`)
  }

  // THE NEGATIVE, and it is the REAL document with citations added rather than
  // a small one of its own. The first version was a bare document containing
  // nothing but citations, and it "failed" -- by raising UNDOCUMENTED_EXPORT
  // for every export, because a document that mentions nothing documents
  // nothing. A negative fixture has to be a document that would otherwise be
  // CLEAN, or it proves nothing.
  findings.length = 0
  docs.DOCUMENTATION_ORIGINAL =
    real +
    '\n---\n\n## Citations, which are not local files\n\n' +
    '- `cis_libs/shared/registry.lua` -- the capability slot declaration\n' +
    '- `cis_libs/shared/detect.lua` -- the framework table\n' +
    '- `qbx_core/server/groups.lua` -- the job definition registry\n' +
    '- `data/shared/citizen/scripting/lua/scheduler.lua` -- the exports proxy\n\n' +
    'None of those is a file in THIS repository, and naming them is the point.\n'
  runAll()
  const negativeGot = findings.map((f) => f.code)
  docs.DOCUMENTATION_ORIGINAL = real
  findings.length = 0

  if (negativeGot.length > 0) {
    console.log(`  FAIL  a document of citations raised ${[...new Set(negativeGot)].join(', ')}`)
    ok = false
  } else {
    console.log('  PASS  citations to other repositories are not reported as missing files')
  }

  process.exit(ok ? 0 : 1)
}

// ---------------------------------------------------------------------------
//  The checks
// ---------------------------------------------------------------------------
//
// Every finding carries a CODE as well as a place and a fix, because the
// self-test has to assert that a SPECIFIC defect was detected rather than that
// "something" was -- and a finding with no code cannot be asserted against.


// The text a check should score for a given document name.
//
// DOCUMENTATION.md is read through docs.DOCUMENTATION_ORIGINAL because that is
// what the self-test swaps a mutated copy into. Reading docs[name] instead made
// the count and link checks score the real file while the fixture swapped a
// different one, so both reported nothing for a fixture that contained exactly
// the defect they look for.
function docText(name) {
  return name === 'DOCUMENTATION.md' ? docs.DOCUMENTATION_ORIGINAL : docs[name]
}

function runAll() {
  findings.length = 0
  const doc = docs.DOCUMENTATION_ORIGINAL

  for (const name of Object.keys(api.exports || {})) {
    if (!mentions(doc, name)) {
      finding(
        CODE.UNMENTIONED,
        'DOCUMENTATION.md',
        `the export ${name} is declared in api.lua and never named`,
        'a consumer reading the documentation cannot find the name to call',
      )
    }
  }
  for (const name of Object.keys(api.commands || {})) {
    if (!mentions(doc, name)) {
      finding(
        CODE.UNMENTIONED,
        'DOCUMENTATION.md',
        `the console command ${name} is not documented`,
        'name it in the diagnostics section',
      )
    }
  }
  for (const name of Object.keys(api.events || {})) {
    if (!mentions(doc, name)) {
      finding(CODE.UNMENTIONED, 'DOCUMENTATION.md', `the event ${name} is not documented`, 'name it in the events table')
    }
  }

  checkLayout(doc)
  checkAssertionCount()
  checkReferences()
  checkVersions()
  checkUntestedClaims()
  checkScenariosAreDiscoverable()
}

// Claims the documentation must not make, because the tree makes them false.
//
// This is the narrowest and most useful check in the file. A documentation
// claim can be wrong in ways no tool can see -- a wrong return value, a wrong
// framework convention. But a handful of claims are checkable against the TREE
// itself, and the most expensive of those is "this is not tested".
//
// DOCUMENTATION.md said, for most of this resource's life, that the framework
// abstraction and the inventory service were "deliberately not unit-tested
// against a mock". It stayed true-looking long after twelve scenarios covered
// both of them, and a reader would have concluded a class of shipping bug was
// unguarded. A stale claim that understates what is checked costs more than a
// missing one: the missing claim sends someone to write a test, the false one
// sends them to ship.
//
// Deliberately narrow. It checks THIS claim shape and nothing else, because a
// general "is the docs lying" checker is not a thing you can build and a
// general one that guessed would produce findings nobody could act on.
function checkUntestedClaims() {
  const scenarioDir = path.join(root, 'test', 'scenarios')
  const scenarios = fs.existsSync(scenarioDir)
    ? fs.readdirSync(scenarioDir).filter((f) => f.endsWith('.lua'))
    : []
  if (scenarios.length === 0) return

  // BACKTICKED SPANS ARE STRIPPED FIRST, and that is not a detail.
  //
  // The section that documents the fix for a stale claim has to QUOTE the stale
  // claim to explain what changed -- and the first version of this check fired
  // on exactly that, reporting a document for saying "this used to say X" while
  // also saying X is no longer true. A quoted example is not a claim, and a
  // check that cannot tell them apart will eventually be silenced for being
  // wrong rather than being fixed.
  const doc = docs.DOCUMENTATION_ORIGINAL.replace(/`[^`]*`/g, '``')
  // "not tested", "no test over", "deliberately not unit-tested", and the
  // argument that usually follows them. Each of these is a claim about coverage,
  // and coverage is the one thing the tree can answer.
  const claims = [
    /deliberately\s+\*{0,2}not\*{0,2}\s+unit-tested/i,
    /are not (?:deliberately )?tested/i,
    /no test[s]? over this file/i,
    /there (?:was|is) no test/i,
    /deliberately not tested/i,
  ]
  for (const re of claims) {
    const m = re.exec(doc)
    if (!m) continue
    finding(
      CODE.STALE_CLAIM,
      'DOCUMENTATION.md',
      `claims something is untested ("${m[0].trim()}") while ${scenarios.length} scenarios exist`,
      'a coverage claim the tree can contradict is the worst kind of stale: it tells a reader a bug class is unguarded when it is not. Say what IS covered, and say what only a live server can answer',
    )
  }
}

// And the mirror: if a scenario directory exists, the documentation must
// mention it at all. A reader cannot be told to run something they cannot find.
function checkScenariosAreDiscoverable() {
  const scenarioDir = path.join(root, 'test', 'scenarios')
  const scenarios = fs.existsSync(scenarioDir)
    ? fs.readdirSync(scenarioDir).filter((f) => f.endsWith('.lua'))
    : []
  if (scenarios.length === 0) return
  for (const d of ['README.md', 'DOCUMENTATION.md']) {
    if (!mentions(docs[d], 'test/scenarios')) {
      finding(
        CODE.STALE_CLAIM,
        d,
        `${scenarios.length} scenarios exist and neither this document nor the README points at them`,
        'a reader who wants to run the framework tests has to find the directory themselves',
      )
    }
  }
}
function checkLayout(doc) {
  const i = doc.indexOf('§12')
  const layout = i === -1 ? doc : doc.slice(i)
  for (const abs of luaFiles(root)) {
    const rel = path.relative(root, abs).replace(/\\/g, '/')
    // A DIRECTORY in the listing satisfies its files: the layout says
    // `configs/`, and spelling out every file under it would be redundant. What
    // it does not accept is a file listed nowhere, because that layout is the
    // map a reader uses to find the thing they were just told about.
    const dir = rel.split('/')[0] + '/'
    if (mentions(layout, rel) || mentions(layout, dir)) continue
    finding(
      CODE.LAYOUT,
      'DOCUMENTATION.md',
      `${rel} is not in the layout section`,
      'every shipped file is listed, or a reader cannot find it',
    )
  }
}

function checkAssertionCount() {
  const result = require('child_process').spawnSync(process.execPath, [path.join(root, 'test', 'run.js')], {
    cwd: root,
    encoding: 'utf8',
  })
  const m = /suites=(\d+) passed=(\d+) failed=(\d+)/.exec(result.stdout || '')
  if (!m) return
  const total = Number(m[2]) + Number(m[3])
  for (const d of ['README.md', 'DOCUMENTATION.md']) {
    const quoted = docText(d).match(/(\d+)\s+assertions/)
    if (quoted && Number(quoted[1]) !== total) {
      finding(
        CODE.STALE_COUNT,
        d,
        `says "${quoted[1]} assertions" and the suite currently runs ${total}`,
        'quote the number the suite actually runs, or point at `npm test`',
      )
    }
  }
}

function checkReferences() {
  for (const d of DOCS) {
    const text = docText(d)
    // Markdown links. A target with no separator and no dot is prose, not a
    // link -- `](text)` happens in ordinary writing.
    for (const m of text.matchAll(/\]\((?!https?:)([^)#]+)\)/g)) {
      const target = m[1].trim()
      if (!/[/.]/.test(target)) continue
      if (!looksLocal(target)) continue
      if (!fs.existsSync(path.join(root, target))) {
        finding(CODE.DEAD_LINK, d, `links to ${target}, which does not exist`, 'a dead link in shipped documentation is a support ticket')
      }
    }
    // Backticked file names.
    for (const m of text.matchAll(/`([\w./-]+\.(?:lua|md|sql|js|json|yml))`/g)) {
      const target = m[1]
      if (!looksLocal(target)) continue
      if (!fs.existsSync(path.join(root, target))) {
        finding(CODE.DEAD_LINK, d, `names ${target} in backticks, which does not exist`, 'either the file moved or the name is wrong')
      }
    }
  }
}

function checkVersions() {
  const manifest = read('fxmanifest.lua').match(/^\s*version\s+["']([^"']+)["']/m)
  if (manifest && api.version !== manifest[1]) {
    finding(CODE.VERSION, 'api.lua', `says version ${api.version} and fxmanifest says ${manifest[1]}`, 'they are the same number')
  }
  for (const d of ['README.md', 'DOCUMENTATION.md']) {
    const quoted = docText(d).match(/Version\s+\*?\*?(\d+\.\d+\.\d+)/)
    if (quoted && quoted[1] !== api.version) {
      finding(CODE.VERSION, d, `quotes version ${quoted[1]} and the contract says ${api.version}`, 'the three must agree')
    }
  }
}


runAll()

console.log(`doc-check: ${DOCS.length} documents, ${Object.keys(api.exports || {}).length} exports, ` +
  `${Object.keys(api.commands || {}).length} commands, ${Object.keys(api.events || {}).length} events`)
if (findings.length === 0) {
  console.log('  clean: every export, command, event and file is documented; every link resolves; every number agrees')
} else {
  for (const f of findings) {
    console.log(`  ${f.where}`)
    console.log(`      ${f.what}`)
    console.log(`      fix: ${f.fix}`)
  }
  console.log(`  ${findings.length} finding(s) across ${new Set(findings.map((f) => f.where)).size} document(s)`)
  process.exit(1)
}