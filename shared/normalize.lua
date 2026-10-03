-- =============================================================================
--  cis_core -- shape normalisation, shared by both realms  (PURE)
--
--  WHY THIS FILE EXISTS
--
--  framework_client.lua carries this in its own header, and it is worth reading
--  twice:
--
--      "IT USED TO BE A MIRROR OF EVERYTHING EXCEPT THE DETECTION, and the
--       difference was a live bug rather than a style choice... There was no
--       test over this file at all, which is how a divergence survives for
--       years."
--
--  The divergence survived because the interesting parts of this resource are
--  adapters -- branches on which framework is running, on which third-party
--  export answers, on which of two field names a given inventory uses -- and an
--  adapter looks untestable. That is half true. The ADAPTER is untestable
--  without a server, but the decision inside it is not: "which field is this
--  inventory's item name", "is this payload the job itself or a wrapper around
--  it", "is this money type an account or an item" are pure functions, they were
--  written inline, and nothing could reach them.
--
--  So they are here now, in one file, in both realms, with tests over each one.
--
--  EVERY FUNCTION HERE IS TOTAL. It takes any value at all -- nil, a string, a
--  number, a table of the wrong shape -- and answers. None of them raises and
--  none of them indexes a value without checking what it is. These run on
--  framework data and third-party inventory data, both of which are outside this
--  project's control and both of which have shipped shapes nobody predicted.
-- =============================================================================

CisNormalize = {}

--- An inventory entry's name and amount, or nil when it is not an entry.
---
--- Both conventions are in the wild and neither is going away: ox_inventory,
--- QBCore and qs-inventory write `name`, codem-inventory and the ESX ecosystem
--- write `item` or `name` interchangeably, and the amount field is `count` on
--- some builds and `amount` on others. A consumer that picked one convention
--- works on the install it was written on and nowhere else.
---
--- `entry.name or entry.item` resolves that, and resolves it the SAME WAY as the
--- snapshot function already did -- which is the point. The counter used to test
--- `entry.name == item or entry.item == item` while the snapshot used
--- `entry.name or entry.item`, so an entry carrying both fields set to different
--- values counted for one item and appeared in the other's snapshot. Two
--- functions in the same file, one item, two answers.
---
--- An entry with neither name convention counts as 1 rather than 0. That is
--- deliberate: an unrecognised shape should read as "has some" rather than "has
--- none", because "has none" is the answer that removes a player's only key.
--- @return string|nil name, number|nil amount
function CisNormalize.itemEntry(entry)
    if type(entry) ~= 'table' then
        return nil, nil
    end
    local name = entry.name or entry.item
    if type(name) ~= 'string' or name == '' then
        return nil, nil
    end
    -- `or` and not a sum: an entry with `amount = 0` must read as zero, and
    -- `0 or 1` is 0 in Lua but `if not entry.amount then` would be 1. The
    -- difference is an item that is present with zero of it, which is a real
    -- state in every one of these inventories.
    local amount = entry.amount or entry.count or 1
    if type(amount) ~= 'number' then
        amount = 1
    end
    return name, amount
end

--- Flatten an inventory into `{ [name] = total }`.
---
--- The one shape every consumer reads. Nobody iterates a per-resource inventory
--- themselves, which is the entire reason this file exists -- that is what keeps
--- the entry shapes out of every companion resource.
--- @param list table|nil  entries of any shape
--- @return table snapshot  always a table, possibly empty
function CisNormalize.itemSnapshot(list)
    local out = {}
    if type(list) ~= 'table' then
        return out
    end
    for _, entry in pairs(list) do
        local name, amount = CisNormalize.itemEntry(entry)
        if name then
            out[name] = (out[name] or 0) + amount
        end
    end
    return out
end

