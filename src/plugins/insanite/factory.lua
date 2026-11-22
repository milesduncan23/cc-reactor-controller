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
-- Runs beside the core controller (see hook.lua). Every peripheral call is pcall-guarded and
-- a failed cycle is logged and retried, so a plugin fault cannot stop reactor control.

local Factory = {}

local cfg, model, need, opsPerBlock
local plantRate = 0          -- Insanite Blocks per tick the rod targets are sized for
local rateTargets = {}       -- reactorId -> burn target mB/t (rod control)
local rateDetail = nil       -- last InsanitePlanner.rateTargets detail (plant rate, limit, trims)
local machineState = {}      -- machineName -> { process, ops, busy, sig, changedAt, stalled, contents }
local reactorInfo = {}       -- reactorId -> last stats
local lastEject = {}         -- reactorId -> clock
local lastNotes, lastActions = {}, {}
local lastStock, lastProjected = {}, {}
local events = {}
local cycleCount = 0
local lastError = nil
local bootMessage = nil
local plantWarnings = {}     -- non-fatal plant config problems, shown on the status screen

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
        if st.process then event("%s finished %s", name, st.process) end
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
        if now() - (st.repairAt or -math.huge) >= window then
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

local function runBatch(p, ops)
    local m = cfg.machines[p.machine]
    local st = machineState[p.machine] or {}
    machineState[p.machine] = st

    -- First input sets how many operations actually happen; later inputs are sized to match.
    local moved, opsDone = {}, ops
    for i, inp in ipairs(p.inputs) do
        local def = cfg.resources[inp.res]
        moved[i] = exportTo(def, m.ports[inp.port], opsDone * inp.qty)
        if i == 1 then
            opsDone = math.ceil(moved[i] / inp.qty)
            if opsDone == 0 then
                event("%s: could not load %s", p.machine, inp.res)
                return
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
end

--endregion

--region reactors

local function observeReactor(id, r)
    local info = { present = wrap(id) ~= nil, feedable = r.inlet ~= nil and wrap(r.inlet) ~= nil }
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

