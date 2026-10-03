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
CisAuthority.spoofed = 0

-- Logged once per boot at most. The first one is information and the thousandth
-- is a flood: a resource that prints a line per forged event hands an attacker
-- a way to fill an operator's console, which is a denial of service wearing a
-- log line.
local warned = false

--- Is this a real player who is currently connected?
---
--- The bounds check is not decoration. `source` is set by the runtime, but the
--- helpers below are also fed payload values, and a payload is any type at all
--- -- including a table, a string, and a number far larger than the server has
--- slots.
function CisAuthority.isPlayer(value)
    if type(value) ~= 'number' then
        return false
    end
    if value <= 0 or value > GetMaxPlayers() then
        return false
    end
    return GetPlayerName(value) ~= nil
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

    CisAuthority.spoofed = CisAuthority.spoofed + 1
    if not warned then
        warned = true
        print(('[cis_core] refused a spoofed event source on %s: the network says %d, the payload said %s. '
            .. 'Acting as the network says. This line prints once; the count is in cis_core_doctor.')
            :format(tostring(eventName), netSource, tostring(payloadSource)))
    end
    return netSource
end

return CisAuthority