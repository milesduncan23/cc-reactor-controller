-- Insanite factory plugin: attach to the core controller without editing any core file.
--
-- src/scripts/main.lua runs every file under src/ (sorted), then calls the global main()
-- defined by src/scripts/controller.lua. "src/plugins/..." sorts before "src/scripts/...", so
-- main() does not exist yet when this file runs. Instead of depending on load order, this
-- watches _G for the moment controller.lua assigns main and wraps it so the factory runs as
-- a second coroutine beside the core loop:
--
--   parallel.waitForAll(coreMain, InsaniteFactory.runForever)
--
-- waitForAll (not waitForAny): if the plugin ever returns, the core keeps running.
-- The watcher removes itself right after wrapping main.

local function wrap(coreMain)
    return function(...)
        local args = table.pack(...)
        local function core()
            return coreMain(table.unpack(args, 1, args.n))
        end
        if not _G.InsaniteFactory then
            return core()
        end
        parallel.waitForAll(core, _G.InsaniteFactory.runForever)
    end
end

local existing = rawget(_G, "main")
if type(existing) == "function" then
    -- Loaded after controller.lua (e.g. the plugin was moved): wrap directly.
    _G.main = wrap(existing)
else
    local meta = getmetatable(_G)
    local createdMeta = meta == nil
    meta = meta or {}
    local previous = meta.__newindex

    meta.__newindex = function(t, key, value)
        if key == "main" and type(value) == "function" then
            value = wrap(value)
            -- Uninstall the watcher; everything after this is plain assignment again.
            meta.__newindex = previous
            if createdMeta and next(meta) == nil then setmetatable(t, nil) end
        end
        if type(previous) == "function" then
            previous(t, key, value)
        elseif type(previous) == "table" then
            previous[key] = value
        else
            rawset(t, key, value)
        end
    end
    setmetatable(_G, meta)
end
