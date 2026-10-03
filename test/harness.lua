-- The test harness. Tiny on purpose, and shared by every suite in this folder.
--
-- WHY IT IS A FILE AND NOT A COPY-PASTE
--
-- The first version of each suite ended with its own report block and its own
-- `os.exit(1)`. That works right up until there is a second suite: `os.exit`
-- takes the whole Lua state with it, so the second file never ran and the run
-- reported success for the suites that had already passed. A test that cannot
-- stop the run is a test whose failure is invisible, and this one is the worst
-- possible instance -- it would have reported "all green" on a run where half
-- the assertions never executed.
--
-- So: a suite calls `Test.begin`, `Test.check` as many times as it likes, and
-- `Test.report` at the end. `Test.totals()` is what test/run.js reads to decide
-- the exit code, and it is read AFTER every suite has loaded.

Test = { suites = {} }

local current = nil

--- Start a suite. The name is the one printed in the run line.
function Test.begin(name)
    current = { name = name, passed = 0, failed = 0, failures = {}, notes = {} }
    Test.suites[#Test.suites + 1] = current
end

--- One assertion.
---
--- `cond` is the truthiness of the thing under test and `msg` is what the
--- failure should SAY. A message that only names the function ("order failed")
-- costs the next person the whole investigation, so every message here is a
--- sentence about behaviour: what is true, and what it would mean if it were not.
function Test.check(cond, msg)
    if current == nil then
        error('Test.check called before Test.begin', 2)
    end
    if cond then
        current.passed = current.passed + 1
    else
        current.failed = current.failed + 1
        current.failures[#current.failures + 1] = msg
    end
end

--- Print one suite's result. Returns nothing; the totals are read separately.
function Test.report()
    if current == nil then
        error('Test.report called before Test.begin', 2)
    end
    for i = 1, #current.failures do
        io.stderr:write(('FAIL(%s): %s\n'):format(current.name, current.failures[i]))
    end
    -- Notes only when something failed. A passing run that printed its own
    -- context would train people to skip the output, which is the one thing an
    -- output nobody reads is for.
    if current.failed > 0 then
        for n = 1, #current.notes do
            io.stderr:write(('  note(%s): %s\n'):format(current.name, current.notes[n]))
        end
    end
    io.write(('%s passed=%d failed=%d\n'):format(current.name, current.passed, current.failed))
end

--- A line of context for a failure, printed with the suite's result.
---
--- For the tests that run inside a SIMULATED world. When one of them fails the
--- question is never "what did the assertion say" -- it is "what world did the
--- code under test actually see". A scenario attaches that here and it comes out
--- next to the failure, instead of costing a re-run with a print added and then
--- removed.
function Test.note(msg)
    if current == nil then
        error('Test.note called before Test.begin', 2)
    end
    current.notes[#current.notes + 1] = tostring(msg)
end

--- Grand totals, across every suite that ran. `{ passed, failed, suites }`.
function Test.totals()
    local passed, failed, suites = 0, 0, 0
    for _, s in ipairs(Test.suites) do
        passed = passed + s.passed
        failed = failed + s.failed
        suites = suites + 1
    end
    return passed, failed, suites
end

--- Raise when anything failed.
---
--- For the scenario runner, which decides pass/fail from whether the file LOADED
--- rather than by parsing printed output. A scenario that quietly finished with
--- six failed assertions and a clean status would report as a pass, which is
--- worse than not running it at all.
function Test.raiseIfFailed()
    local passed, failed = Test.totals()
    if failed > 0 then
        error(('%d of %d assertions failed'):format(failed, passed + failed), 0)
    end
end