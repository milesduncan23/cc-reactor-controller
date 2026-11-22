-- Install or update the Insanite factory plugin on a reactor controller computer.
-- Run AFTER the core controller is installed:
--
--   wget run https://raw.githubusercontent.com/milesduncan23/cc-reactor-controller/main/install-insanite.lua [owner] [repo] [branch]
--
-- Only touches /src/plugins/insanite/*. Creates a starter /insanite.conf if none exists and
-- never overwrites an existing one. Remove the plugin with: delete /src/plugins/insanite

local args = { ... }
local OWNER = args[1] or "milesduncan23"
local REPO = args[2] or "cc-reactor-controller"
local BRANCH = args[3] or "main"
local RAW_BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, BRANCH)
local TEMP = "/.insanite-install.tmp"

local FILES = {
    "src/plugins/insanite/config.lua",
    "src/plugins/insanite/planner.lua",
    "src/plugins/insanite/factory.lua",
    "src/plugins/insanite/hook.lua",
    "src/plugins/insanite/rods.lua",
}

local STARTER_CONF = [[
{
  -- Insanite factory plugin overrides. Only keys you set here change; see
  -- src/plugins/insanite/config.lua for every option.

  -- monitor = "monitor_2",   -- dedicate a monitor to the factory status screen

  -- Control rods follow the waste production speed the factory needs. Per reactor:
  --   rodControl = "waste"        burn only as fast as the factory needs (energy ignored)
  --   rodControl = "waste+power"  same, but never slower than energy demand asks for
  --   rodControl = "power"        original energy-demand control
  -- Defaults: reactors 5 and 7 "waste", reactors 6 and 8 "waste+power".

  reactors = {
    -- Attach a wired modem to each reactor's ports, right-click it, and paste the names from
    -- chat. inlet = the port in INLET mode (required to feed fuel); outlet = optional port the
    -- plugin should empty into ME (leave out if pipes/AE2 already do that).
    ["BigReactors-Reactor_6"] = { -- yellorium -> cyanite ingots (Solid Access Ports)
      -- inlet = "bigreactors:reinforced_reactorsolidaccessport_0",
    },
    ["BigReactors-Reactor_8"] = { -- yellorium -> cyanite fluid (Fuel Injection Port, outlet mode)
      -- inlet = "bigreactors:reinforced_reactorsolidaccessport_1",
    },
    ["BigReactors-Reactor_5"] = { -- blutonium -> magentite fluid (Fuel Injection Port, outlet mode)
      -- inlet = "bigreactors:reinforced_reactorsolidaccessport_2",
    },
    ["BigReactors-Reactor_7"] = { -- verderium (fluid) -> rossinite fluid (Fuel Injection Ports)
      -- inlet = "bigreactors:reinforced_reactorfluidaccessport_0",
    },
  },
}
]]

local function get(url)
    local response, err = http.get(url)
    if not response then error("HTTP failed for " .. url .. ": " .. tostring(err)) end
    local body = response.readAll()
    response.close()
    return body
end

local function writeFile(path, body)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "w")
    f.write(body)
    f.close()
end

print("Installing Insanite plugin from " .. OWNER .. "/" .. REPO .. " (" .. BRANCH .. ")")

-- Download and syntax-check everything before replacing anything.
local bodies = {}
for _, path in ipairs(FILES) do
    local body = get(RAW_BASE .. path)
    writeFile(TEMP, body)
    local fn, err = loadfile(TEMP)
    fs.delete(TEMP)
    if not fn then error("Syntax check failed for " .. path .. ": " .. tostring(err)) end
    bodies[path] = body
end

for i, path in ipairs(FILES) do
    writeFile("/" .. path, bodies[path])
    print(("[%d/%d] %s"):format(i, #FILES, path))
end

if not fs.exists("/insanite.conf") then
    writeFile("/insanite.conf", STARTER_CONF)
    print("Created /insanite.conf - edit it to set your reactor port names.")
else
    print("Kept existing /insanite.conf")
end

print("Done. Reboot to start the plugin with the controller.")