local function feedReactor(p, ops)
    local r = cfg.reactors[p.reactor]
    local inp = p.inputs[1]
    local def = cfg.resources[inp.res]
    local moved = exportTo(def, r.inlet, ops * inp.qty)
    if moved > 0 then
        event("%s <- %d %s", shortId(p.reactor), moved, def.kind == "fluid" and ("mB " .. inp.res) or inp.res)
    end
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
        local res = (notes[p.id] or ""):match("^needs (.+)$")
        if res and not model.producerOf[res] then out[#out + 1] = p.id .. " needs " .. res end
    end
    for name, st in pairs(machineState) do
        if st.offline or st.foreign or st.stalled then out[#out + 1] = name .. " " .. busyReason(st) end
    end
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
    if d and d.unconstrained > 0 and d.rate < d.unconstrained * slowAt then
        local pct = math.floor(d.rate / d.unconstrained * 100 + 0.5)
        if d.limitKind == "overflow" then
            local cov = 0
            for _, r in pairs(d.reactors) do
                if r.output == d.limitId then cov = r.cov end
            end
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
            local r = d.reactors[d.limitId]
            add("capacity:" .. d.limitId, string.format(
                "PLANT SLOWED to %d%%: %s at its max burn (%.2f of %.2f mB/t needed); other reactors matched",
                pct, shortId(d.limitId), r.capacity or 0, d.unconstrained * r.share * r.trim))
        end
    end
    if not causeless then slowSince = nil end

    -- A reactor that has been off its own burn target for too long.
    local window = cfg.deviationAlertSeconds or 120
    local limit = (cfg.deviationAlertPct or 15) / 100
    for id, e in pairs(deviation.reactors) do
        local r = d and d.reactors[id]
        local floor = r and 0.1 * plantRate * r.share or 0
        local measuredBurn = r and e.pace * r.share or 0
        local off = (e.target > 0) and math.abs(measuredBurn - e.target) / math.max(e.target, floor) or 0
        if e.tracking and off > limit then
            trackSince[id] = trackSince[id] or now()
            if now() - trackSince[id] >= window then
                local info = reactorInfo[id] or {}
                local rod = (_G.InsaniteRods and InsaniteRods.state(id)) or {}
                local why = ""
                if (info.fuelAmount or 0) < 1000 then
                    why = " - out of fuel"
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
        if scada then pcall(AlarmManager.raise, "insanite:" .. a.key, "warning", a.text, "insanite", false) end
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

    -- Alert banner: a full-width red band at the very top.
    if #alertOrder > 0 then
        add("", colors.white, colors.red)
        add(string.format("  !!! %d ALERT%s !!!", #alertOrder, #alertOrder == 1 and "" or "S"), colors.yellow, colors.red)
        for _, key in ipairs(alertOrder) do add("  " .. alerts[key].text, colors.white, colors.red, true) end
        add("", colors.white, colors.red)
    end

    local kit = InsanitePlanner.kitCoverage(model, lastStock)
    add(string.format("Insanite factory  cycle %d   kit %.1f/%g blk   craftable now %d",
        cycleCount, kit, K, InsanitePlanner.craftableBlocks(model, lastStock)), colors.yellow)
    if lastError then add("last error: " .. lastError, colors.red) end
    if rateDetail then
        add(string.format("Plant %.1f of %.1f blk/h   limit: %s",
            rateDetail.rate * 72000, plantRate * 72000, shortId(rateDetail.limit)),
            rateDetail.rate > 0 and colors.lime or colors.lightGray)
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
    local order, seen = {}, {}
    for _, p in ipairs(model.processes) do
        if not seen[p.output] then order[#order + 1] = p.output; seen[p.output] = true end
    end
    local raws = {}
    for res, n in pairs(need) do
        if n > 0 and not seen[res] then raws[#raws + 1] = res end
    end
    table.sort(raws)
    for _, res in ipairs(raws) do order[#order + 1] = res end
    for _, res in ipairs(order) do
        local def = cfg.resources[res]
        local n = need[res] or 0
        if n > 0 then
            local produced = model.producerOf[res] ~= nil
            local cov = (lastProjected[res] or 0) / n
            local text = string.format("%-14s %8s %8s  %s", def.label or res,
                fmtAmount(def, lastStock[res]), fmtAmount(def, n),
                produced and string.format("%.1f/%g", cov, K) or "raw")
            local color = colors.white
            if produced then color = (cov >= K) and colors.lime or colors.orange end
            if not produced and (lastStock[res] or 0) < n then color = colors.red end
            add(text, color)
        end
    end

    add("Machines", colors.lightGray)
    for name in pairs(cfg.machines or {}) do
        local st = machineState[name] or {}
        add(string.format("%-12s %s", name, busyReason(st) or "idle"), st.stalled and colors.red or colors.white)
    end
    for _, p in ipairs(model.processes) do
        if p.machine ~= "reactor" then
            local note = lastNotes[p.id] or ""
            local color = note:find("^start") and colors.lime or (note:find("^needs") and colors.orange or colors.white)
            add(string.format("  %-11s %s", p.id, note), color)
        end
    end

    add("Reactor mode  trim  fuel rods  burn/target mB/t   dev", colors.lightGray)
    for _, p in ipairs(model.processes) do
        if p.machine == "reactor" then
            local info = reactorInfo[p.reactor] or {}
            local rod = _G.InsaniteRods and InsaniteRods.state(p.reactor) or {}
            local r = rateDetail and rateDetail.reactors[p.reactor]
            local e = deviation.reactors[p.reactor]
            local fuel = (info.present and (info.fuelCapacity or 0) > 0)
                and string.format("%3d%%", math.floor(info.fuelAmount / info.fuelCapacity * 100)) or "  - "
            local mode = _G.InsaniteRods and InsaniteRods.modeOf(p.reactor) or p.rodControl
            local dev = "    -"
            if e and e.isRef then dev = "  ref" elseif e and e.dev then dev = string.format("%+4.0f%%", e.dev * 100) end
            -- '!' marks deviation beyond what trim asked for (the part that isn't intended)
            local beyond = e and e.dev and e.expected and math.abs(e.dev - e.expected) > (cfg.deviationAlertPct or 15) / 100
            if beyond then dev = dev .. "!" end
            local text = string.format("%-6s %-5s %5s %s %4s %6.2f/%-6.2f %5s %s", shortId(p.reactor), mode,
                r and string.format("x%.2f", r.trim) or "", fuel,
                rod.level and string.format("%3.0f%%", rod.level) or "  - ",
                rod.measured or 0, rateTargets[p.reactor] or 0, dev, lastNotes[p.id] or "")
            if rod.capacity then text = text .. string.format(" max %.2f", rod.capacity) end
            if rod.lastError then text = text .. " ERR " .. rod.lastError end
            local color = colors.white
            if rod.capacity then color = colors.orange end
            if beyond then color = colors.orange end
            if alerts["track:" .. p.reactor] or rod.lastError then color = colors.red end
            add(text, color)
        end
    end
    -- Footnote: what trim alone accounts for, so an intended deviation doesn't look like a fault.
    local fromTrim = {}
    for _, p in ipairs(model.processes) do
        local e = deviation.reactors[p.reactor or ""]
        if e and e.expected and not e.isRef and math.abs(e.expected) >= 0.005 then
            fromTrim[#fromTrim + 1] = string.format("%s %+.0f%%", shortId(p.reactor), e.expected * 100)
        end
    end
    add(string.format("dev = burn pace vs %s in recipe ratio, 0%% = exact.%s ! = off by more than trim explains",
        shortId(deviation.ref or cfg.referenceReactor),
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

local function render()
    local lines = buildStatus()

    if cfg.statusFile then
        local text = {}
        for _, l in ipairs(lines) do text[#text + 1] = (l.bg and "!! " or "") .. l.text end
        local dir = fs.getDir(cfg.statusFile)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local f = fs.open(cfg.statusFile, "w")
        if f then f.write(table.concat(text, "\n")); f.close() end
    end

    if cfg.monitor then
        -- Claim the monitor from the core UI so the two don't draw over each other.
        if _G.monitors and _G.monitors[cfg.monitor] then _G.monitors[cfg.monitor] = nil end
        local mon = wrap(cfg.monitor)
        if mon then
            pcall(function()
                mon.setTextScale(0.5)
                mon.setBackgroundColor(colors.black)
                mon.clear()
                local width = mon.getSize()
                local y = 1
                for _, l in ipairs(lines) do
                    local chunks = l.wrap and wrapText(l.text, width - 1, "      ") or { l.text }
                    for _, chunk in ipairs(chunks) do
                        mon.setCursorPos(1, y)
                        mon.setBackgroundColor(l.bg or colors.black)
                        mon.setTextColor(l.color)
                        -- banner lines are padded so the red band spans the whole monitor
                        mon.write(l.bg and (chunk .. string.rep(" ", math.max(0, width - #chunk))) or chunk)
                        y = y + 1
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

    machineState, reactorInfo, lastEject = {}, {}, {}
    lastNotes, lastActions, lastStock, lastProjected = {}, {}, {}, {}
    alerts, alertOrder, trackSince, deviation, slowSince = {}, {}, {}, { reactors = {} }, nil
    local saved = readTableFile(cfg.stateFile)
    for name, process in pairs(saved or {}) do
        machineState[name] = { process = process }
    end

    plantRate = InsanitePlanner.plantRate(cfg, model, opsPerBlock)
    rateTargets, rateDetail = {}, nil
    local rodsOn = _G.InsaniteRods and InsaniteRods.configure(cfg)

    local parts = {}
    for _, res in ipairs({ "yellorium", "blutonium", "cyanite", "rossinite", "benitoite" }) do
        if need[res] and need[res] > 0 then
            parts[#parts + 1] = res .. " " .. fmtAmount(cfg.resources[res], need[res])
        end
    end
    bootMessage = "Insanite plugin: per block " .. table.concat(parts, ", ")
        .. string.format("; max pace %.1f blocks/h%s", plantRate * 72000,
            rodsOn and ", reactors locked to recipe ratio" or "")
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

    local pending, busy = {}, {}
    for name, m in pairs(cfg.machines or {}) do
        local st = observeMachine(name, m)
        busy[name] = busyReason(st)
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
            plantRate, InsaniteRods.capacities())
        local fullPace = {}
        for id, r in pairs(rateDetail.reactors) do fullPace[id] = plantRate * r.share end
        InsaniteRods.update(burnTarget, reactors, fullPace)
        InsaniteRods.install()
    end
    rateTargets = burnTarget

    -- 4. Plan dosing and fuel.
    local actions, notes, projected = InsanitePlanner.plan(cfg, model, need, {
        stock = stock, pending = pending, busy = busy,
        reactors = reactors, burnTarget = burnTarget,
    })

    -- 5. Act.
    for _, a in ipairs(actions) do
        local p = a.process
        if p.machine == "reactor" then
            feedReactor(p, a.ops)
        else
            runBatch(p, a.ops)
        end
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
        sleep(cfg.cycleSeconds or 5)
    end
end

--endregion

_G.InsaniteFactory = Factory
