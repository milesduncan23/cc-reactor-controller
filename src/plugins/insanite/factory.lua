-- Insanite factory plugin: runtime.
--
-- Every cycleSeconds: empty configured output ports into ME, read ME stock + machine/reactor
-- state, set the locked reactor burn rates (InsanitePlanner.rateTargets -> InsaniteRods), ask
-- InsanitePlanner what to dose, then move items/fluids through the ME Bridge.
-- No AE2 autocrafting is used: the plugin only stocks ME; crafting the blocks is up to you.
--
-- Batch machines (reprocessor, fluidizer) run ONE recipe at a time. The plugin only loads a
-- recipe into an empty machine and always loads whole operations (e.g. exactly 2 items per
-- 1000 mB), so the machine drains completely and the next recipe never mixes with leftovers.
-- If a load comes up short, or contents sit unchanged for stallSeconds, the short input is
-- topped up to a whole number of operations (nothing is ever pulled back out).
--
-- Two stop buttons (top row of the status monitor), each on its own:
--   reactors: "ratio" reactors (R5 + R7) held at 100% rods; "stock" reactors (R6 + R8) keep running.
--   machines: nothing loaded into the batch machines (not even stall top-ups) and no AE2 crafts.
-- Both survive reboots (pauseFile).
--
-- Runs beside the core controller (see hook.lua). Every peripheral call is pcall-guarded and
-- a failed cycle is logged and retried, so a plugin fault cannot stop reactor control.

local Factory = {}

local cfg, model, need, opsPerBlock
local plantRate = 0          -- Insanite Blocks per tick the rod targets are sized for
local rateTargets = {}       -- reactorId -> burn target mB/t (rod control)
local rateDetail = nil       -- last InsanitePlanner.rateTargets detail (plant rate, limit, trims)
local stockState = {}        -- stock pools' on/off (hysteresis) state, kept between cycles
local machineState = {}      -- machineName -> { process, ops, busy, sig, changedAt, stalled, contents }
local reactorInfo = {}       -- reactorId -> last stats
local lastEject = {}         -- reactorId -> clock
local lastNotes, lastActions = {}, {}
local lastStock, lastProjected = {}, {}
local blocksInMe = nil       -- finished blocks (cfg.blockCraft) in ME, for the status screen
local machineLoad = {}       -- machineName -> recent samples { t, limited, waiting = { processId... } }
local machineRuns = {}       -- machineName -> recent batches { t0, ops, tEnd }
local craftFailures = {}     -- craft output -> { count, err }: AE2 refusals in a row
local opSecondsLearned = {}  -- machineName -> seconds per operation, measured (when the mod's isn't known)
local events = {}
local cycleCount = 0
local lastError = nil
local bootMessage = nil
local plantWarnings = {}     -- non-fatal plant config problems, shown on the status screen
local stopped = { reactors = false, machines = false } -- the two stop buttons
local heldReactors = {}      -- reactorId -> true: what the reactor stop holds fully inserted
local buttonAt = {}          -- drawn buttons: { key, y, x1, x2 }
local lastTap = {}           -- button key -> clock of its last toggle (debounce)

local unpack = table.unpack or unpack

local function now() return os.clock() end

local function splitLines(text)
    local out = {}
    for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    return out
end

local function shortId(id)
    return (tostring(id):gsub("BigReactors%-Reactor_", "R"))
end

local function event(fmt, ...)
    local text = string.format(fmt, ...)
    events[#events + 1] = string.format("[%6.0f] %s", now(), text)
    while #events > 8 do table.remove(events, 1) end
end

--region config

local function deepMerge(base, over)
    if type(over) ~= "table" or type(base) ~= "table" then return over end
    if #over > 0 then return over end -- lists replace wholesale
    local out = {}
    for k, v in pairs(base) do out[k] = v end
    for k, v in pairs(over) do
        if v == false and type(base[k]) == "table" then
            out[k] = nil
        else
            out[k] = deepMerge(base[k], v)
        end
    end
    return out
end
Factory.deepMerge = deepMerge

local function readTableFile(path)
    if not path or not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    local data = textutils.unserialise(text)
    if type(data) ~= "table" then
        return nil, "could not parse " .. path
    end
    return data
end

local function writeTableFile(path, data)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "w")
    if not f then return end
    f.write(textutils.serialize(data))
    f.close()
end

local PLANT_TEMPLATE_HINT = "Get the template with:   wget run "
    .. "https://raw.githubusercontent.com/milesduncan23/cc-reactor-controller/main/install-insanite.lua"
    .. "   (it creates /insanite.conf), or copy insanite.conf from the repo."

-- Read the plant config. Returns the table, or nil + a precise problem message (missing file,
-- syntax error with its line number, or not a table).
local function loadPlant(path)
    if not fs.exists(path) then
        return nil, path .. " not found. It must define every device the plugin uses (ME Bridge, monitor, "
            .. "machine ports, reactors).\n   " .. PLANT_TEMPLATE_HINT
    end
    local f = fs.open(path, "r")
    if not f then return nil, path .. " exists but can't be opened." end
    local text = f.readAll()
    f.close()
    -- "return " goes on the file's first line, so error line numbers match the file.
    local fn, syntaxErr = load("return " .. text, "=" .. path, "t", {})
    if not fn then
        return nil, path .. " has a syntax error: " .. tostring(syntaxErr) .. "\n   "
            .. "Usually a missing comma after an entry, a missing closing } or \", or text outside the outer { }."
    end
    local ok, value = pcall(fn)
    if not ok then return nil, path .. " could not be read: " .. tostring(value) end
    if type(value) ~= "table" then
        return nil, path .. " must contain one table { ... }, but it contains " .. type(value) .. "."
    end
    return value
end

-- Every peripheral on the network and all its types (generic peripherals report several).
local function scanNetwork()
    local net = {}
    local ok, names = pcall(peripheral.getNames)
    if not ok then return nil end
    for _, name in ipairs(names or {}) do
        local types = { peripheral.getType(name) }
        if type(types[1]) == "table" then types = types[1] end
        net[name] = types
    end
    return net
end

-- Load and check the plant config. Returns plant, errors, warnings.
function Factory.checkPlant()
    local path = _G.INSANITE_DEFAULTS.plantFile
    local plant, problem = loadPlant(path)
    if not plant then return nil, { problem }, {} end
    local errors, warnings = InsanitePlanner.validatePlant(plant, _G.INSANITE_DEFAULTS, scanNetwork())
    return plant, errors, warnings
end