--- Sum one item's amount across an inventory. 0, never nil.
---
--- 0 rather than nil because every caller compares with `>=`, and a nil here
--- raises inside the comparison instead of reading as "does not have it".
function CisNormalize.itemCount(list, item)
    local total = 0
    if type(list) ~= 'table' then
        return total
    end
    for _, entry in pairs(list) do
        local name, amount = CisNormalize.itemEntry(entry)
        if name == item then
            total = total + amount
        end
    end
    return total
end

--- The job out of any of the payloads the frameworks fire.
---
--- Five shapes are in use and none of them is a superset of another:
---
---   esx:setJob(job, lastJob)                    -> the job itself
---   QBCore:Client:OnJobUpdate(job)              -> the job itself
---   qbx_core:client:onJobUpdate(job)            -> the job itself
---   esx:playerLoaded(playerData, isNew, skin)   -> playerData, job under .job
---   QBCore:Client:OnPlayerLoaded(playerData)     -> playerData, job under .job
---   qbx_core:client:playerLoaded(playerData)     -> playerData, job under .job
---
--- Taking only the first shape would make every playerLoaded event a no-op, and
--- taking only the second would make every setJob event one. That is not a
--- hypothetical: both were live bugs here, in the same file, at different times.
---
--- `.job` is checked BEFORE the payload itself, and the order is load-bearing.
--- A qbx_core playerData carries a character `name` field alongside its `job`,
--- so a payload can match BOTH shapes at once. Tested the other way round --
--- `data.name and data or data.job` -- such a payload resolves to the whole
--- playerData, whose `.name` is the character's, and the job is dropped: the
--- client keeps a stale job and nothing anywhere reports it. That is the shape
--- qbx_core actually sends, so this is not a hypothetical ordering.
---
--- A bare job table has no `.job` field, so it falls through to the second
--- check and is returned as itself.
--- @return table|nil job
function CisNormalize.jobFromPayload(data)
    if type(data) ~= 'table' then
        return nil
    end
    -- The wrapper shape: the job is nested, and it has a name of its own.
    local nested = data.job
    if type(nested) == 'table' and type(nested.name) == 'string' and nested.name ~= '' then
        return nested
    end
    -- The bare shape: this table IS the job.
    if type(data.name) == 'string' and data.name ~= '' then
        return data
    end
    return nil
end

--- Is this money type an ACCOUNT, or an item every framework happens to carry?
---
--- `markedbills` is an inventory item on every framework this supports, not an
--- account. Handing it to AddMoney creates an account named markedbills that no
--- shop and no ATM knows how to spend, and the money appears to work -- balances
--- rise, the shop refuses -- which is the hardest kind of wrong to trace.
--- @return string route  'inventory' or 'account'
function CisNormalize.moneyRoute(account)
    if account == 'markedbills' then
        return 'inventory'
    end
    return 'account'
end

--- ESX's account LIST into the map every other framework already returns.
---
--- The SQL frameworks hand back a money table and ESX hands back a list of
--- `{ name, money }`. Collapsing them to a common currency would mean picking
--- one and losing what the other carries, so this maps the list and stops
--- there: a consumer that needs a number asks for the account it wants.
function CisNormalize.accountMap(accounts)
    local out = {}
    if type(accounts) ~= 'table' then
        return out
    end
    for _, account in ipairs(accounts) do
        if type(account) == 'table' and type(account.name) == 'string' then
            out[account.name] = account.money
        end
    end
    return out
end

--- A character name, or nil.
---
--- The name is a JOIN, not a field read. A framework that stores neither a
--- charinfo nor a getName yields nil rather than "", so a consumer can tell "no
--- name" from "the name is blank" -- which matters, because a blank name is
--- something to fix and a missing one is something to tolerate.
--- @return string|nil
function CisNormalize.personName(first, last)
    if type(first) ~= 'string' and type(last) ~= 'string' then
        return nil
    end
    local joined = ((type(first) == 'string' and first or '') .. ' '
        .. (type(last) == 'string' and last or ''))
    local trimmed = joined:gsub('^%s+', ''):gsub('%s+$', '')
    if trimmed == '' then
        return nil
    end
    return trimmed
end

return CisNormalize