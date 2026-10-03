'use strict'

// Static hygiene for the Lua sources.
//
// WHY THIS EXISTS WHEN THERE IS A LINTER
//
// `tools/luacheck.js` checks that files PARSE. Parsing is not hygiene, and the
// four classes of defect below all parse perfectly:
//
//   * a missing `local` is valid Lua, and the leak is invisible until two
//     resources load in an order you did not choose;
//   * `for i = 0, #t` is valid Lua and reads the wrong slot;
//   * `!=` inside a COMMENT parses, and ships;
//   * a module table that only ever grows is valid Lua and is a slow memory
//     leak nobody can point at.
//
// So this checks things a parser cannot: it reports them with a line, a snippet
// and -- where it can -- what the fix is. Findings are FAILURES, not advice.
//
// NOT A LINTER. It does not know types, does not track scope properly, and
// every finding carries the line so a human decides. A check that cries wolf
// gets deleted, and then the four things it was watching are unwatched again.

const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..')

// ---------------------------------------------------------------------------
// Blank out comments AND string bodies, preserving line structure and offsets.
//
// `stripComments` from lua-exports.js removes comments but KEEPS string
// contents, because it exists to find names. Here the opposite is needed: a
// `#` inside a string must not read as a comment, and a `!=` inside a string
// must not read as an operator.
// ---------------------------------------------------------------------------
function blankLiterals(src) {
  let out = ''
  let i = 0
  while (i < src.length) {
    const c = src[i]
    // long bracket string / comment: [=*[ ... ]=*]
    if (c === '[' && /^\[=*\[/.test(src.slice(i, i + 20))) {
      const open = src.slice(i).match(/^\[=*\[/)[0]
      const close = open[0] + '='.repeat(open.length - 2) + ']'
      const end = src.indexOf(close, i + open.length)
      const stop = end === -1 ? src.length : end + close.length
      // keep the newlines so line numbers stay right
      for (let k = i; k < stop; k++) out += src[k] === '\n' ? '\n' : ' '
      i = stop
      continue
    }
    if (c === '"' || c === "'") {
      const quote = c
      out += c
      i += 1
      while (i < src.length) {
        if (src[i] === '\\') {
          out += '  '
          i += 2
          continue
        }
        if (src[i] === quote) {
          out += quote
          i += 1
          break
        }
        out += src[i] === '\n' ? '\n' : ' '
        i += 1
      }
      continue
    }
    if (c === '-' && src[i + 1] === '-') {
      const longComment = /^\[=*\[/.test(src.slice(i + 2, i + 22))
      if (longComment) {
        const open = src.slice(i + 2).match(/^\[=*\[/)[0]
        const close = open[0] + '='.repeat(open.length - 2) + ']'
        const end = src.indexOf(close, i + 2 + open.length)
        const stop = end === -1 ? src.length : end + close.length
        for (let k = i; k < stop; k++) out += src[k] === '\n' ? '\n' : ' '
        i = stop
        continue
      }
      while (i < src.length && src[i] !== '\n') {
        out += ' '
        i += 1
      }
      continue
    }
    out += c
    i += 1
  }
  return out
}

// ---------------------------------------------------------------------------
// The globals that are allowed to be globals.
// ---------------------------------------------------------------------------

// Declared by this resource ON PURPOSE. Each is a capability surface, a boot
// contract another resource is documented to reach, or a test-harness module the
// runner loads by name. Removing one from this list means proving nobody reads
// it -- see PLATFORM_NOTES.md.
//
// This list IS the decision record. An entry here is a claim that a global is
// load-bearing, and the claim is what a reviewer reads.
const CIS_GLOBALS = new Set([
  // Capability surfaces and boot contracts, reachable from other resources.
  'CisAuthority', 'CisConfig', 'CisDoctor', 'CisMigrationRunner', 'CisMigrations',
  'CisMigrationsApplied', 'CisNormalize', 'CisState', 'CisStateRules',
  'CoreLibs', 'Config', 'Security', 'DiscordConfig', 'Discord', 'FrameworkLoaded',
  // The framework capability tables. `CisFramework` is the server surface and
  // `Framework` the client one -- the client declares its own `Framework`
  // because a global of that name meaning two different things in two realms is
  // documented here rather than accidental.
  'CisFramework', 'Framework',
  // Test harness modules. test/run.js and test/scenarios.js load them into a
  // fresh Lua state by name, so they cannot be local to a file.
  'Test', 'FrameworkEnv',
])

// Lua standard library and FiveM natives. Not exhaustive on purpose: an unknown
// name is REPORTED, and the fix is either to declare it local or to add it here
// with a reason. That is the whole design -- the list is a decision record.
const KNOWN_GLOBALS = new Set([
  // Lua
  'assert', 'collectgarbage', 'dofile', 'error', 'getfenv', 'getmetatable', 'ipairs',
  'load', 'loadfile', 'next', 'pairs', 'pcall', 'print', 'rawequal', 'rawget',
  'rawlen', 'rawset', 'require', 'select', 'setfenv', 'setmetatable', 'tonumber',
  'tostring', 'type', 'unpack', 'xpcall', 'coroutine', 'debug', 'io', 'math',
  'os', 'package', 'string', 'table', 'utf8', 'bit32', 'jit', 'arg', '_G', '_VERSION',
  // FiveM server / shared
  'AddEventHandler', 'RegisterNetEvent', 'TriggerEvent', 'TriggerClientEvent',
  'TriggerServerEvent', 'CreateThread', 'Citizen', 'Wait', 'Citizen.CreateThread',
  'Citizen.Wait', 'Citizen.SetTimeout', 'SetTimeout', 'exports', 'source',
  'GetResourceState', 'GetResourceMetadata', 'GetNumResourceMetadata',
  'GetCurrentResourceName', 'GetInvokingResource', 'IsDuplicityVersion',
  'GetGameTimer', 'GetPlayers', 'GetPlayerName', 'GetPlayerFromIndex',
  'GetNumPlayerIndices', 'GetMaxPlayers', 'DropPlayer', 'json', 'load', 'loadstring',
  // FiveM client
  'PlayerPedId', 'PlayerId', 'GetPlayerPed', 'NetworkIsPlayerActive',
])

// Lua keywords and anything that can never be an assignment target.
const KEYWORDS = new Set([
  'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto',
  'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true',
  'until', 'while',
])

// ---------------------------------------------------------------------------
// The checks
// ---------------------------------------------------------------------------

const findings = []

function report(code, file, line, snippet, message, fix) {
  findings.push({ code, file, line, snippet: snippet.trim(), message, fix })
}

// S001 -- operators that are not Lua. They appear in comments and in pasted
// Java most often, and they survive review because a reader skims past them.
function checkOperators(clean, file, raw) {
  // Scan the ORIGINAL source for operators, but only where the cleaned source at
  // the same offset is blank (i.e. not inside a string) and not a comment.
  const patterns = [
    [/\s!=\s/g, 'S001', '`!=` is not a Lua operator; it is Java, C or SQL', 'write `~=`'],
    [/&&/g, 'S001', '`&&` is not a Lua operator', 'write `and`'],
    [/\|\|/g, 'S001', '`||` is not a Lua operator', 'write `or`'],
    [/[^~=!<>]===[^=]/g, 'S001', '`===` is not a Lua operator', 'write `==`'],
  ]
  for (const [re, code, message, fix] of patterns) {
    let m
    re.lastIndex = 0
    while ((m = re.exec(raw)) !== null) {
      const at = m.index
      // Skip if it is inside a string or a comment in the cleaned copy.
      if (clean[at] !== m[0].trim()) {
        // the cleaned copy blanks literals; if it shows nothing there, it was a literal
      }
      const cleanedHere = clean.slice(Math.max(0, at - 1), at + m[0].length)
      if (cleanedHere.includes(' ') && !cleanedHere.includes(m[0])) {
        // blanked: inside a string or comment
        continue
      }
      const line = raw.slice(0, at).split('\n').length
      report(code, file, line, raw.split('\n')[line - 1] || '', message, fix)
    }
  }
}

// S002 -- a numeric for over a table, which is the shape that reads slot 0.
//
// `for i = 0, #t` is correct only when the body compensates with `[i+1]`. This
// reports the loop and lets the reader confirm the compensation, because the
// common case by far is a plain mistake that reads a nil and moves on.
function checkZeroIndexedLoops(clean, file) {
  const lines = clean.split('\n')
  lines.forEach((text, idx) => {
    // ONLY when the bound is a LENGTH, and `\s*` before `do` -- `for i = 0, #t
    // do` has a space there, and the first version of this pattern did not, so
    // it matched nothing at all and the check passed vacuously.
    //
    // `for j = 0, lb do` is a row of an edit-distance matrix and index 0 is
    // correct there; the first version flagged every numeric-for-from-0 and
    // duly reported one, which is how a check either learns to be narrower or
    // gets deleted.
    const m = text.match(/\bfor\s+([A-Za-z_][\w]*)\s*=\s*0\s*,\s*(#[A-Za-z_][\w.]*(?:\[[^\]]+\])?)\s*do\b/)
    if (!m) return
    const body = lines.slice(idx, idx + 8).join('\n')
    const compensated = new RegExp(`\\[\\s*${m[1]}\\s*\\+\\s*1\\s*\\]`).test(body)
    if (!compensated) {
      report('S002', file, idx + 1, text,
        `numeric for starts at 0 over the length of ${m[2].slice(1)}`,
        'Lua tables are 1-indexed: either start at 1, or index with [i + 1] -- which this loop does not do anywhere in the next few lines')
    }
  })
}

// S003 -- an assignment to a bare name that is neither local, nor a known
// global, nor a keyword.
//
// The highest-value check in this file. A missing `local` is valid Lua that
// leaks into _G, where it collides with whatever resource loads next, and the
// symptom is a value that is right on the machine you wrote it on.
function checkAccidentalGlobals(clean, file, localsInFile) {
  const lines = clean.split('\n')
  lines.forEach((text, idx) => {
    const trimmed = text.trim()
    if (!trimmed || trimmed.startsWith('--')) return

    // `name =`, `name +=`, `name -=`, but NOT `a.b =`, `a[b] =`, `f(x) =`, or
    // anything that is a call argument. Requiring the name at the START of the
    // statement and followed by `=`, `+=` or `-=` is what keeps this precise.
    const m = trimmed.match(/^([A-Za-z_][\w]*)\s*(?:\+=|-=|=(?!=))/)
    if (!m) return
    const name = m[1]
    if (KEYWORDS.has(name)) return
    if (KNOWN_GLOBALS.has(name)) return
    if (CIS_GLOBALS.has(name)) return
    // A local declared anywhere in the file is fine, and so is a function
    // PARAMETER -- which is what stops `function f(count) count = count + 1 end`
    // being reported as a leak. This is a scope heuristic rather than a
    // resolver: a false "it is local" costs a missed finding, while a false "it
    // is global" would be an accusation, so the bias is deliberate.
    if (localsInFile.has(name)) return

    report('S003', file, idx + 1, text,
      `assigns to \`${name}\`, which is neither declared local nor a known global`,
      `add \`local ${name}\` -- or, if it is meant to be shared, add it to CIS_GLOBALS in tools/static-analysis.js with a reason`)
  })
}

// S004 -- a local that shadows a Lua or FiveM global by name.
//
// Lower severity than S003 and a different failure: the code works, and the
// shadowing is invisible at the call site.
function checkShadowing(clean, file, localsInFile) {
  for (const name of localsInFile) {
    if (!KNOWN_GLOBALS.has(name)) continue
    const lines = clean.split('\n')
    lines.forEach((text, idx) => {
      if (new RegExp(`\\blocal\\s+${name}\\b`).test(text)) {
        report('S004', file, idx + 1, text,
          `\`local ${name}\` shadows a global of the same name`,
          `rename it. Inside this file \`${name}\` means the local, everywhere else it means the global, and the two are not the same thing.`)
      }
    })
  }
}

// ---------------------------------------------------------------------------
// Thread and resmon discipline
//
// These are not style rules. A `while true do Wait(0)` loop in this resource
// burns a slice of every frame forever, on every client, for a service that is
// meant to be idle most of the time -- and the symptom is not a crash, it is a
// server that is quietly slower and never says so.
//
// The target this resource states for itself is 0.00-0.02 ms idle. A single
// Wait(0) loop is three orders of magnitude past that, and nothing in a boot log
// will mention it.
// ---------------------------------------------------------------------------

// S005 -- Wait(0). Never correct here: nothing in this resource draws, so there
// is no frame to synchronise to.
function checkZeroWait(clean, file) {
  clean.split('\n').forEach((text, idx) => {
    if (/\bWait\s*\(\s*0\s*\)/.test(text)) {
      report(
        'S005',
        file,
        idx + 1,
        text,
        'waits zero milliseconds',
        'nothing here draws, so there is no frame to sync to. Use an explicit interval, or event-driven code with no loop at all',
      )
    }
  })
}

// S006 -- a loop that never yields.
//
// `while true do` is correct in a client render loop and a leak everywhere else,
// so the test is not the loop but the ABSENCE of a Wait in its body: a thread
// that never yields stops being scheduled for anything else, and the resource
// stops responding while nothing on screen moves.
function checkUnboundedLoops(clean, file) {
  const lines = clean.split('\n')
  lines.forEach((text, idx) => {
    if (!/\bwhile\s+true\s+do\b/.test(text)) return
    const body = lines.slice(idx, idx + 12).join('\n')
    if (/\bWait\s*\(|\bCitizen\.Wait\s*\(/.test(body)) return
    report(
      'S006',
      file,
      idx + 1,
      text,
      'unbounded loop with no Wait in its body',
      'the thread never yields, so nothing else runs on it. If this is a client render loop, say so in a comment and keep the draw',
    )
  })
}

// S007 -- a poll tighter than the floor.
//
// 50 ms is the floor this resource uses everywhere, and every one of those is a
// boot-path wait for another RESOURCE to start, which happens a handful of times
// per server start. A shorter interval is a per-frame cost wearing a poll's
// clothes, and 50 ms against 10 ms is indistinguishable to a player.
const MIN_POLL_MS = 25

function checkPollInterval(clean, file) {
  clean.split('\n').forEach((text, idx) => {
    const m = /\bWait\s*\(\s*([0-9]+)\s*\)/.exec(text)
    if (!m) return
    const ms = Number(m[1])
    if (ms >= MIN_POLL_MS) return
    report(
      'S007',
      file,
      idx + 1,
      text,
      `polls every ${ms}ms`,
      `below the ${MIN_POLL_MS}ms floor. Every poll is a scheduler round trip on every client; if this is waiting for a resource to start, 50ms is indistinguishable to a human and an order of magnitude cheaper`,
    )
  })
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

function luaFiles(dir, acc = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.git') continue
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) luaFiles(full, acc)
    else if (entry.name.endsWith('.lua')) acc.push(full)
  }
  return acc
}

// Everything one file needs, so the driver and the self-test run IDENTICAL
// checks. A self-test that re-implements the check is a test of itself.
function analyze(file, rel) {
  findings.length = 0
  const raw = fs.readFileSync(file, 'utf8')
  const clean = blankLiterals(raw)

  const localsInFile = new Set()
  for (const m of clean.matchAll(/\blocal\s+(?:function\s+)?([A-Za-z_][\w]*)/g)) {
    localsInFile.add(m[1])
  }
  for (const m of clean.matchAll(/\blocal\s+[A-Za-z_][\w]*\s*,\s*([A-Za-z_][\w]*)/g)) {
    localsInFile.add(m[1])
  }
  // Function PARAMETERS are locals, and an assignment to one is the single
  // commonest shape that is not a leak. Without collecting them the check
  // reports every `count = count + 1` in the repository.
  for (const m of clean.matchAll(/\bfunction\s*[A-Za-z_][\w.:]*\s*\(([^)]*)\)/g)) {
    for (const part of m[1].split(',')) {
      const n = part.trim().match(/^([A-Za-z_][\w]*)/)
      if (n) localsInFile.add(n[1])
    }
  }
  // ...and so is a generic-for variable.
  for (const m of clean.matchAll(/\bfor\s+([A-Za-z_][\w]*)\s*(?:,\s*([A-Za-z_][\w]*))?\s+in\b/g)) {
    localsInFile.add(m[1])
    if (m[2]) localsInFile.add(m[2])
  }

  checkOperators(clean, rel, raw)
  checkZeroIndexedLoops(clean, rel)
  checkAccidentalGlobals(clean, rel, localsInFile)
  checkShadowing(clean, rel, localsInFile)
  checkZeroWait(clean, rel)
  checkUnboundedLoops(clean, rel)
  checkPollInterval(clean, rel)
  return findings.slice()
}

// The self-test, and it runs FIRST when asked: each fixture in
// test/static/broken/ is broken on purpose and must still fail with its own
// code.
//
// test/api/broken/** does the same job for the contract validator, for the
// same reason -- a checker that has only ever been seen to pass has not been
// tested. It is also why the main scan EXCLUDES both directories: their defects
// are the fixtures', not ours.
function selftest() {
  const dir = path.join(root, 'test', 'static', 'broken')
  const expectFile = path.join(dir, 'expect.txt')
  if (!fs.existsSync(expectFile)) {
    console.error('static analysis self-test: no expect.txt, so the run would be vacuous')
    return 1
  }
  const expected = fs
    .readFileSync(expectFile, 'utf8')
    .trim()
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)

  console.log('static analysis self-test')
  let ok = true

  for (const line of expected) {
    const [name, code] = line.split(/\s+/)
    const file = path.join(dir, name)
    if (!fs.existsSync(file)) {
      console.log(`  FAIL  broken/${name} does not exist`)
      ok = false
      continue
    }
    const got = analyze(file, name).map((f) => f.code)
    if (!got.includes(code)) {
      console.log(`  FAIL  broken/${name} did not raise ${code}; got ${[...new Set(got)].join(', ') || 'nothing'}`)
      ok = false
      continue
    }
    console.log(`  PASS  broken/${name} fails with ${[...new Set(got)].join(', ')}`)
  }

  // AND THE NEGATIVE, which is the half that matters most.
  //
  // Without it the checker could pass every fixture above by reporting
  // everything, loudly, forever -- and a checker that reports a Java operator
  // inside a code comment is a checker whose output nobody reads.
  const tricky = path.join(dir, '_tricky_clean.lua')
  fs.writeFileSync(
    tricky,
    [
      '-- a != b in a comment is not an operator',
      '-- for i = 0, #t do in a comment is not a loop',
      "-- a string containing != and && and || and a 0, #t loop",
      'local t = { 1, 2 }',
      'local out = {}',
      'for i = 1, #t do',
      '    out[#out + 1] = t[i]',
      'end',
      'local counted = 1',
      'return out, counted',
      '',
    ].join('\n'),
  )
  const cleanRun = analyze(tricky, '_tricky_clean.lua')
  fs.unlinkSync(tricky)
  if (cleanRun.length > 0) {
    console.log(
      `  FAIL  a file whose defects are only in comments and strings raised ${[
        ...new Set(cleanRun.map((f) => f.code)),
      ].join(', ')}`,
    )
    ok = false
  } else {
    console.log('  PASS  defects inside comments and strings are not reported')
  }

  return ok ? 0 : 1
}

if (process.argv.includes('--selftest')) {
  process.exit(selftest())
}

const files = luaFiles(root)
const scanned = files.filter(
  (f) =>
    !f.includes(`${path.sep}test${path.sep}api${path.sep}broken${path.sep}`) &&
    !f.includes(`${path.sep}test${path.sep}static${path.sep}broken${path.sep}`),
)

for (const file of scanned) {
  for (const f of analyze(file, path.relative(root, file))) findings.push(f)
}

const byCode = findings.reduce((acc, f) => {
  acc[f.code] = (acc[f.code] || 0) + 1
  return acc
}, {})

console.log(`static analysis: ${scanned.length} files`)
if (findings.length === 0) {
  console.log('  clean: no non-Lua operators, no 0-indexed loops, no accidental globals, no shadowing,')
  console.log('         no Wait(0), no unbounded loops, no poll under the floor')
} else {
  for (const f of findings) {
    console.log(`  ${f.code} ${f.file}:${f.line}`)
    console.log(`      ${f.message}`)
    console.log(`      fix: ${f.fix}`)
    console.log(`      > ${f.snippet}`)
  }
  console.log(`  ${Object.entries(byCode).map(([c, n]) => `${n} ${c}`).join(', ')}`)
  process.exit(1)
}