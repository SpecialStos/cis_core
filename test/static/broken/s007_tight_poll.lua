-- Broken on purpose: a 5ms poll.
--
-- Five times tighter than the floor, for a wait that is really a resource
-- starting -- something that resolves in seconds. Indistinguishable to a player
-- and ten times the scheduler cost.
CreateThread(function()
    while not ready() do
        Wait(5)
    end
end)
return ready
