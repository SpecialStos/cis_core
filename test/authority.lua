-- Tests for the event authority rule.
--
-- THE STUBS BELOW ARE THE POINT, NOT A WORKAROUND
--
-- test/state.lua and test/normalize.lua test pure functions because pure
-- functions are all that could be reached. This file is the exception that
-- proves the exception was worth making: `CisAuthority.resolveSource` is the
-- resource's most security-relevant decision and it depends on three things
-- that do not exist off a server -- `source`, `GetMaxPlayers` and `GetPlayerName`.
--
-- Those three are stubbed. What is NOT stubbed is the thing under test: the
-- rule, its ordering, and the decision about which of two disagreeing values
-- wins. A stub that decides the answer would make the test a comment, and this
-- one does not -- it only supplies the facts of the world.
--
-- The behaviour under test is not hypothetical. A client could send
-- `QBCore:Server:OnJobUpdate` naming another player's source, and
-- `PublishJobUpdate` ends in `TriggerClientEvent('cis_libs:jobUpdated', src,
-- ...)`, so that player would have received a job they did not have --
-- including this resource's own client, which stores exactly that event.

Test.begin('authority')
local check = Test.check

-- ---------------------------------------------------------------- the world
-- Replaced before the module under test is loaded, because `source` is a
-- global read inside its handler and the two natives are resolved at call time.
local MAX_PLAYERS = 64
local connected = { [1] = 'Alice', [2] = 'Bob', [5] = 'Eve', [9] = 'Ivy' }

function GetMaxPlayers()
    return MAX_PLAYERS
end

function GetPlayerName(src)
    return connected[src]
end

_G.source = 0

