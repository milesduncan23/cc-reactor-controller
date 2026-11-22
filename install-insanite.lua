-- Install or update the Insanite factory plugin on a reactor controller computer.
-- Run AFTER the core controller is installed:
--
--   wget run https://raw.githubusercontent.com/milesduncan23/cc-reactor-controller/main/install-insanite.lua [owner] [repo] [branch]
--
-- Installs /src/plugins/insanite/*. The plant config (/insanite.conf: every device the plugin
-- uses) comes from insanite.conf in the repo:
--   * no /insanite.conf yet         -> it is created from the repo copy
--   * an old-style /insanite.conf   -> (tuning overrides only, no devices) it is saved as
--                                      /insanite.conf.old and replaced by the repo copy
--   * a /insanite.conf with devices -> kept as it is
-- Afterwards the config is checked against the devices on the network and any problem is
-- listed. Remove the plugin with: delete /src/plugins/insanite

local args = { ... }
local OWNER = args[1] or "milesduncan23"
local REPO = args[2] or "cc-reactor-controller"
local BRANCH = args[3] or "main"
local RAW_BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(OWNER, REPO, BRANCH)
local TEMP = "/.insanite-install.tmp"
local PLANT_PATH = "/insanite.conf"

local FILES = {
    "src/plugins/insanite/config.lua",
    "src/plugins/insanite/planner.lua",
    "src/plugins/insanite/factory.lua",
    "src/plugins/insanite/hook.lua",
    "src/plugins/insanite/rods.lua",
}
local PLANT_TEMPLATE = "insanite.conf"

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

local function readFile(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

local function parseTable(text)
    local fn = load("return " .. text, "=conf", "t", {})
    if not fn then return nil end
    local ok, value = pcall(fn)
    if ok and type(value) == "table" then return value end
    return nil
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
local template = get(RAW_BASE .. PLANT_TEMPLATE)
if not parseTable(template) then error("The repo's " .. PLANT_TEMPLATE .. " is not a valid config table") end

for i, path in ipairs(FILES) do
    writeFile("/" .. path, bodies[path])
    print(("[%d/%d] %s"):format(i, #FILES, path))
end

-- Plant config.
if not fs.exists(PLANT_PATH) then
    writeFile(PLANT_PATH, template)
    print("Created " .. PLANT_PATH .. " from the repo's " .. PLANT_TEMPLATE .. ".")
else
    local current = parseTable(readFile(PLANT_PATH) or "")
    local hasDevices = current and (current.bridge ~= nil or current.machines ~= nil or current.reactors ~= nil)
    -- A device file from before AE2 autocraft existed: reactor inlets, no autocraft section.
    local outdated = hasDevices and current.autocraft == nil
    if outdated then
        print("Your " .. PLANT_PATH .. " is from an older plugin version (no autocraft section;")
        print("reactor inlets are no longer used). Replace it with the repo copy?")
        print("The old file is kept as " .. PLANT_PATH .. ".old. (y/n)")
        local answer = string.lower(read() or "")
        if answer == "y" or answer == "yes" then
            if fs.exists(PLANT_PATH .. ".old") then fs.delete(PLANT_PATH .. ".old") end
            fs.move(PLANT_PATH, PLANT_PATH .. ".old")
            writeFile(PLANT_PATH, template)
            print("Replaced. Old file: " .. PLANT_PATH .. ".old")
        else
            print("Kept your " .. PLANT_PATH .. "; the check below lists what to change.")
        end
    elseif hasDevices then
        print("Kept your existing " .. PLANT_PATH .. ".")
    else
        if fs.exists(PLANT_PATH .. ".old") then fs.delete(PLANT_PATH .. ".old") end
        fs.move(PLANT_PATH, PLANT_PATH .. ".old")
        writeFile(PLANT_PATH, template)
        print("Your old " .. PLANT_PATH .. " had no device definitions; it is saved as " .. PLANT_PATH .. ".old")
        print("and " .. PLANT_PATH .. " now comes from the repo.")
        if current then
            local keys = {}
            for k in pairs(current) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            if #keys > 0 then
                print("Settings in the old file: " .. table.concat(keys, ", "))
                print("Copy any you still want into " .. PLANT_PATH .. " (edit " .. PLANT_PATH .. ").")
            end
        else
            print("(The old file couldn't be read as a table.)")
        end
    end
end

-- Check the config against the devices actually on the network.
print("")
print("Checking " .. PLANT_PATH .. " ...")
local ok, err = pcall(function()
    dofile("/src/plugins/insanite/config.lua")
    dofile("/src/plugins/insanite/planner.lua")
    dofile("/src/plugins/insanite/factory.lua")
    local _, errors, warnings = InsaniteFactory.checkPlant()
    if #errors == 0 and #warnings == 0 then
        print("Config OK: every device is defined and on the network.")
    else
        for _, line in ipairs(InsaniteFactory.formatProblems(errors, warnings)) do print(line) end
        if #errors > 0 then
            print(("%d problem(s): the plugin won't start until they're fixed (edit %s)."):format(#errors, PLANT_PATH))
        else
            print("Warnings only: the plugin will start.")
        end
    end
end)
if not ok then print("Could not run the config check: " .. tostring(err)) end

print("")
print("Done. Reboot to start the plugin with the controller.")
