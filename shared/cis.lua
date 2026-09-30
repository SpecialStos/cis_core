-- The seam between this resource and cis_libs.
--
-- Two different problems, one file, because both are "how do I read something
-- that lives in another resource's Lua state" and solving them in two places
-- guarantees they drift.
--
-- SERVER: `Config` and `Security` are globals in THIS resource, set by the two
-- files in configs/. They are pushed across to cis_libs at boot and cis_libs
-- keeps its own copy; from here on, the authoritative copy for this resource is
-- the local one, because that is the file the operator edits.
--
-- CLIENT: there is no config file and no global. The server's redacted payload
-- lives in cis_libs's client state, and the only way to read it is the
-- `GetClientConfig` export. That call yields for readiness, so it is made ONCE
-- and cached -- a per-frame read of a config from another resource's export is
-- a crossing per frame for a value that cannot change mid-session.
--
-- What a client is told is a whitelist, so there is no webhook URL, no database
-- block and no allow-list here. That is a security property of the redaction,
-- not an oversight, and `GetClientConfig` returning nil is a legitimate answer
-- rather than a failure.

CoreLibs = {}

local clientConfigCache = nil

--- The redacted config this client was given, or an empty table.
---
--- Returns a table ALWAYS, so a caller can index it without a guard. An empty
--- table and a real one behave identically under `cfg.Framework or {}`, which
--- is how every call site here is written -- a nil that has to be checked at
--- each use is a nil that will be forgotten at one of them.
function CoreLibs.clientConfig()
    if clientConfigCache then
        return clientConfigCache
    end
    local ok, cfg = pcall(function()
        return exports['cis_libs']:GetClientConfig()
    end)
    clientConfigCache = (ok and type(cfg) == 'table') and cfg or {}
    return clientConfigCache
end

--- Drop the cache. Called when the payload arrives, so a config that arrives
--- after first read is not shadowed by the empty table read before it.
function CoreLibs.invalidateClientConfig()
    clientConfigCache = nil
end

--- The framework block of the client config, or {}.
function CoreLibs.clientFramework()
    return CoreLibs.clientConfig().Framework or {}
end

-- Server-side convenience, so a caller in this resource never has to remember
-- which of the two shapes it is in.
function CoreLibs.config()
    if IsDuplicityVersion() then
        return Config
    end
    return CoreLibs.clientConfig()
end