-- `print` is counted rather than swallowed, because the warn-once behaviour is
-- part of what is being tested: a resource that logs one line per forged event
-- hands an attacker a way to fill an operator's console.
local printed = {}
local realPrint = print
_G.print = function(...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        parts[i] = tostring((select(i, ...)))
    end
    printed[#printed + 1] = table.concat(parts, '\t')
end

-- ================================================================== the world
check(CisAuthority ~= nil, 'the module loaded')
check(type(CisAuthority.resolveSource) == 'function', 'resolveSource is exposed')

-- `isPlayer` is the gate everything else stands on.
check(CisAuthority.isPlayer(1) == true, 'a connected player is a player')
check(CisAuthority.isPlayer(MAX_PLAYERS + 1) == false, 'a source above GetMaxPlayers is refused')
check(CisAuthority.isPlayer(0) == false, 'the console is not a player')
check(CisAuthority.isPlayer(-1) == false, 'a negative source is refused')
check(CisAuthority.isPlayer(7) == false, 'an in-range but disconnected source is refused')
for _, junk in ipairs({ '5', {}, true, print }) do
    check(CisAuthority.isPlayer(junk) == false, ('a %s is not a player'):format(type(junk)))
end

-- ============================================ the checks this file leans on
-- The gate is `GetPlayerName(src) ~= nil`. `GetMaxPlayers()` is a refinement,
-- and it could not be verified to exist on every build -- so a check that
-- RAISES must cost a bounds check, never the whole function. Both cases below
-- were live risks before the hardening.
local realMaxPlayers = GetMaxPlayers

function GetMaxPlayers()
    error('this build has no GetMaxPlayers', 0)
end
check(CisAuthority.isPlayer(1) == true,
    'a missing GetMaxPlayers costs the bounds check, not the answer')
check(CisAuthority.isPlayer(7) == false,
    'and a disconnected player is still refused without it')

function GetMaxPlayers()
    return 'not a number'
end
check(CisAuthority.isPlayer(1) == true, 'a GetMaxPlayers that answers nonsense is ignored too')
GetMaxPlayers = realMaxPlayers

local realPlayerName = GetPlayerName
function GetPlayerName()
    error('this build raises here', 0)
end
check(CisAuthority.isPlayer(1) == false,
    'a GetPlayerName that RAISES fails closed -- an unknown sender is never trusted')
GetPlayerName = realPlayerName
check(CisAuthority.isPlayer(1) == true, 'and the gate works again once it stops raising')

-- ================================================ the server-side trigger case
-- `source == 0` means the framework called its own event. There is no networked
-- sender to contradict the payload, so the payload is believed -- this is the
-- path every legitimate framework event takes, and getting it wrong would break
-- every framework on the platform.
_G.source = 0
check(CisAuthority.resolveSource(5, 'test') == 5,
    'a server-side trigger is believed: the framework named the player')
check(CisAuthority.resolveSource(99, 'test') == nil,
    'a server-side trigger naming a player who is not connected does nothing')
check(CisAuthority.resolveSource(nil, 'test') == nil, 'a server-side trigger with no source does nothing')
check(CisAuthority.resolveSource('5', 'test') == nil, 'a string source is not a player id')

-- =============================================== the networked trigger case
-- `source == player` means a CLIENT sent it. Here the payload may name nobody
-- but the sender, and this is the whole of the fix.
_G.source = 5
check(CisAuthority.resolveSource(5, 'test') == 5,
    'a client naming ITSELF is allowed -- self-inflicted and true')

local before = CisAuthority.spoofed
local got = CisAuthority.resolveSource(9, 'QBCore:Server:OnJobUpdate')
check(got == 5, 'a client naming ANOTHER player gets the network source, not the payload')
check(got ~= 9, 'and specifically not the source it asked for')
check(CisAuthority.spoofed == before + 1, 'the forgery is counted')

-- Every connected player is equally off-limits, not just one.
local before2 = CisAuthority.spoofed
check(CisAuthority.resolveSource(1, 'test') == 5, 'naming player 1 gets the network source')
check(CisAuthority.resolveSource(2, 'test') == 5, 'naming player 2 gets the network source')
check(CisAuthority.spoofed == before2 + 2, 'each one is counted')

-- ============================================================ the log, once
check(#printed == 1, 'the first forgery logs exactly one line')

-- Read through a guard rather than `printed[1]:find(...)`. If the rule is
-- reverted, nothing is logged, and indexing a missing first element raises
-- inside the suite -- which fails the run, but with "attempt to index a nil
-- value" instead of the sentence naming the behaviour that broke. A test that
-- cannot explain its own failure is one people stop reading.
local firstLine = printed[1] or ''
check(firstLine:find('QBCore:Server:OnJobUpdate', 1, true) ~= nil,
    'the line names the event, so an operator knows what to look for')
check(firstLine:find('5', 1, true) ~= nil, 'and what the network said')
check(firstLine:find('9', 1, true) ~= nil, 'and what the payload claimed')

-- More forgeries after the first must not produce more lines. A log per forged
-- event is a denial of service wearing a log line.
_G.source = 2
for _ = 1, 20 do
    CisAuthority.resolveSource(1, 'test')
end
check(#printed == 1, 'a flood of forgeries still logs only the first one')
check(CisAuthority.spoofed >= 23, 'and every one of them is still counted')

-- ============================================================ mixed payloads
-- The payload is whatever a client sent, which is any type at all -- and the
-- ONLY one of these is a forgery.
--
-- A forgery is a NUMBER naming somebody else. A string, a boolean or a table
-- names nobody, so nothing was forged; they are answered with the sender and
-- counted separately. Getting this backwards made the counter forgeable by
-- anyone with a zero-byte event, and the doctor reported the inflation as
-- clients forging sources -- which is the one number here that is supposed to
-- mean "a cheat menu did this".
_G.source = 1
local before3 = CisAuthority.spoofed
local beforeAnon = CisAuthority.anonymous

local junkPayloads = { '9', 9.5, true, {} }
for _, junk in ipairs(junkPayloads) do
    local r = CisAuthority.resolveSource(junk, 'test')
    check(r == 1, ('a %s payload gets the network source'):format(type(junk)))
end

-- 9.5 is the only one of the four that named a number.
check(CisAuthority.spoofed == before3 + 1,
    'only a NUMERIC payload that differs counts as a forgery')
check(CisAuthority.anonymous == beforeAnon + 3,
    'and the other three are counted as events that named nobody')

-- A nil payload from a client is a forgery, not an absence: the client DID send
-- an event, and the only player it could have been about is itself.
check(CisAuthority.resolveSource(nil, 'test') == 1, 'a client sending no source at all gets itself')

-- ============================================================== never raises
-- `source` is set by the runtime, but the payload is not, and a handler that
-- raises takes down whatever thread called it.
_G.source = nil
local okNoSource = pcall(CisAuthority.resolveSource, 5, 'test')
check(okNoSource, 'a missing `source` global does not raise')

_G.source = 'not a number'
local okStringSource = pcall(CisAuthority.resolveSource, 5, 'test')
check(okStringSource, 'a string `source` does not raise')

_G.source = 0
local okNoName = pcall(CisAuthority.resolveSource, 5)
check(okNoName, 'a missing event name does not raise')

-- ============================================================== tear down
_G.print = realPrint
_G.source = 0
connected = nil

Test.report()