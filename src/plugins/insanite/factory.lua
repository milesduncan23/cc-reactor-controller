-- Insanite factory plugin: runtime.
--
-- Every cycleSeconds: empty configured output ports into ME, read ME stock + machine/reactor
-- state, ask InsanitePlanner what to run, then dose the machines through the ME Bridge.
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
local machineState = {}      -- machineName -> { process, ops, busy, sig, changedAt, stalled, contents }
local reactorInfo = {}       -- reactorId -> last stats
local craftableCache = {}    -- res -> { value, at }
local lastEject = {}         -- reactorId -> clock
local lastNotes, lastActions = {}, {}
local lastStock, lastProjected = {}, {}
local events = {}
local cycleCount = 0
local lastError = nil
local bootMessage = nil

local unpack = table.unpack or unpack

local function now() return os.clock() end

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
        event("%s <- %d %s", p.reactor, moved, def.kind == "fluid" and ("mB " .. inp.res) or inp.res)
    end
end

--endregion

--region AE2

local function craftable(res)
    local cached = craftableCache[res]
    if cached and now() - cached.at < 60 then return cached.value end
    local value = call(cfg.bridge, "isCraftable", { name = cfg.resources[res].id })
    value = value and true or false
    craftableCache[res] = { value = value, at = now() }
    return value
end

