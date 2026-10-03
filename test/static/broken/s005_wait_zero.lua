-- Broken on purpose: a Wait(0) loop.
--
-- Valid Lua, and it burns a slice of every frame on every client for the life
-- of the server. Nothing in a boot log mentions it, and resmon shows one thread
-- that never idles.
CreateThread(function()
    while true do
        Wait(0)
        DoSomething()
    end
end)
return DoSomething
