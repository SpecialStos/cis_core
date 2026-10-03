-- =============================================================================
--  cis_core -- event authority  (SERVER SIDE ONLY)
--
--  THE ONE RULE THIS FILE EXISTS TO ENFORCE
--
--  In FiveM a client can `TriggerServerEvent` with ANY event name and ANY
--  payload. `esx:playerLoaded` is therefore not an ESX event: it is a name a
--  player can type. Every handler in this resource that reads a player source
--  out of a payload is therefore trusting a value the sender chose, and the
--  only question is whether anything trusted with it notices.
--
--  For this resource it did not, for a long time. `PublishJobUpdate(job, src)`
--  ends in
--
--      TriggerClientEvent('cis_libs:jobUpdated', src, { name = ..., grade = ... })
--
--  so a client that sent `QBCore:Server:OnJobUpdate` naming somebody else's
--  source made THAT PLAYER'S CLIENT receive a job it did not have -- and
--  cis_core's own client listens for that event and stores it, so the poisoned
--  job was the platform's, not just a consumer's.
--
--  `source` is the answer, and it is not complicated:
--
--      source == 0        the framework triggered this from its own server
--                         code. Its payload is real. There is no networked
--                         sender to contradict it.
--
--      source == player   a CLIENT triggered this. The payload may name nobody
--                         but the player who sent it.
--
--  So: a payload-supplied source is trusted only when there is no networked
--  source to contradict it, and when there is one the networked source wins and
--  the disagreement is counted.
--
--  THE RESULT IS NOT "REFUSE THE EVENT". A player stays able to do this to
--  THEMSELVES -- harmless, and true -- and is unable to do it to anybody else,
--  which is the entire point. Refusing outright would break every framework
--  whose event is legitimately triggered from the client, which is most of
--  them, in exchange for a stricter rule nobody asked for.
-- =============================================================================

CisAuthority = {}

-- Counted, and surfaced by cis_core_doctor, because a source that disagrees
-- with itself is the signature of a cheat menu and an operator should never
-- have to ask what it means.
-- A source that NAMED somebody else. This is the one that means a cheat menu,
-- and it is counted only when the payload contained a NUMBER -- see
-- resolveSource for why that distinction is load-bearing.
CisAuthority.spoofed = 0

-- An event sent from a client with no source in the payload at all. Correctly
-- answered, and evidence of nothing. Reported separately so the two cannot be
-- confused by a reader -- or by whoever increments them.
CisAuthority.anonymous = 0

-- Logged once per boot at most. The first one is information and the thousandth
-- is a flood: a resource that prints a line per forged event hands an attacker
-- a way to fill an operator's console, which is a denial of service wearing a
-- log line.
local warned = false

--- Is this a real player who is currently connected?
---
--- THE TWO CHECKS ARE NOT EQUAL, and which one is load-bearing matters.
---
--- `GetPlayerName(src) ~= nil` is the gate. It is verified behaviour: the
--- server-side binding is a client function with a null default, so a
--- disconnected source answers nil and only a connected one answers a string.
---
--- `GetMaxPlayers()` is a REFINEMENT, not the gate -- and it is deliberately
--- not required. It could not be verified to exist on every build, and a check
--- that raises turns every event handler in this resource into a crash. So it
--- is probed, and its absence costs a bounds check rather than correctness.
---
--- The order is chosen so that the one check that is certain runs first on the
--- common path, and so that a failure anywhere FAILS CLOSED. An error here must
--- answer "not a player": the other answer is to treat an unknown sender as
--- trusted, which is the one thing this file exists to prevent.
---
--- `source` itself is handled by the `type(value) ~= 'number'` guard above it,
--- and that guard is doing more work than it looks. The runtime sets `source`
--- to the player id for a net event, to a number for an internal-net event,
--- and to an EMPTY STRING for a server-side TriggerEvent -- not 0 and not nil.
--- A string source therefore fails the type check, lands on the server-side
--- branch of resolveSource, and has its payload believed. That is the intended
--- answer for a framework calling its own event.
function CisAuthority.isPlayer(value)
    if type(value) ~= 'number' then
        return false
    end
    if value <= 0 then
        return false
    end

    local named
    local ok = pcall(function()
        named = GetPlayerName(value)
    end)
    if not ok or named == nil then
        return false
    end

    local gotMax, max = pcall(GetMaxPlayers)
    if gotMax and type(max) == 'number' and max > 0 and value > max then
        return false
    end

    return true
end

--- Resolve who an event is really about.
---
--- @param payloadSource  whatever the payload claimed, of any type
--- @param eventName      string, for the log line
--- @return number|nil src   the source to act on; nil means "do nothing"
function CisAuthority.resolveSource(payloadSource, eventName)
    -- FiveM exposes the sender as a global inside the handler, and it is 0 for
    -- a server-side trigger. Read through a local because `source` is also the
    -- name of one of this resource's own helpers elsewhere, and a shadowed
    -- global read is exactly the kind of thing that survives a rename.
    local netSource = source

    if not CisAuthority.isPlayer(netSource) then
        -- Server-side trigger. The framework called its own event, its payload
        -- is real, and there is nobody else it could have been about.
        if CisAuthority.isPlayer(payloadSource) then
            return payloadSource
        end
        return nil
    end

    -- Networked trigger. The payload may name nobody but the sender.
    if payloadSource == netSource then
        return netSource
    end

    -- TWO COUNTS, AND THE DISTINCTION IS THE WHOLE POINT.
    --
    -- A client that sends the event with NO source at all is not forging
    -- anything -- it sent nothing -- and the answer is still correct: it gets
    -- its own source back. Counting that as a forgery made the one number
    -- meant to detect a cheat menu forgeable by anyone:
    --
    --     TriggerServerEvent('QBCore:Server:PlayerLoaded')   -- zero bytes
    --
    -- is enough to drive it up, and cis_core_doctor then told an operator
    -- "N spoofed event source(s) refused -- a client sent an event naming
    -- somebody else's source". Nothing was named. Nothing was refused. The
    -- operator's only correct response was to stop believing the counter.
    --
    -- So: a NUMBER that is not the sender is a forgery and is counted as one.
    -- Anything else is an event sent with nothing, counted separately, and is
    -- not evidence of anything.
    if type(payloadSource) == 'number' then
        CisAuthority.spoofed = CisAuthority.spoofed + 1
        if not warned then
            warned = true
            print(('[cis_core] refused a forged event source on %s: the network says %d, the payload named %d. '
                .. 'Acting as the network says. This line prints once; the count is in cis_core_doctor.')
                :format(tostring(eventName), netSource, payloadSource))
        end
    else
        CisAuthority.anonymous = CisAuthority.anonymous + 1
    end
    return netSource
end

return CisAuthority