local function craft(p, count)
    local ok, err = call(cfg.bridge, "craftItem", { name = cfg.resources[p.output].id, count = count })
    if ok then
        event("AE2 craft %d %s", count, p.output)
    else
        event("AE2 craft %s failed: %s", p.output, tostring(err))
        craftableCache[p.output] = nil
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
    local function add(text, color) lines[#lines + 1] = { text = text, color = color or colors.white } end

    add(string.format("Insanite factory  cycle %d", cycleCount), colors.yellow)
    if lastError then add("last error: " .. lastError, colors.red) end

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
            local cov = (lastProjected[res] or 0) / n
            local target = InsanitePlanner.targetBlocks(cfg, model, res)
            local produced = model.producerOf[res] ~= nil
            local text = string.format("%-14s %8s %8s  %s", def.label or res,
                fmtAmount(def, lastStock[res]), fmtAmount(def, n),
                produced and string.format("%.1f/%s", cov, target == math.huge and "inf" or tostring(target)) or "raw")
            local color = colors.white
            if produced then color = (cov >= target) and colors.lime or colors.orange end
            if not produced and (lastStock[res] or 0) < n then color = colors.red end
            add(text, color)
        end
    end

    add("Machines", colors.lightGray)
    for name in pairs(cfg.machines or {}) do
        local st = machineState[name] or {}
        add(string.format("%-12s %s", name, busyReason(st) or "idle"), st.stalled and colors.red or colors.white)
    end
    add("Processes", colors.lightGray)
    for _, p in ipairs(model.processes) do
        local note = lastNotes[p.id] or ""
        local color = note:find("^start") and colors.lime or (note:find("^needs") and colors.orange or colors.white)
        local label = p.machine == "reactor"
            and string.format("%s (%s)", p.id:gsub("BigReactors%-", ""), p.mode)
            or p.id
        local info = reactorInfo[p.reactor or ""]
        if info and info.present and (info.fuelCapacity or 0) > 0 then
            label = label .. string.format(" fuel %d%%", math.floor(info.fuelAmount / info.fuelCapacity * 100))
        end
        add(string.format("%-28s %s", label, note), color)
        local rod = p.reactor and _G.InsaniteRods and InsaniteRods.state(p.reactor)
        if rod and rateTargets[p.reactor] then
            local text = string.format("  rods %s %3.0f%%  burn %.2f / %.2f mB/t",
                InsaniteRods.modeOf(p.reactor), rod.level or 0, rod.measured or 0, rateTargets[p.reactor])
            if rod.powerWins then text = text .. "  (energy demand higher)" end
            if rod.lastError then text = text .. "  ERR " .. rod.lastError end
            add(text, rod.lastError and colors.red or colors.lightGray)
        end
    end
    add("Events", colors.lightGray)
    for _, e in ipairs(events) do add(e, colors.lightGray) end
    return lines
end

local function render()
    local lines = buildStatus()

    if cfg.statusFile then
        local text = {}
        for _, l in ipairs(lines) do text[#text + 1] = l.text end
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
                for i, l in ipairs(lines) do
                    mon.setCursorPos(1, i)
                    mon.setTextColor(l.color)
                    mon.write(l.text)
                end
            end)
        end
    end
end

--endregion

--region lifecycle

function Factory.init(extraOverrides)
    local merged = deepMerge(_G.INSANITE_DEFAULTS, {})
    local fileOverrides, err = readTableFile(_G.INSANITE_DEFAULTS.overrideFile)
    if err then print("Insanite plugin: " .. err .. " (using defaults)") end
    if fileOverrides then merged = deepMerge(merged, fileOverrides) end
    if extraOverrides then merged = deepMerge(merged, extraOverrides) end
    cfg = merged

    local errors
    model, errors = InsanitePlanner.buildModel(cfg)
    if #errors > 0 then
        error("Insanite plugin config: " .. table.concat(errors, "; "), 0)
    end
    need, opsPerBlock = InsanitePlanner.computeNeeds(model)

    machineState, reactorInfo, craftableCache, lastEject = {}, {}, {}, {}
    local saved = readTableFile(cfg.stateFile)
    for name, process in pairs(saved or {}) do
        machineState[name] = { process = process }
    end

    plantRate = InsanitePlanner.plantRate(cfg, model, opsPerBlock)
    rateTargets = {}
    local rodsOn = _G.InsaniteRods and InsaniteRods.configure(cfg)

    local parts = {}
    for _, res in ipairs({ "yellorium", "blutonium", "cyanite", "rossinite", "benitoite" }) do
        if need[res] and need[res] > 0 then
            parts[#parts + 1] = res .. " " .. fmtAmount(cfg.resources[res], need[res])
        end
    end
    bootMessage = "Insanite plugin: per block " .. table.concat(parts, ", ")
        .. string.format("; pace %.1f blocks/h%s", plantRate * 72000, rodsOn and ", rods follow waste demand" or "")
    return cfg
end

function Factory.plantRate() return plantRate end
function Factory.rateTargets() return rateTargets end

function Factory.config() return cfg end
function Factory.needs() return need, opsPerBlock end
function Factory.machineState() return machineState end
function Factory.lastNotes() return lastNotes end
function Factory.lastActions() return lastActions end
function Factory.events() return events end

function Factory.cycle()
    cycleCount = cycleCount + 1

    if not wrap(cfg.bridge) then
        lastNotes = {}
        lastError = "ME bridge " .. tostring(cfg.bridge) .. " not found"
        render()
        return
    end

    -- 1. Empty configured outlets/output ports into ME.
    for id, r in pairs(cfg.reactors or {}) do
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
        if r then
            local info = observeReactor(id, r)
            reactors[id] = info
            if info.present then
                local def = cfg.resources[r.waste]
                local reactant = (info.fuelAmount or 0) + (info.wasteAmount or 0)
                local asWaste = (def.kind == "fluid") and reactant or math.floor(reactant / 1000)
                pending[r.waste] = (pending[r.waste] or 0) + asWaste
            end
        end
    end

    -- Rod control: burn-rate targets from the recipe ratio + how much waste ME already holds.
    if _G.InsaniteRods and InsaniteRods.enabled() then
        rateTargets = InsanitePlanner.rateTargets(cfg, model, need, opsPerBlock, stock, plantRate)
        InsaniteRods.update(rateTargets, reactors)
        InsaniteRods.install()
    end

    local crafting, craftableMap = {}, {}
    if cfg.autoCraft then
        for _, p in ipairs(model.processes) do
            if p.machine == "ae2" then
                crafting[p.output] = call(cfg.bridge, "isCrafting", { name = cfg.resources[p.output].id }) == true
                craftableMap[p.output] = craftable(p.output)
            end
        end
    end

    -- 3. Plan.
    local actions, notes, projected = InsanitePlanner.plan(cfg, model, need, {
        stock = stock, pending = pending, busy = busy,
        reactors = reactors, crafting = crafting, craftable = craftableMap,
    })

    -- 4. Act.
    for _, a in ipairs(actions) do
        local p = a.process
        if p.machine == "reactor" then
            feedReactor(p, a.ops)
        elseif p.machine == "ae2" then
            craft(p, a.ops)
        else
            runBatch(p, a.ops)
        end
    end

    -- 5. Remember which recipe each machine holds (survives a reboot mid-batch).
    local saveState = {}
    for name, st in pairs(machineState) do
        if st.process then saveState[name] = st.process end
    end
    writeTableFile(cfg.stateFile, saveState)

    lastNotes, lastActions, lastStock, lastProjected = notes, actions, stock, projected
    lastError = nil
    render()
end

function Factory.runForever()
    local ok, err = pcall(Factory.init)
    if not ok then
        print("Insanite plugin disabled: " .. tostring(err))
        return
    end
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