-- Numbered, human-readable list of plant config problems.
function Factory.formatProblems(errors, warnings)
    local lines = {}
    for i, e in ipairs(errors or {}) do lines[#lines + 1] = string.format("PROBLEM %d: %s", i, e) end
    for i, w in ipairs(warnings or {}) do lines[#lines + 1] = string.format("WARNING %d: %s", i, w) end
    return lines
end

--endregion

--region peripherals

local function wrap(name)
    if not name then return nil end
    local ok, p = pcall(peripheral.wrap, name)
    if ok then return p end
    return nil
end

-- Call a peripheral method; returns its results, or nil + error string.
local function call(name, method, ...)
    local p = wrap(name)
    if not p then return nil, "missing peripheral " .. tostring(name) end
    if type(p[method]) ~= "function" then return nil, tostring(name) .. " has no " .. method end
    local res = table.pack(pcall(p[method], ...))
    if not res[1] then return nil, tostring(res[2]) end
    return unpack(res, 2, res.n)
end

local function meAmount(def)
    local t
    if def.kind == "fluid" then
        t = call(cfg.bridge, "getFluid", { name = def.id })
    else
        t = call(cfg.bridge, "getItem", { name = def.id })
    end
    if type(t) ~= "table" then return 0 end
    return tonumber(t.amount or t.count) or 0
end

-- ME -> target peripheral. Returns amount moved.
local function exportTo(def, target, qty)
    if not target or qty <= 0 then return 0 end
    local moved
    if def.kind == "fluid" then
        moved = call(cfg.bridge, "exportFluid", target, { name = def.id, amount = qty })
    else
        moved = call(cfg.bridge, "exportItem", target, { name = def.id, count = qty })
    end
    return tonumber(moved) or 0
end

-- source peripheral -> ME. Returns amount moved.
local function importFrom(def, source)
    if not source then return 0 end
    local moved
    if def.kind == "fluid" then
        moved = call(cfg.bridge, "importFluid", source, { name = def.id, amount = 64000 })
    else
        moved = call(cfg.bridge, "importItem", source, { name = def.id, count = 4096 })
    end
    return tonumber(moved) or 0
end

-- Contents of an injector/port: { [gameId] = amount }, or nil if the peripheral is missing.
local function portContents(name)
    local p = wrap(name)
    if not p then return nil end
    local out = {}
    if type(p.list) == "function" then
        local ok, list = pcall(p.list)
        if not ok then return nil end
        for _, stack in pairs(list or {}) do
            if stack.name and (stack.count or 0) > 0 then
                out[stack.name] = (out[stack.name] or 0) + stack.count
            end
        end
    end
    if type(p.tanks) == "function" then
        local ok, tanks = pcall(p.tanks)
        if not ok then return nil end
        for _, tank in pairs(tanks or {}) do
            if tank.name and tank.name ~= "minecraft:empty" and (tank.amount or 0) > 0 then
                out[tank.name] = (out[tank.name] or 0) + tank.amount
            end
        end
    end
    return out
end

--endregion

--region machines

-- Seconds per operation: the mod's constant (opsPerTick) when known, else learned from how long
-- this machine's batches took (the shortest per-operation time seen; finishing is only noticed at
-- the next cycle, so longer readings are mostly that delay).
local function opSeconds(name)
    local m = (cfg.machines or {})[name]
    if m and m.opsPerTick and m.opsPerTick > 0 then return 1 / m.opsPerTick / 20 end
    return opSecondsLearned[name]
end

local function runStarted(name, ops)
    local runs = machineRuns[name] or {}
    machineRuns[name] = runs
    runs[#runs + 1] = { t0 = now(), ops = ops }
end

local function runFinished(name)
    local runs = machineRuns[name]
    local r = runs and runs[#runs]
    if not r or r.tEnd then return end
    r.tEnd = now()
    if r.ops > 0 and not ((cfg.machines or {})[name] or {}).opsPerTick then
        local per = (r.tEnd - r.t0) / r.ops
        if per > 0 and (opSecondsLearned[name] == nil or per < opSecondsLearned[name]) then
            opSecondsLearned[name] = per
        end
    end
end

local function processesFor(machineName)
    local list = {}
    for _, p in ipairs(model.processes) do
        if p.machine == machineName then list[#list + 1] = p end
    end
    return list
end

local function amountIn(contents, inp)
    local def = cfg.resources[inp.res]
    local portContentsTable = contents[inp.port] or {}
    return portContentsTable[def.id] or 0
end

-- Which recipe do these contents belong to? Every item/fluid present must be an input of the
-- recipe on the port it sits in. Prefers the remembered recipe when it still fits.
local function inferProcess(machineName, contents, remembered)
    local function fits(p)
        for port, items in pairs(contents) do
            for id in pairs(items) do
                local ok = false
                for _, inp in ipairs(p.inputs) do
                    if inp.port == port and cfg.resources[inp.res].id == id then ok = true end
                end
                if not ok then return false end
            end
        end
        return true
    end
    if remembered and model.byId[remembered] and fits(model.byId[remembered]) then
        return remembered
    end
    for _, p in ipairs(processesFor(machineName)) do
        if fits(p) then return p.id end
    end
    return nil
end

-- Whole operations implied by the contents (largest over inputs, rounded up).
local function impliedOps(p, contents)
    local ops = 0
    for _, inp in ipairs(p.inputs) do
        ops = math.max(ops, math.ceil(amountIn(contents, inp) / inp.qty))
    end
    return ops
end

-- Top up every input to `ops` whole operations. Returns true if nothing is missing afterwards.
local function topUp(m, p, contents, ops)
    local complete = true
    for _, inp in ipairs(p.inputs) do
        local def = cfg.resources[inp.res]
        local missing = ops * inp.qty - amountIn(contents, inp)
        if missing > 0 then
            local moved = exportTo(def, m.ports[inp.port], missing)
            if moved < missing then complete = false end
        end
    end
    return complete
end

local function observeMachine(name, m)
    local st = machineState[name] or {}
    machineState[name] = st

    local contents, total, sig = {}, 0, {}
    for port, pname in pairs(m.ports or {}) do
        local c = portContents(pname)
        if c == nil then
            st.busy, st.offline, st.contents = true, pname, nil
            return st
        end
        contents[port] = c
        for id, amount in pairs(c) do
            total = total + amount
            sig[#sig + 1] = port .. ":" .. id .. "=" .. amount
        end
    end
    st.offline = nil
    st.contents = contents
    table.sort(sig)
    sig = table.concat(sig, ",")

    if total == 0 then
        if st.process then
            event("%s finished %s", name, st.process)
            runFinished(name)
        end
        st.process, st.ops, st.busy, st.stalled, st.foreign, st.sig = nil, nil, false, false, nil, ""
        return st
    end

    st.busy = true
    if st.sig ~= sig then
        st.sig, st.changedAt, st.stalled = sig, now(), false
    end
    st.process = inferProcess(name, contents, st.process)
    if st.process == nil and st.foreign ~= sig then
        event("%s holds items no recipe uses: %s (clear it by hand)", name, sig)
    end
    st.foreign = (st.process == nil) and sig or nil

    -- Contents unchanged for a whole stall window: top the short input up to whole operations.
    -- Retried once per window until the contents start moving again.
    local window = cfg.stallSeconds or 60
    if st.process and now() - (st.changedAt or now()) >= window then
        st.stalled = true
        if not stopped.machines and now() - (st.repairAt or -math.huge) >= window then
            st.repairAt = now()
            local p = model.byId[st.process]
            local ops = impliedOps(p, contents)
            if topUp(m, p, contents, ops) then
                event("%s stalled on %s; topped up to %d ops (check power/output if it persists)", name, st.process, ops)
            else
                event("%s stalled on %s; ME short of inputs", name, st.process)
            end
        end
    end
    return st
end

local function busyReason(st)
    if st.offline then return "port missing: " .. st.offline end
    if st.foreign then return "unknown contents" end
    if st.stalled then return "stalled on " .. tostring(st.process) end
    if st.busy then return "running " .. tostring(st.process) end
    return nil
end

-- Loads p into its (empty) machine. Returns the operations loaded, or 0 and the missing input.
local function runBatch(p, ops)
    local m = cfg.machines[p.machine]
    local st = machineState[p.machine] or {}
    machineState[p.machine] = st

    -- Re-read ME right before loading (an importer may have taken something since the cycle
    -- started): only whole operations that EVERY input is there for, or nothing at all.
    local spare, order = {}, {}
    for i, inp in ipairs(p.inputs) do
        spare[i] = math.floor(meAmount(cfg.resources[inp.res]) / inp.qty)
        order[i] = i
        if spare[i] < ops then ops = spare[i] end
    end
    if ops < 1 then
        local short = p.inputs[1].res
        for i, inp in ipairs(p.inputs) do if spare[i] < 1 then short = inp.res end end
        event("%s: %s not started, ME has no %s now", p.machine, p.id, short)
        return 0, short
    end

    -- Scarcest input first: it sets how many operations actually happen and the rest are sized
    -- to match, so if it can't be moved nothing has been loaded.
    table.sort(order, function(a, b)
        if spare[a] ~= spare[b] then return spare[a] < spare[b] end
        return a < b
    end)
    local moved, opsDone = {}, ops
    for n, i in ipairs(order) do
        local inp = p.inputs[i]
        moved[i] = exportTo(cfg.resources[inp.res], m.ports[inp.port], opsDone * inp.qty)
        if n == 1 then
            opsDone = math.ceil(moved[i] / inp.qty)
            if opsDone == 0 then
                event("%s: %s not started, could not load %s", p.machine, p.id, inp.res)
                return 0, inp.res
            end
        end
    end

    -- Make every input a whole number of operations.
    local contents = {}
    for i, inp in ipairs(p.inputs) do
        contents[inp.port] = contents[inp.port] or {}
        local id = cfg.resources[inp.res].id
        contents[inp.port][id] = (contents[inp.port][id] or 0) + moved[i]
    end
    local implied = impliedOps(p, contents)
    if not topUp(m, p, contents, implied) then
        event("%s: %s loaded short, will retry", p.machine, p.id)
    end

    st.process, st.ops, st.busy, st.stalled = p.id, implied, true, false
    st.sig, st.changedAt = nil, now()
    event("%s <- %s x%d", p.machine, p.id, implied)
    runStarted(p.machine, implied)
    return implied
end

--endregion

--region reactors

local function observeReactor(id, r)
    local info = { present = wrap(id) ~= nil }
    if info.present then
        local stats = call(id, "getFuelStats")
        if type(stats) == "table" then
            info.fuelAmount = tonumber(stats.fuelAmount) or 0
            info.fuelCapacity = tonumber(stats.fuelCapacity) or 0
            info.wasteAmount = tonumber(stats.wasteAmount) or 0
        else
            info.present = false
        end
    end
    reactorInfo[id] = info

    local pct = cfg.ejectWasteAbovePct or 0
    if info.present and pct > 0 and info.fuelCapacity > 0
        and info.wasteAmount / info.fuelCapacity * 100 > pct
        and now() - (lastEject[id] or -math.huge) > 30 then
        lastEject[id] = now()
        call(id, "doEjectWaste")
    end
    return info
end

--endregion

--region AE2 crafts (liquid cyanite and liquid magentite only)

local craftableCache = {}   -- res -> { value, at }

-- AE2's generic filters need the kind for fluids.
local function genericFilter(def)
    return { type = (def.kind == "fluid") and "fluid" or "item", name = def.id }
end

local function isCraftable(res)
    local cached = craftableCache[res]
    if cached and now() - cached.at < 60 then return cached.value end
    local value = call(cfg.bridge, "isCraftable", genericFilter(cfg.resources[res])) == true
    craftableCache[res] = { value = value, at = now() }
    return value
end

local function isCrafting(res)
    return call(cfg.bridge, "isCrafting", genericFilter(cfg.resources[res])) == true
end

local function requestCraft(p, ops)
    -- Second line of defence: never ask AE2 for anything outside the allowlist.
    if not InsanitePlanner.ALLOWED_CRAFTS[p.output] then
        event("refused AE2 craft of %s (not allowed)", tostring(p.output))
        return
    end
    local def = cfg.resources[p.output]
    local amount = ops * p.outQty
    local ok, err
    if def.kind == "fluid" then
        ok, err = call(cfg.bridge, "craftFluid", { name = def.id, amount = amount })
    else
        ok, err = call(cfg.bridge, "craftItem", { name = def.id, count = amount })
    end
    if ok then
        event("AE2 craft %s %s", def.kind == "fluid" and string.format("%.1fB", amount / 1000) or tostring(amount), p.output)
        craftFailures[p.output] = nil
        return true
    else
        -- AE2 said no (a missing pattern somewhere in the tree, or ingredients it can't make).
        -- Logged once; repeated refusals raise an alert (see buildAlerts).
        local f = craftFailures[p.output] or { count = 0 }
        craftFailures[p.output] = f
        f.count, f.err = f.count + 1, tostring(err)
        if f.count == 1 then event("AE2 craft %s refused: %s", p.output, f.err) end
        craftableCache[p.output] = nil
        return false
    end
end

--endregion

--region stop buttons (status monitor)

-- Reactors the reactor stop holds: every "ratio" reactor. "stock" reactors (R6 + R8) keep
-- running and "power" reactors stay on the core's energy control.
local function stoppableReactors()
    local out = {}
    for id, r in pairs(cfg.reactors or {}) do
        if r and (r.rodControl or "ratio") == "ratio" then out[id] = true end
    end
    return out
end

local function reactorList(mode)
    local ids = {}
    for id, r in pairs(cfg.reactors or {}) do
        if r and (r.rodControl or "ratio") == mode then ids[#ids + 1] = shortId(id) end
    end
    table.sort(ids)
    return #ids > 0 and table.concat(ids, "+") or "none"
end

-- Hand the hold to the rod law (and make sure the law is installed, even if the ME Bridge is
-- gone this cycle).
local function applyStops()
    heldReactors = stopped.reactors and stoppableReactors() or {}
    if _G.InsaniteRods then
        InsaniteRods.setHeld(heldReactors)
        if InsaniteRods.enabled() then InsaniteRods.install() end
    end
end

local STOP_LABEL = { reactors = "reactors", machines = "machines + AE2 crafts" }

local function setStopped(key, on, why)
    if STOP_LABEL[key] == nil then error("unknown stop button " .. tostring(key), 2) end
    stopped[key] = on == true
    if cfg.pauseFile then
        if stopped.reactors or stopped.machines then
            writeTableFile(cfg.pauseFile, { reactors = stopped.reactors, machines = stopped.machines })
        elseif fs.exists(cfg.pauseFile) then
            fs.delete(cfg.pauseFile)
        end
    end
    applyStops()
    local label = key == "reactors" and (reactorList("ratio") .. " reactors") or STOP_LABEL[key]
    event("%s %s (%s)", label, stopped[key] and "STOPPED" or "STARTED", why)
    print("Insanite: " .. label .. " " .. (stopped[key] and "STOPPED" or "STARTED") .. " (" .. why .. ")")
end

-- A tap on the status monitor. Each button toggles its own stop; a repeat tap on the same button
-- within a second is ignored (a held click can fire twice). Returns true if something toggled.
function Factory.touch(name, x, y)
    if not cfg or not cfg.monitor or name ~= cfg.monitor then return false end
    for _, b in ipairs(buttonAt) do
        if y == b.y and x >= b.x1 and x <= b.x2 then
            if lastTap[b.key] and now() - lastTap[b.key] < 1 then return false end
            lastTap[b.key] = now()
            setStopped(b.key, not stopped[b.key], "monitor button")
            return true
        end
    end
    return false
end
function Factory.setStopped(key, on) setStopped(key, on, "command") end
function Factory.stopped() return { reactors = stopped.reactors, machines = stopped.machines } end

--endregion

--region machine capacity

-- One sample per cycle per batch machine: was ready work waiting for it (InsanitePlanner.plan's
-- `waiting`)? Samples older than machineAlertSeconds are dropped. The machine button clears them.
local function sampleMachines(waiting)
    local window = cfg.machineAlertSeconds or 300
    local t = now()
    for name in pairs(cfg.machines or {}) do
        local list = machineLoad[name] or {}
        machineLoad[name] = list
        local w = (waiting or {})[name]
        list[#list + 1] = { t = t, limited = w ~= nil and #w > 0, waiting = w or {} }
        while #list > 0 and t - list[1].t > window do table.remove(list, 1) end
    end
end

-- Seconds of real work in the last `window` seconds: each batch counts its operations x the time
-- per operation, and never past the moment it was seen finished.
local function busySeconds(name, window)
    local t = now()
    local from = t - window
    local per = opSeconds(name)
    local runs = machineRuns[name] or {}
    while #runs > 0 and (runs[1].tEnd or t) < from do table.remove(runs, 1) end
    local total = 0
    for _, r in ipairs(runs) do
        local stop = r.tEnd or t
        if per then stop = math.min(stop, r.t0 + r.ops * per) end
        local a = math.max(r.t0, from)
        if stop > a then total = total + (stop - a) end
    end
    return total
end

-- How hard a machine works: busy % (real work over the window), % of cycles with ready work
-- waiting for it, whether the history covers (nearly) the whole window yet, and the recipes that
-- waited most often.
local function machinePressure(name)
    local list = machineLoad[name]
    if not list or #list == 0 then return nil end
    local limited, count = 0, {}
    for _, smp in ipairs(list) do
        if smp.limited then limited = limited + 1 end
        for _, pid in ipairs(smp.waiting) do count[pid] = (count[pid] or 0) + 1 end
    end
    local pids = {}
    for pid in pairs(count) do pids[#pids + 1] = pid end
    table.sort(pids, function(a, b) if count[a] ~= count[b] then return count[a] > count[b] end return a < b end)
    local window = cfg.machineAlertSeconds or 300
    local span = now() - list[1].t
    local covered = span >= 0.9 * window
    local busyPct = math.floor(100 * busySeconds(name, window) / math.max(1, math.min(window, span)) + 0.5)
    return math.min(100, busyPct), math.floor(100 * limited / #list + 0.5), covered, pids
end

-- Machines currently at capacity: { [name] = { busy, waiting } }.
local function machinesAtCapacity()
    local out = {}
    if stopped.machines then return out end
    for name in pairs(cfg.machines or {}) do
        local busy, waitPct, covered, pids = machinePressure(name)
        if busy and covered and busy >= (cfg.machineAlertPct or 75) and waitPct >= (cfg.machineBacklogPct or 50) then
            out[name] = { busy = busy, waiting = pids }
        end
    end
    return out
end

--endregion

--region alerts

local alerts = {}           -- key -> { text, since, lastSeen }
local alertOrder = {}       -- active alert keys, oldest first
local trackSince = {}       -- reactorId -> clock since its burn has been off its target
local slowSince = nil       -- clock since an overflow slowdown with no identified cause began
local deviation = { reactors = {} } -- last InsanitePlanner.deviations result

-- Plant-wide blockers: recipes waiting on a raw input (nothing here produces it) and batch
-- machines that can't run. An overflow slowdown is almost always waiting on one of these.
local function blockers(notes)
    local out = {}
    for _, p in ipairs(model.processes) do
        local res = (notes[p.id] or ""):match("^needs (%S+)")
        if res and InsanitePlanner.isRaw(model, res) then out[#out + 1] = p.id .. " needs " .. res end
        if notes[p.id] == "no AE2 pattern" then out[#out + 1] = p.id .. ": no AE2 pattern" end
    end
    for name, st in pairs(machineState) do
        if st.offline or st.foreign or st.stalled then out[#out + 1] = name .. " " .. busyReason(st) end
    end
    for name in pairs(machinesAtCapacity()) do out[#out + 1] = name .. " at capacity" end
    table.sort(out)
    return out
end

local function buildAlerts(notes)
    local found = {}
    local function add(key, text) found[#found + 1] = { key = key, text = text } end

    -- The plant running slower than the kit reserve asks for.
    local d = rateDetail
    local slowAt = 1 - (cfg.slowAlertPct or 25) / 100
    -- Hysteresis: once a slowdown alert is up, it holds until the plant is back within
    -- (slowAlertPct - 10)% of the asked pace, so it can't flicker around the threshold.
    local slowedNow = alerts["overflow"] ~= nil
    for key in pairs(alerts) do
        if key:find("^capacity:") then slowedNow = true end
    end
    if slowedNow then slowAt = math.min(1, slowAt + 0.10) end
    local causeless = false
    -- (no slowdown alerts while a stop button is on: the plant is held on purpose)
    if not stopped.reactors and not stopped.machines
        and d and d.unconstrained > 0 and d.rate < d.unconstrained * slowAt then
        local pct = math.floor(d.rate / d.unconstrained * 100 + 0.5)
        if d.limitKind == "overflow" then
            local cov = (d.pools[d.limitId] or {}).cov or 0
            local text = string.format("PLANT SLOWED to %d%%: %s piling up in ME (%.1f blk, target %g)",
                pct, cfg.resources[d.limitId].label or d.limitId, cov, cfg.stockBlocks or 2)
            local b = blockers(notes)
            if #b > 0 then
                -- A real blockage (raw input missing, machine broken): alert right away.
                add("overflow", text .. ". Blocked: " .. table.concat(b, ", "))
            else
                -- No cause found: usually downstream still catching up (e.g. right after start).
                -- Only alert if it lasts.
                causeless = true
                slowSince = slowSince or now()
                if now() - slowSince >= (cfg.slowAlertSeconds or 600) then
                    add("overflow", text .. ". No blocked recipe found; downstream too slow?")
                end
            end
        elseif d.limitKind == "capacity" then
            local pool = d.pools[d.limitId]
            local several = #pool.members > 1
            add("capacity:" .. d.limitId, string.format(
                "PLANT SLOWED to %d%%: %s at %s max burn (%.2f of %.2f mB/t needed for %s); other reactors matched",
                pct, pool.label, several and "their combined" or "its", pool.capacity or 0,
                d.unconstrained * pool.share * pool.trim, pool.waste))
        end
    end
    if not causeless then slowSince = nil end

    -- A reactor that has been off its own burn target for too long.
    local window = cfg.deviationAlertSeconds or 120
    local limit = (cfg.deviationAlertPct or 15) / 100
    for id, e in pairs(deviation.reactors) do
        local r = d and d.reactors[id]
        local floor = r and 0.1 * plantRate * r.share or 0
        local measuredBurn = e.measured or 0
        local off = (e.target and e.target > 0) and math.abs(measuredBurn - e.target) / math.max(e.target, floor) or 0
        if heldReactors[id] then
            trackSince[id] = nil -- stopped on purpose
        elseif e.stock then
            -- Stock reactors burn flat out by design; only an empty tank while filling is a fault.
            local pool = d and d.stockPools[r.pool]
            local info = reactorInfo[id] or {}
            if pool and pool.state == "filling" and info.present and (info.fuelAmount or 0) < 1000 then
                trackSince[id] = trackSince[id] or now()
                if now() - trackSince[id] >= window then
                    add("track:" .. id, string.format("%s out of fuel while filling %s to its cap (check its ME importer)",
                        shortId(id), pool.waste))
                end
            else
                trackSince[id] = nil
            end
        elseif e.tracking and off > limit then
            trackSince[id] = trackSince[id] or now()
            if now() - trackSince[id] >= window then
                local info = reactorInfo[id] or {}
                local rod = (_G.InsaniteRods and InsaniteRods.state(id)) or {}
                local why = ""
                if (info.fuelAmount or 0) < 1000 then
                    why = " - out of fuel (check its ME importer)"
                elseif e.tracking < 0 and (rod.level or 100) <= 1 then
                    why = " - rods fully out"
                elseif e.tracking > 0 and (rod.level or 0) >= 99 then
                    why = " - rods fully in"
                end
                add("track:" .. id, string.format("%s burning %d%% %s its target (%.2f of %.2f mB/t)%s",
                    shortId(id), math.floor(math.abs(e.tracking) * 100 + 0.5),
                    e.tracking < 0 and "below" or "above", measuredBurn, e.target, why))
            end
        else
            trackSince[id] = nil
        end
    end

    -- AE2 keeps refusing a craft the plugin asks for.
    local refused = {}
    for res in pairs(craftFailures) do refused[#refused + 1] = res end
    table.sort(refused)
    for _, res in ipairs(refused) do
        local f = craftFailures[res]
        if f.count >= (cfg.craftFailAlertCount or 3) then
            local def = cfg.resources[res] or {}
            local what = (res == cfg.blockCraft) and "its patterns (Insanite Block, Inanite Block, Netherite Block)"
                or "its pattern"
            add("craftfail:" .. res, string.format(
                "AE2 REFUSED the %s craft %d times in a row: %s. Check %s and that AE2 can make every ingredient.",
                def.label or res, f.count, f.err, what))
        end
    end

    -- Kit full but the finished block can't be crafted: the plant would just sit there.
    local blockRes = cfg.blockCraft
    local blockNote = blockRes and notes["craft " .. blockRes]
    if blockNote and (blockNote == "no AE2 pattern" or blockNote:find("^needs ")) then
        local def = cfg.resources[blockRes]
        add("blockcraft", string.format("KIT FULL, but AE2 can't craft %ss: %s%s", def.label or blockRes,
            blockNote == "no AE2 pattern" and ("no AE2 pattern for " .. def.id .. " (and the Inanite Block)")
                or (blockNote:gsub("^needs (.+)$", function(r) return "ME has no " .. ((cfg.resources[r] or {}).label or r) end)),
            ". Plant held until it can."))
    end

    -- Batch machines at capacity: ready work keeps waiting for them, so they limit throughput.
    local window = math.floor((cfg.machineAlertSeconds or 300) / 60 + 0.5)
    local atCapacity = machinesAtCapacity()
    local capNames = {}
    for name in pairs(atCapacity) do capNames[#capNames + 1] = name end
    table.sort(capNames)
    for _, name in ipairs(capNames) do
        local mc = atCapacity[name]
        local top = {}
        for i = 1, math.min(3, #mc.waiting) do top[i] = mc.waiting[i] end
        add("atcapacity:" .. name, string.format(
            "%s AT CAPACITY: busy %d%% of the last %d min with work waiting (%s). It's limiting throughput; another %s would raise it.",
            string.upper(name), mc.busy, window, table.concat(top, ", "), name))
        found[#found].severity = "advisory" -- a limit, not a fault
    end

    -- Batch machines that can't run.
    for name, st in pairs(machineState) do
        if st.offline or st.foreign or st.stalled then
            add("machine:" .. name, string.upper(name) .. " " .. busyReason(st))
        end
    end
    return found
end

-- Keep each alert on screen until its cause has been gone alertClearSeconds (no flapping), and
-- mirror it into the core's alarm list (SCADA header + alarm page) when scadaAlarms is on.
local function updateAlerts(found)
    local t = now()
    local seen = {}
    local scada = cfg.scadaAlarms and _G.AlarmManager
    for _, a in ipairs(found) do
        seen[a.key] = true
        local cur = alerts[a.key]
        if not cur then
            alerts[a.key] = { text = a.text, since = t, lastSeen = t }
            alertOrder[#alertOrder + 1] = a.key
            event("ALERT %s", a.text)
            print("Insanite ALERT: " .. a.text)
        else
            cur.text, cur.lastSeen = a.text, t
        end
        if scada then pcall(AlarmManager.raise, "insanite:" .. a.key, a.severity or "warning", a.text, "insanite", false) end
    end
    for i = #alertOrder, 1, -1 do
        local key = alertOrder[i]
        if not seen[key] and t - alerts[key].lastSeen >= (cfg.alertClearSeconds or 30) then
            alerts[key] = nil
            table.remove(alertOrder, i)
            event("cleared %s", key)
            if scada then pcall(AlarmManager.clear, "insanite:" .. key) end
        end
    end
end

--endregion

--region status

local function sortedKeysOf(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

local function fmtAmount(def, amount)
    amount = amount or 0
    if def.kind == "fluid" then
        return string.format("%.1fB", amount / 1000)
    end
    return tostring(math.floor(amount))
end

local function buildStatus()
    local lines = {}
    local function add(text, color, bg, wrapIt)
        lines[#lines + 1] = { text = text, color = color or colors.white, bg = bg, wrap = wrapIt }
    end
    local K = cfg.stockBlocks or 2

    -- The two stop buttons, side by side on the top row (each half is its own touch target).
    local held = reactorList("ratio")
    local function button(key, runningText, stoppedText)
        if stopped[key] then
            return { key = key, text = stoppedText, color = colors.black, bg = colors.orange }
        end
        return { key = key, text = runningText, color = colors.white, bg = colors.gray }
    end
    local buttons = {
        button("reactors", "[ STOP " .. held .. " ]", "[ " .. held .. " STOPPED - START ]"),
        button("machines", "[ STOP MACHINES + CRAFTS ]", "[ MACHINES STOPPED - START ]"),
    }
    lines[#lines + 1] = { text = buttons[1].text .. "  " .. buttons[2].text, color = colors.white,
        buttons = buttons }

    -- (Alerts aren't part of the text: they're a window drawn over the bottom-right corner.)

    local kit = InsanitePlanner.kitCoverage(model, lastStock)
    add(string.format("Insanite factory  cycle %d   kit %.1f/%g blk   craftable now %d",
        cycleCount, kit, K, InsanitePlanner.craftableBlocks(model, lastStock)), colors.yellow)
    if lastError then add("last error: " .. lastError, colors.red) end
    if stopped.reactors then
        add(string.format("%s STOPPED by button: rods held at 100%% (%s keep running)", held,
            reactorList("stock")), colors.orange, nil, true)
    end
    if stopped.machines then
        add("Machines STOPPED by button: nothing goes into the reprocessor or fluidizer, no AE2 crafts",
            colors.orange, nil, true)
    end
    if rateDetail then
        add(string.format("Plant %.1f of %.1f blk/h   limit: %s",
            rateDetail.rate * 72000, plantRate * 72000, shortId(rateDetail.limit)),
            rateDetail.rate > 0 and colors.lime or colors.lightGray)
        for _, waste in ipairs(sortedKeysOf(rateDetail.stockPools)) do
            local sp = rateDetail.stockPools[waste]
            local def = cfg.resources[waste]
            local why = sp.state
            if sp.state == "holding" then
                local fdef = cfg.resources[sp.fuel]
                why = string.format("stopped: ME %s %s is under the %s floor (resumes at %s)",
                    (fdef.label or sp.fuel):lower(), fmtAmount(fdef, lastStock[sp.fuel]), fmtAmount(fdef, sp.reserve),
                    fmtAmount(fdef, sp.reserve * (1 + (cfg.stockFuelResumePct or 5) / 100)))
            elseif sp.state == "at cap" then
                why = "at cap, restarts below " .. fmtAmount(def, sp.restartAt)
            end
            add(string.format("Stock %s (%s) -> %s %s/%s: %s%s", sp.label, sp.fuel, waste, fmtAmount(def, sp.have),
                fmtAmount(def, sp.cap),
                why, sp.maxBurn and string.format(" (max %.1f mB/t)", sp.maxBurn) or ""),
                sp.state == "filling" and colors.cyan or colors.lightGray, nil, true)
        end
    end

    if #plantWarnings > 0 then
        add(string.format("Config warnings (%d) - see /insanite.conf:", #plantWarnings), colors.yellow)
        for i, w in ipairs(plantWarnings) do
            for j, part in ipairs(splitLines(w)) do
                local text = part:gsub("^%s+", "")
                add((j == 1 and string.format(" %d. ", i) or "    ") .. text, colors.yellow, nil, true)
            end
        end
    end

    add("Resource        ME      per-blk  have/target", colors.lightGray)
    -- Products first (in recipe order), then raw stock; autocrafted prerequisites (netherite
    -- blocks) aren't monitored at all.
    local order, seen = {}, {}
    for _, p in ipairs(model.processes) do
        if not seen[p.output] and not InsanitePlanner.isRaw(model, p.output) then
            order[#order + 1] = p.output
            seen[p.output] = true
        end
    end
    local raws = {}
    for res, n in pairs(need) do
        if n > 0 and not seen[res] and not (model.autocrafted or {})[res] then raws[#raws + 1] = res end
    end
    table.sort(raws)
    for _, res in ipairs(raws) do order[#order + 1] = res end
    for _, res in ipairs(order) do
        local def = cfg.resources[res]
        local n = need[res] or 0
        if n > 0 then
            local produced = not InsanitePlanner.isRaw(model, res)
            local cov = (lastProjected[res] or 0) / n
            local sp = produced and rateDetail and rateDetail.stockPools[res]
            local target = produced and string.format("%.1f/%g", cov, K) or "raw"
            if sp then target = "cap " .. fmtAmount(def, sp.cap) end
            local text = string.format("%-14s %8s %8s  %s", def.label or res,
                fmtAmount(def, lastStock[res]), fmtAmount(def, n), target)
            local color = colors.white
            if produced then color = (cov >= K) and colors.lime or colors.orange end
            if sp then color = colors.cyan end
            if not produced and (lastStock[res] or 0) < n then color = colors.red end
            add(text, color)
        end
    end

    add("Machines", colors.lightGray)
    for name in pairs(cfg.machines or {}) do
        local st = machineState[name] or {}
        local busy, _, covered = machinePressure(name)
        local atCap = machinesAtCapacity()[name] ~= nil
        add(string.format("%-12s %s%s%s", name, busyReason(st) or "idle", stopped.machines and " (loading stopped)" or "",
            busy and string.format("   busy %d%%%s", busy, covered and "" or " (warming up)") or ""),
            st.stalled and colors.red or ((stopped.machines or atCap) and colors.orange or colors.white))
    end
    for _, p in ipairs(model.processes) do
        if p.machine ~= "reactor" then
            local note = lastNotes[p.id] or ""
            local color = note:find("^start") and colors.lime or (note:find("^needs") and colors.orange or colors.white)
            add(string.format("  %-11s %s", p.id, note), color)
        end
    end

    -- One row per reactor; reactors that make the same waste form a pool (e.g. R6+R8 -> cyanite)
    -- and share its trim and deviation.
    if cfg.blockCraft and cfg.resources[cfg.blockCraft] then
        local note = lastNotes["craft " .. cfg.blockCraft] or ""
        local color = note:find("^request") and colors.lime
            or ((note == "no AE2 pattern" or note:find("^needs")) and colors.red or colors.white)
        add(string.format("  %-11s %s%s", "craft block", note,
            blocksInMe and string.format("  (%d in ME)", blocksInMe) or ""), color)
    end

    add("Reactor makes      trim  fuel rods  burn/target mB/t   dev  note", colors.lightGray)
    for _, p in ipairs(model.processes) do
        if p.machine == "reactor" then
            local pe = deviation.pools and deviation.pools[p.output]
            for _, id in ipairs(p.members) do
                local info = reactorInfo[id] or {}
                local rod = _G.InsaniteRods and InsaniteRods.state(id) or {}
                local r = rateDetail and rateDetail.reactors[id]
                local target = rateTargets[id] or 0
                local sp = rateDetail and rateDetail.stockPools[p.output]
                local fuel = (info.present and (info.fuelCapacity or 0) > 0)
                    and string.format("%3d%%", math.floor(info.fuelAmount / info.fuelCapacity * 100)) or "  - "
                local dev = "    -"
                if pe and pe.isRef then dev = "  ref" elseif pe and pe.dev then dev = string.format("%+4.0f%%", pe.dev * 100) end
                -- '!' marks deviation beyond what trim asked for (the part that isn't intended)
                local beyond = pe and pe.dev and pe.expected and math.abs(pe.dev - pe.expected) > (cfg.deviationAlertPct or 15) / 100
                if beyond then dev = dev .. "!" end
                local note = ""
                local mode = _G.InsaniteRods and InsaniteRods.modeOf(id) or p.rodControl[id]
                if not info.present then
                    note = "not connected"
                elseif mode == "held" then
                    note = "stopped (rods in)"
                    dev = "    -"
                elseif (info.fuelAmount or 0) < 1000 then
                    note = "out of fuel (ME importer?)"
                elseif mode == "power" then
                    note = "energy control"
                elseif sp then
                    dev = "stock"
                    note = (sp.state == "filling") and "filling to cap"
                        or (sp.state == "holding" and "stopped (fuel floor)" or sp.state)
                elseif target <= 0 then
                    note = "idle (rate 0)"
                end
                if rod.capacity then note = note .. string.format(" max %.2f", rod.capacity) end
                if rod.lastError then note = note .. " ERR " .. rod.lastError end
                local targetText = (target >= InsanitePlanner.FULL_BURN) and "max   " or string.format("%-6.2f", target)
                local text = string.format("%-7s %-10s %5s %s %4s %6.2f/%s %5s %s", shortId(id),
                    (cfg.resources[p.output].label or p.output):sub(1, 10),
                    (r and not sp) and string.format("x%.2f", r.trim) or "", fuel,
                    rod.level and string.format("%3.0f%%", rod.level) or "  - ",
                    rod.measured or 0, targetText, dev, note)
                local color = colors.white
                if rod.capacity or beyond then color = colors.orange end
                if mode == "held" then color = colors.lightGray end
                if sp then color = colors.cyan end -- flat out by design; a recorded max is normal
                if alerts["track:" .. id] or rod.lastError then color = colors.red end
                add(text, color)
            end
        end
    end
    -- Footnote: what trim alone accounts for, so an intended deviation doesn't look like a fault.
    local fromTrim = {}
    for _, p in ipairs(model.processes) do
        local pe = p.machine == "reactor" and deviation.pools and deviation.pools[p.output]
        if pe and pe.expected and not pe.isRef and math.abs(pe.expected) >= 0.005 then
            fromTrim[#fromTrim + 1] = string.format("%s %+.0f%%", p.label, pe.expected * 100)
        end
    end
    add(string.format("dev = burn pace vs %s in recipe ratio, 0%% = exact.%s ! = off by more than trim explains",
        deviation.refLabel or shortId(cfg.referenceReactor),
        #fromTrim > 0 and (" From trim alone: " .. table.concat(fromTrim, ", ") .. ".") or ""),
        colors.lightGray, nil, true)

    add("Events", colors.lightGray)
    for _, e in ipairs(events) do add(e, colors.lightGray) end
    return lines
end

-- Word-wrap text to `width`, continuation lines indented by `indent`.
local function wrapText(text, width, indent)
    local lead = text:match("^%s*")
    local out, line = {}, ""
    for word in text:gmatch("%S+") do
        local candidate = (line == "") and (lead .. word) or (line .. " " .. word)
        if #candidate > width and line ~= "" then
            out[#out + 1] = line
            line = indent .. word
        else
            line = candidate
        end
    end
    if line ~= "" or #out == 0 then out[#out + 1] = line end
    return out
end
Factory.wrapText = wrapText

-- The alert window: drawn over the bottom-right corner of the monitor while there are alerts.
-- Half the monitor wide (at least 30 columns), as tall as its text, never over the button row;
-- if it doesn't fit, the last row says how much more there is. Returns nil without alerts.
local function alertWindow(width, height)
    if #alertOrder == 0 or width < 4 or height < 3 then return nil end
    local w = math.max(math.min(30, width), math.floor(width / 2))
    local inner = w - 2
    local rows = { { text = string.format("!!! %d ALERT%s !!!", #alertOrder, #alertOrder == 1 and "" or "S"),
        color = colors.black, bg = colors.yellow } }
    for _, key in ipairs(alertOrder) do
        for _, chunk in ipairs(wrapText("- " .. alerts[key].text, inner, "  ")) do
            rows[#rows + 1] = { text = chunk:sub(1, inner), color = colors.white, bg = colors.red }
        end
    end
    rows[#rows + 1] = { text = "", color = colors.white, bg = colors.red }
    local maxRows = height - 1 -- the top row (stop buttons) always stays visible
    if #rows > maxRows then
        local hidden = #rows - maxRows + 1
        for i = #rows, maxRows, -1 do rows[i] = nil end
        rows[maxRows] = { text = string.format("... %d more line%s (/insanite/status.txt)", hidden,
            hidden == 1 and "" or "s"):sub(1, inner), color = colors.yellow, bg = colors.red }
    end
    return { x = width - w + 1, y = height - #rows + 1, w = w, rows = rows }
end

local function render()
    local lines = buildStatus()

    if cfg.statusFile then
        local text = {}
        if #alertOrder > 0 then
            text[#text + 1] = string.format("!! %d ALERT%s", #alertOrder, #alertOrder == 1 and "" or "S")
            for _, key in ipairs(alertOrder) do text[#text + 1] = "!! " .. alerts[key].text end
        end
        for _, l in ipairs(lines) do text[#text + 1] = (l.bg and "!! " or "") .. l.text end
        local dir = fs.getDir(cfg.statusFile)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local f = fs.open(cfg.statusFile, "w")
        if f then f.write(table.concat(text, "\n")); f.close() end
    end

    buttonAt = {}
    if cfg.monitor then
        -- Claim the monitor from the core UI so the two don't draw over each other.
        if _G.monitors and _G.monitors[cfg.monitor] then _G.monitors[cfg.monitor] = nil end
        local mon = wrap(cfg.monitor)
        if mon then
            pcall(function()
                mon.setTextScale(0.5)
                mon.setBackgroundColor(colors.black)
                mon.clear()
                local width, height = mon.getSize()
                local y = 1
                for _, l in ipairs(lines) do
                    local chunks = l.wrap and wrapText(l.text, width - 1, "      ") or { l.text }
                    if l.buttons then
                        -- Equal-width buttons, label centred, one blank column between them.
                        local n = #l.buttons
                        local w = math.floor((width - (n - 1)) / n)
                        for i, b in ipairs(l.buttons) do
                            local x1 = 1 + (i - 1) * (w + 1)
                            local label = b.text:sub(1, w)
                            local pad = w - #label
                            local left = math.floor(pad / 2)
                            mon.setCursorPos(x1, y)
                            mon.setBackgroundColor(b.bg)
                            mon.setTextColor(b.color)
                            mon.write(string.rep(" ", left) .. label .. string.rep(" ", pad - left))
                            buttonAt[#buttonAt + 1] = { key = b.key, y = y, x1 = x1, x2 = x1 + w - 1 }
                        end
                        chunks = {}
                        y = y + 1
                    end
                    for _, chunk in ipairs(chunks) do
                        mon.setCursorPos(1, y)
                        mon.setBackgroundColor(l.bg or colors.black)
                        mon.setTextColor(l.color)
                        -- lines with a background are padded so the colour spans the whole monitor
                        mon.write(l.bg and (chunk .. string.rep(" ", math.max(0, width - #chunk))) or chunk)
                        y = y + 1
                    end
                end
                -- Alert window on top of everything, bottom-right.
                local win = alertWindow(width, height)
                if win then
                    for i, r in ipairs(win.rows) do
                        mon.setCursorPos(win.x, win.y + i - 1)
                        mon.setBackgroundColor(r.bg)
                        mon.setTextColor(r.color)
                        mon.write(" " .. r.text .. string.rep(" ", win.w - 1 - #r.text))
                    end
                end
                mon.setBackgroundColor(colors.black)
            end)
        end
    end
end

--endregion

--region lifecycle

-- Load + check the plant config, then build everything from it. On any problem this raises
-- { plantErrors = {...}, plantWarnings = {...}, plant = ... } and nothing starts.
function Factory.init(extraOverrides)
    local plant, errors, warnings = Factory.checkPlant()
    if #errors > 0 then
        error({ plantErrors = errors, plantWarnings = warnings, plant = plant }, 0)
    end
    plantWarnings = warnings

    local merged = deepMerge(_G.INSANITE_DEFAULTS, {})
    merged = deepMerge(merged, plant)
    if extraOverrides then merged = deepMerge(merged, extraOverrides) end
    cfg = merged

    local modelErrors
    model, modelErrors = InsanitePlanner.buildModel(cfg)
    if #modelErrors > 0 then
        error({ plantErrors = modelErrors, plantWarnings = warnings, plant = plant }, 0)
    end
    need, opsPerBlock = InsanitePlanner.computeNeeds(model)

    machineState, reactorInfo, lastEject, craftableCache, stockState = {}, {}, {}, {}, {}
    lastNotes, lastActions, lastStock, lastProjected = {}, {}, {}, {}
    blocksInMe = nil
    alerts, alertOrder, trackSince, deviation, slowSince = {}, {}, {}, { reactors = {} }, nil
    machineLoad, machineRuns, opSecondsLearned, craftFailures = {}, {}, {}, {}
    local saved = readTableFile(cfg.stateFile)
    for name, process in pairs(saved or {}) do
        machineState[name] = { process = process }
    end

    plantRate = InsanitePlanner.plantRate(cfg, model, opsPerBlock)
    rateTargets, rateDetail = {}, nil
    local rodsOn = _G.InsaniteRods and InsaniteRods.configure(cfg)
    local saved = readTableFile(cfg.pauseFile) or {}
    stopped = { reactors = saved.reactors == true, machines = saved.machines == true }
    lastTap = {}
    applyStops()

    local parts = {}
    for _, res in ipairs({ "uranium", "blutonium", "cyanite", "rossinite", "benitoite" }) do
        if need[res] and need[res] > 0 then
            parts[#parts + 1] = res .. " " .. fmtAmount(cfg.resources[res], need[res])
        end
    end
    bootMessage = "Insanite plugin: per block " .. table.concat(parts, ", ")
        .. string.format("; max pace %.1f blocks/h%s", plantRate * 72000,
            rodsOn and ", reactors locked to recipe ratio" or "")
        .. ((stopped.reactors or stopped.machines) and string.format(
            "\nInsanite STOPPED by button:%s%s. Tap START on %s (or delete %s and reboot).",
            stopped.reactors and (" " .. reactorList("ratio") .. " reactors") or "",
            stopped.machines and " machines + AE2 crafts" or "", tostring(cfg.monitor), tostring(cfg.pauseFile)) or "")
    return cfg
end

function Factory.plantRate() return plantRate end
function Factory.rateTargets() return rateTargets end
function Factory.rateDetail() return rateDetail end
function Factory.config() return cfg end
function Factory.needs() return need, opsPerBlock end
function Factory.machineState() return machineState end
function Factory.lastNotes() return lastNotes end
function Factory.lastActions() return lastActions end
function Factory.events() return events end
function Factory.statusLines() return buildStatus() end
function Factory.deviation() return deviation end
function Factory.alerts()
    local list = {}
    for _, key in ipairs(alertOrder) do list[#list + 1] = { key = key, text = alerts[key].text } end
    return list
end

function Factory.cycle()
    cycleCount = cycleCount + 1
    applyStops() -- before anything that can fail, so a reactor stop always holds

    if not wrap(cfg.bridge) then
        lastNotes = {}
        lastError = "ME bridge " .. tostring(cfg.bridge) .. " not found"
        updateAlerts({ { key = "bridge", text = "ME BRIDGE " .. tostring(cfg.bridge) .. " NOT FOUND - factory paused" } })
        render()
        return
    end

    -- 1. Empty configured outlets/output ports into ME.
    for _, r in pairs(cfg.reactors or {}) do
        if r and r.outlet then importFrom(cfg.resources[r.waste], r.outlet) end
    end
    for name, m in pairs(cfg.machines or {}) do
        if m.output then
            for _, p in ipairs(processesFor(name)) do importFrom(cfg.resources[p.output], m.output) end
        end
    end

    -- 2. Observe.
    local stock = {}
    for res, def in pairs(cfg.resources) do
        if (need[res] or 0) > 0 then stock[res] = meAmount(def) end
    end

    local pending, busy, running = {}, {}, {}
    for name, m in pairs(cfg.machines or {}) do
        local st = observeMachine(name, m)
        busy[name] = busyReason(st)
        if busy[name] then running[name] = st.process end
        if stopped.machines then busy[name] = "loading stopped" end
        if st.process and st.contents then
            local p = model.byId[st.process]
            pending[p.output] = (pending[p.output] or 0) + impliedOps(p, st.contents) * p.outQty
        end
    end

    local reactors = {}
    for id, r in pairs(cfg.reactors or {}) do
        if r then reactors[id] = observeReactor(id, r) end
    end

    -- 3. Reaction rate: one plant rate from the kit reserve, split in recipe ratio, capped by
    --    the slowest reactor (see InsanitePlanner.rateTargets).
    local burnTarget = {}
    if _G.InsaniteRods and InsaniteRods.enabled() then
        burnTarget, rateDetail = InsanitePlanner.rateTargets(cfg, model, need, opsPerBlock, stock,
            plantRate, InsaniteRods.capacities(), stockState)
        for id in pairs(heldReactors) do burnTarget[id] = 0 end -- reactor stop: rods fully in
        local fullPace = {}
        for id, r in pairs(rateDetail.reactors) do fullPace[id] = plantRate * r.share end
        InsaniteRods.update(burnTarget, reactors, fullPace)
        InsaniteRods.install()
    end
    rateTargets = burnTarget

    -- 4. Plan batch-machine loads and AE2 craft requests (reactor fuel is the ME importer's job).
    --    Machine stop: every batch machine counts as busy ("loading stopped") and AE2 crafts are
    --    off, so nothing is loaded or requested.
    local crafting, craftable = {}, {}
    if not stopped.machines then
        for _, p in ipairs(model.processes) do
            if p.machine == "ae2" then
                crafting[p.output] = isCrafting(p.output)
                craftable[p.output] = isCraftable(p.output)
            end
        end
    end
    local actions, notes, projected, waiting = InsanitePlanner.plan(cfg, model, need, {
        stock = stock, pending = pending, busy = busy, running = running, crafting = crafting, craftable = craftable,
        craftsStopped = stopped.machines,
    })
    if stopped.machines then machineLoad, machineRuns = {}, {} else sampleMachines(waiting) end

    -- 5. Act.
    for _, a in ipairs(actions) do
        local p = a.process
        if p.machine == "ae2" then
            requestCraft(p, a.ops)
        else
            local loaded, short = runBatch(p, a.ops)
            if loaded == 0 then notes[p.id] = "needs " .. tostring(short) .. " (gone before loading)" end
        end
    end

    -- 5b. The finished block: once the kit is at target, AE2 crafts Insanite Blocks from it.
    local blockRes = cfg.blockCraft
    if blockRes and cfg.resources[blockRes] then
        local enabled = InsanitePlanner.ALLOWED_CRAFTS[blockRes] and (cfg.autocraft or {})[blockRes] == true
        local crafting, craftable = false, nil
        if enabled and not stopped.machines
            and InsanitePlanner.kitCoverage(model, stock) >= (cfg.stockBlocks or 2) then
            crafting = isCrafting(blockRes)
            craftable = isCraftable(blockRes)
        end
        local n, note = InsanitePlanner.blockCraft(cfg, model, stock,
            { stopped = stopped.machines, crafting = crafting, craftable = craftable })
        if n > 0 and requestCraft({ output = blockRes, outQty = 1 }, n) then
            event("kit full: %d %s requested from AE2", n, cfg.resources[blockRes].label or blockRes)
        end
        notes["craft " .. blockRes] = note
        blocksInMe = meAmount(cfg.resources[blockRes])
    end

    -- 6. Ratio deviations (actual burn vs the reference reactor) and alerts.
    local measured = {}
    if _G.InsaniteRods then
        for id in pairs(burnTarget) do
            local st = InsaniteRods.state(id)
            measured[id] = st and st.measured or 0
        end
    end
    deviation = InsanitePlanner.deviations(cfg, rateDetail, measured)
    updateAlerts(buildAlerts(notes))

    -- 7. Remember which recipe each machine holds (survives a reboot mid-batch).
    local saveState = {}
    for name, st in pairs(machineState) do
        if st.process then saveState[name] = st.process end
    end
    writeTableFile(cfg.stateFile, saveState)

    lastNotes, lastActions, lastStock, lastProjected = notes, actions, stock, projected
    lastError = nil
    render()
end

-- The plugin isn't running because of plant config problems: say exactly what, everywhere the
-- player might look (computer screen, the status monitor if one is configured, the SCADA alarm
-- list, and /insanite/config-problems.txt). Reactors stay on the core's energy control.
local function reportPlantProblems(problem, firstTime)
    local errors = problem.plantErrors or { tostring(problem) }
    local lines = Factory.formatProblems(errors, problem.plantWarnings)
    local header = string.format("Insanite plugin NOT running: %d problem%s in %s", #errors,
        #errors == 1 and "" or "s", _G.INSANITE_DEFAULTS.plantFile)
    local footer = "Fix the file and the plugin starts by itself within 30 s (or reboot). "
        .. "Reactors stay on the core's energy control until then."

    if not fs.exists("/insanite") then fs.makeDir("/insanite") end
    local f = fs.open("/insanite/config-problems.txt", "w")
    if f then
        f.write(header .. "\n\n" .. table.concat(lines, "\n\n") .. "\n\n" .. footer .. "\n")
        f.close()
    end

    if firstTime then
        print("")
        print(header .. ":")
        for _, l in ipairs(lines) do print(l) end
        print(footer)
        print("(Full list: /insanite/config-problems.txt)")
    end

    if _G.AlarmManager then
        pcall(AlarmManager.raise, "insanite:config", "warning",
            header .. " - see the computer screen or /insanite/config-problems.txt", "insanite", false)
    end

    -- Show it on the status monitor too, if the config names a usable one.
    local monName = problem.plant and type(problem.plant.monitor) == "string" and problem.plant.monitor
    local mon = monName and wrap(monName)
    if mon and type(mon.getSize) == "function" then
        if _G.monitors then _G.monitors[monName] = nil end
        pcall(function()
            mon.setTextScale(0.5)
            mon.setBackgroundColor(colors.black)
            mon.clear()
            local width, height = mon.getSize()
            local y = 1
            local function put(text, fg, bg)
                for _, chunk in ipairs(Factory.wrapText(text, width - 1, "    ")) do
                    if y > height then return end
                    mon.setCursorPos(1, y)
                    mon.setBackgroundColor(bg or colors.black)
                    mon.setTextColor(fg)
                    mon.write(bg and (chunk .. string.rep(" ", math.max(0, width - #chunk))) or chunk)
                    y = y + 1
                end
            end
            put("", colors.white, colors.red)
            put("  " .. header, colors.yellow, colors.red)
            put("", colors.white, colors.red)
            for _, l in ipairs(lines) do
                for _, part in ipairs(splitLines(l)) do
                    put(part, l:find("^WARNING") and colors.yellow or colors.white)
                end
                y = y + 1
            end
            put(footer, colors.lightGray)
            mon.setBackgroundColor(colors.black)
        end)
    end
end
Factory.reportPlantProblems = reportPlantProblems

function Factory.runForever()
    local firstTime = true
    while true do
        local ok, problem = pcall(Factory.init)
        if ok then break end
        if tostring(problem):find("Terminated") then error(problem, 0) end
        if type(problem) ~= "table" then problem = { plantErrors = { tostring(problem) } } end
        if firstTime then sleep(3) end -- let the core's startup messages finish first
        reportPlantProblems(problem, firstTime)
        firstTime = false
        sleep(30)
    end
    if _G.AlarmManager then pcall(AlarmManager.clear, "insanite:config") end
    for i, w in ipairs(plantWarnings) do print(string.format("Insanite config WARNING %d: %s", i, w)) end
    if cfg.enabled == false then
        print("Insanite plugin disabled in config")
        return
    end
    print(bootMessage)

    while true do
        local cycleOk, cycleErr = pcall(Factory.cycle)
        if not cycleOk then
            if tostring(cycleErr):find("Terminated") then error(cycleErr, 0) end
            lastError = tostring(cycleErr)
            event("error: %s", lastError)
            pcall(render)
        end
        -- Wait for the next cycle; a tap on the pause button runs one straight away.
        local timer = os.startTimer(cfg.cycleSeconds or 5)
        while true do
            local ev, a, b, c = os.pullEvent()
            if ev == "timer" and a == timer then break end
            -- A reconnected reactor gets a fresh core object (energy law): re-apply the reactor
            -- stop now rather than at the next cycle.
            if ev == "peripheral" then pcall(applyStops) end
            if ev == "monitor_touch" and Factory.touch(a, b, c) then
                pcall(render)
                break
            end
        end
    end
end

--endregion

_G.InsaniteFactory = Factory
