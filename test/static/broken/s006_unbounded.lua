-- Broken on purpose: a loop with no Wait anywhere in its body.
--
-- The thread never yields, so the scheduler cannot run anything else on it. The
-- resource keeps answering "started" and stops responding to anything.
CreateThread(function()
    while true do
        local n = compute()
        store(n)
    end
end)
return compute
