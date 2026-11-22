-- Insanite factory plugin: planning logic. Pure functions, no peripherals (unit-testable).
--
-- Model: every machine runs "processes" (recipes) that turn input resources into one output.
-- Reactors are processes too (fuel -> waste, per 1000 mB of reactant).
--
-- Ratios: computeNeeds() walks the recipe graph back from ONE kit (what an Insanite Block is
-- crafted from: 8 insanite + 8 inanite + 1 netherite block) and records how much of every
-- resource that takes. Those per-block numbers are the "proper ratios".
--
-- Reserves: each product's coverage = its ME stock / per-block need = "how many Insanite
-- Blocks' worth ME holds". Everything is kept at stockBlocks coverage, i.e. in recipe ratio.
--
-- Batch machines (pull): wanted work is sorted by coverage, lowest first, and greedily handed
-- machines and inputs, so the single reprocessor always makes whatever is furthest behind.
--
-- Reactors (locked rate): rateTargets() picks ONE plant rate (Insanite Blocks per tick) and
-- gives every reactor rate x its fuel per block, so the four burn in exact recipe ratio. The
-- rate follows how far the finished kit in ME is below target, and is capped so no reactor is
-- asked for more than it can actually burn: the yellorium reactors burn exactly as much as the
-- blutonium/verderium reactors can, and vice versa.

local Planner = {}

local HUGE = math.huge

local function clamp(value, lo, hi)
    if value < lo then return lo end
    if value > hi then return hi end
    return value
end

local function unitOf(def)
    return (def.kind == "fluid") and 1000 or 1
end
Planner.unitOf = unitOf

local function sortedKeys(t)
    local keys = {}
    for k, v in pairs(t or {}) do
        if v then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return keys
end

-- Build the process graph from config. Returns model, errors (list of strings).
function Planner.buildModel(cfg)
    local model = {
        resources = cfg.resources or {},
        processes = {},
        byId = {},
        producerOf = {},
        consumersOf = {},
        kit = cfg.kit or {},
    }
    local errors = {}

    local function add(p)
        if model.byId[p.id] then
            errors[#errors + 1] = "duplicate process id " .. tostring(p.id)
            return
        end
        if not model.resources[p.output] then
            errors[#errors + 1] = p.id .. ": unknown output resource " .. tostring(p.output)
            return
        end
        for _, inp in ipairs(p.inputs or {}) do
            if not model.resources[inp.res] then
                errors[#errors + 1] = p.id .. ": unknown input resource " .. tostring(inp.res)
                return
            end
        end
        if model.producerOf[p.output] then
            errors[#errors + 1] = p.output .. " has two producers (" .. model.producerOf[p.output].id .. ", " .. p.id .. ")"
            return
        end
        model.byId[p.id] = p
        model.processes[#model.processes + 1] = p
        model.producerOf[p.output] = p
        for _, inp in ipairs(p.inputs) do
            model.consumersOf[inp.res] = model.consumersOf[inp.res] or {}
            table.insert(model.consumersOf[inp.res], p)
        end
    end

    for i, src in ipairs(cfg.processes or {}) do
        local p = {}
        for k, v in pairs(src) do p[k] = v end
        p.order = i
        p.outQty = p.outQty or 1
        add(p)
    end

    for n, id in ipairs(sortedKeys(cfg.reactors)) do
        local r = cfg.reactors[id]
        local fuel, waste = model.resources[r.fuel], model.resources[r.waste]
        if not fuel or not waste then
            errors[#errors + 1] = id .. ": unknown fuel/waste resource"
        else
            add({
                id = id,
                machine = "reactor",
                reactor = id,
                rodControl = r.rodControl or "ratio",
                output = r.waste,
                outQty = unitOf(waste),
                inputs = { { res = r.fuel, qty = unitOf(fuel) } },
                order = #(cfg.processes or {}) + n,
            })
        end
    end

    local kitSize = 0
    for res, qty in pairs(model.kit) do
        kitSize = kitSize + 1
        if not model.resources[res] then
            errors[#errors + 1] = "kit: unknown resource " .. tostring(res)
        elseif type(qty) ~= "number" or qty <= 0 then
            errors[#errors + 1] = "kit: bad quantity for " .. res
        end
    end
    if kitSize == 0 then errors[#errors + 1] = "kit is empty" end
    return model, errors
end

-- Per-kit requirement of every resource, and operations of every process per kit.
function Planner.computeNeeds(model)
    local need, ops, visiting = {}, {}, {}
    local needOf

    local function opsOf(p)
        if ops[p.id] == nil then
            ops[p.id] = needOf(p.output) / p.outQty
        end
        return ops[p.id]
    end

    needOf = function(res)
        if need[res] ~= nil then return need[res] end
        if visiting[res] then error("recipe cycle through " .. res) end
        visiting[res] = true
        local total = model.kit[res] or 0
        for _, p in ipairs(model.consumersOf[res] or {}) do
            local pOps = opsOf(p)
            for _, inp in ipairs(p.inputs) do
                if inp.res == res then total = total + pOps * inp.qty end
            end
        end
        visiting[res] = nil
        need[res] = total
        return total
    end

    for res in pairs(model.resources) do needOf(res) end
    for _, p in ipairs(model.processes) do opsOf(p) end
    return need, ops
end

function Planner.coverage(need, stock, res)
    local n = need[res] or 0
    if n <= 0 then return HUGE end
    return (stock[res] or 0) / n
end

-- Insanite Blocks' worth of FINISHED kit items in ME (the produced ones: insanite, inanite).
function Planner.kitCoverage(model, stock)
    local cov = HUGE
    for res, qty in pairs(model.kit) do
        if model.producerOf[res] then cov = math.min(cov, (stock[res] or 0) / qty) end
    end
    return cov == HUGE and 0 or cov
end

-- Whole Insanite Blocks you could craft right now from ME (all kit items, incl. netherite).
function Planner.craftableBlocks(model, stock)
    local n = HUGE
    for res, qty in pairs(model.kit) do n = math.min(n, (stock[res] or 0) / qty) end
    return n == HUGE and 0 or math.floor(n)
end

-- Operations of p still wanted before its output reaches stockBlocks coverage.
local function opsWanted(cfg, need, projected, p)
    if (need[p.output] or 0) <= 0 then return 0 end
    local deficit = (cfg.stockBlocks or 2) * need[p.output] - (projected[p.output] or 0)
    if deficit <= 0 then return 0 end
    return math.ceil(deficit / p.outQty)
end

-- Most operations a batch machine can hold for process p (injector capacities, batch cap).
function Planner.machineCapacityOps(cfg, machine, p)
    local cap = cfg.maxBatchOps or 16
    for _, inp in ipairs(p.inputs) do
        local limit = machine.limits and machine.limits[inp.port]
        if limit then cap = math.min(cap, math.floor(limit / inp.qty)) end
    end
    return cap
end

-- Fuel (mB) a reactor should hold: enough for fuelLeadSeconds at its burn target, within
-- [fuelMinPct, fuelMaxPct] of capacity; 0 while its target is 0. "power" reactors keep the
-- plain band. Returns desired mB, or nil if no top-up is needed.
function Planner.desiredFuel(cfg, rodControl, info, target)
    local cap = info.fuelCapacity or 0
    local lo = cap * (cfg.fuelMinPct or 10) / 100
    local hi = cap * (cfg.fuelMaxPct or 80) / 100
    if rodControl == "power" then
        if info.fuelAmount < lo then return hi end
        return nil
    end
    if not target or target <= 0 then return nil end
    local desired = clamp(target * 20 * (cfg.fuelLeadSeconds or 600), lo, hi)
    if info.fuelAmount >= 0.9 * desired then return nil end
    return desired
end

-- One planning pass.
-- snap = {
--   stock      = { [res] = amount in ME (exportable) },
--   pending    = { [res] = amount inside batch machines, on its way to ME },
--   busy       = { [machineName] = reason string or nil },
--   reactors   = { [id] = { present, feedable, fuelAmount, fuelCapacity, wasteAmount } },
--   burnTarget = { [id] = mB/t from rateTargets },
-- }
-- Returns actions (list of { process, ops }), notes ({ [processId] = state text }), projected.
function Planner.plan(cfg, model, need, snap)
    local avail, projected = {}, {}
    for res in pairs(model.resources) do
        avail[res] = snap.stock[res] or 0
        projected[res] = avail[res] + ((snap.pending or {})[res] or 0)
    end

    local candidates, notes = {}, {}

    for _, p in ipairs(model.processes) do
        local cand = {
            p = p,
            cov = Planner.coverage(need, projected, p.output),
            wanted = opsWanted(cfg, need, projected, p),
            class = 1,
        }

        if p.machine == "reactor" then
            local r = (snap.reactors or {})[p.reactor]
            local target = (snap.burnTarget or {})[p.reactor]
            if not r or not r.present then
                notes[p.id] = "not connected"
            elseif not r.feedable then
                notes[p.id] = "no inlet port set"
            elseif (r.fuelCapacity or 0) <= 0 then
                notes[p.id] = "no fuel capacity reported"
            else
                local desired = Planner.desiredFuel(cfg, p.rodControl, r, target)
                if not desired then
                    notes[p.id] = (p.rodControl ~= "power" and (target or 0) <= 0) and "idle (rate 0)" or "fuel ok"
                else
                    local room = r.fuelCapacity - r.fuelAmount - (r.wasteAmount or 0)
                    local unit = p.inputs[1].qty
                    local perCycle = (unit == 1) and (cfg.maxFuelItemsPerCycle or 64)
                        or math.floor((cfg.maxFuelFluidPerCycle or 16000) / unit)
                    local short = math.floor((desired - r.fuelAmount) / 1000)
                    local fits = math.floor(room / 1000)
                    cand.cap = math.min(short, fits, perCycle)
                    cand.wanted = HUGE
                    if p.rodControl == "power" then cand.class = 0 end
                    if cand.cap < 1 then
                        notes[p.id] = (fits < 1) and "tank full of waste" or "fuel ok"
                        cand.cap = nil
                    end
                end
            end
        else
            local m = (cfg.machines or {})[p.machine]
            if not m then
                notes[p.id] = "machine not configured"
            elseif (snap.busy or {})[p.machine] then
                notes[p.id] = p.machine .. " " .. snap.busy[p.machine]
            else
                cand.cap = Planner.machineCapacityOps(cfg, m, p)
            end
        end

        if cand.cap then
            if cand.wanted <= 0 then
                notes[p.id] = "at target"
            else
                candidates[#candidates + 1] = cand
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.class ~= b.class then return a.class < b.class end
        if a.cov ~= b.cov then return a.cov < b.cov end
        return a.p.order < b.p.order
    end)

    local actions, taken = {}, {}
    for _, c in ipairs(candidates) do
        local p = c.p
        local exclusive = p.machine ~= "reactor"
        if exclusive and taken[p.machine] then
            notes[p.id] = "waiting (" .. p.machine .. " -> " .. taken[p.machine] .. ")"
        else
            local ops = math.min(c.wanted, c.cap)
            local short, shortOps = nil, HUGE
            for _, inp in ipairs(p.inputs) do
                local canDo = math.floor((avail[inp.res] or 0) / inp.qty)
                if canDo < shortOps then short, shortOps = inp.res, canDo end
            end
            ops = math.min(ops, shortOps)
            if ops >= 1 then
                for _, inp in ipairs(p.inputs) do
                    avail[inp.res] = avail[inp.res] - ops * inp.qty
                end
                if exclusive then taken[p.machine] = p.id end
                actions[#actions + 1] = { process = p, ops = ops }
                notes[p.id] = (p.machine == "reactor") and ("fuel +" .. ops) or ("start x" .. ops)
            else
                notes[p.id] = "needs " .. tostring(short)
            end
        end
    end

    return actions, notes, projected
end

-- Max plant pace in Insanite Blocks per game tick: the slowest machine with a known speed
-- (opsPerTick / its operations per block), derated by plantUtilization. plantBlocksPerHour
-- overrides it. 72000 ticks per hour.
function Planner.plantRate(cfg, model, ops)
    if (cfg.plantBlocksPerHour or 0) > 0 then return cfg.plantBlocksPerHour / 72000 end
    local rate = HUGE
    for name, m in pairs(cfg.machines or {}) do
        if m.opsPerTick and m.opsPerTick > 0 then
            local total = 0
            for _, p in ipairs(model.processes) do
                if p.machine == name then total = total + (ops[p.id] or 0) end
            end
            if total > 0 then rate = math.min(rate, m.opsPerTick / total) end
        end
    end
    if rate == HUGE then return 10 / 72000 end -- no machine speed known: assume 10 blocks/hour
    return rate * (cfg.plantUtilization or 0.9)
end

-- The locked reaction rate. Returns targets ({ [reactorId] = mB/t }) and detail:
--   rate   = common plant rate (blocks/tick)     demand = 0..1 from the kit reserve
--   kit    = finished kit in ME (blocks)          limit  = what is holding the rate down
--   reactors[id] = { cov, trim, share, capRate }
-- capacities[id] = a reactor's measured max burn (mB/t), when known (see rods.lua).
function Planner.rateTargets(cfg, model, need, ops, stock, plantMax, capacities)
    local K = cfg.stockBlocks or 2
    local kit = Planner.kitCoverage(model, stock)
    local demand = clamp((cfg.demandGain or 1) * (K - kit), 0, 1)
    local rate = plantMax * demand
    local limit = (demand >= 1) and "max pace" or ((demand <= 0) and "kit full" or "kit reserve")
    local limitKind = (demand >= 1) and "pace" or ((demand <= 0) and "full" or "reserve")
    local limitId = nil

    local maxTrim = cfg.maxTrim or 0.25
    local trimGain = cfg.trimGain or 0.25
    local overflow = cfg.overflowBlocks or 4

    local locked = {}
    for _, p in ipairs(model.processes) do
        if p.machine == "reactor" and p.rodControl ~= "power" then
            local cov = Planner.coverage(need, stock, p.output)
            local trim = clamp(1 + trimGain * (K - cov), 1 - maxTrim, 1 + maxTrim)
            locked[#locked + 1] = { id = p.reactor, output = p.output, cov = cov, trim = trim,
                share = (ops[p.id] or 0) * 1000 } -- mB of fuel per block

            -- A waste piling up means something downstream is blocked: slow everything.
            if overflow > 0 and cov > K then
                local cap = plantMax * clamp(1 - (cov - K) / overflow, 0, 1)
                if cap < rate then
                    rate, limit, limitKind, limitId = cap, "overflow " .. p.output, "overflow", p.output
                end
            end
        end
    end

    -- No reactor may be asked for more than it can burn; the others follow it down.
    for _, r in ipairs(locked) do
        local cap = capacities and capacities[r.id]
        if cap and r.share * r.trim > 0 then
            r.capacity = cap
            r.capRate = cap / (r.share * r.trim)
            if r.capRate < rate then
                rate, limit, limitKind, limitId = r.capRate, r.id .. " max burn", "capacity", r.id
            end
        end
    end

    -- unconstrained = what the kit reserve alone asks for; rate < unconstrained = plant slowed.
    local targets, detail = {}, { rate = rate, demand = demand, kit = kit, limit = limit,
        limitKind = limitKind, limitId = limitId, unconstrained = plantMax * demand, reactors = {} }
    for _, r in ipairs(locked) do
        targets[r.id] = rate * r.share * r.trim
        detail.reactors[r.id] = r
    end
    return targets, detail
end

-- Ratio deviation of each locked reactor's ACTUAL burn from a reference reactor.
-- pace_i = measured burn / fuel per block (the Insanite Blocks per tick that burn amounts to).
-- dev_i  = pace_i / pace_ref - 1: 0 means exactly in recipe ratio with the reference.
-- expected_i = trim_i / trim_ref - 1: the part of dev_i that trim asked for on purpose.
-- tracking_i = measured / own target - 1: how far the reactor is off what it was told.
-- The reference is cfg.referenceReactor if it is burning, else the first locked reactor that is.
-- measured = { [id] = mB/t }.
function Planner.deviations(cfg, detail, measured)
    local out = { reactors = {} }
    if not detail then return out end
    local function paceOf(id)
        local r = detail.reactors[id]
        if not r or r.share <= 0 then return 0 end
        return (measured[id] or 0) / r.share
    end

    local ref = cfg.referenceReactor
    if not (detail.reactors[ref] and paceOf(ref) > 0) then
        ref = nil
        for _, id in ipairs(sortedKeys(detail.reactors)) do
            if paceOf(id) > 0 then ref = id; break end
        end
    end
    out.ref = ref

    for id, r in pairs(detail.reactors) do
        local e = { pace = paceOf(id), target = detail.rate * r.share * r.trim, isRef = (id == ref) }
        if e.target > 0 then e.tracking = (measured[id] or 0) / e.target - 1 end
        if ref then
            e.dev = e.pace / paceOf(ref) - 1
            e.expected = r.trim / detail.reactors[ref].trim - 1
        end
        out.reactors[id] = e
    end
    return out
end

--region plant config check

local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local DEVICE_KEYS = { bridge = true, monitor = true, referenceReactor = true, machines = true, reactors = true }
local MACHINE_KEYS = { "ports", "output" }
local REACTOR_KEYS = { "fuel", "waste", "rodControl", "inlet", "outlet" }
local ROD_MODES = { "ratio", "power" }

local function q(v) return string.format("%q", tostring(v)) end

local function describe(v)
    if type(v) == "string" then return "the text " .. q(v) end
    if type(v) == "table" then return "a table" end
    return type(v) .. " " .. tostring(v)
end

-- Edit distance, for "did you mean ...?" on typos.
local function distance(a, b)
    a, b = a:lower(), b:lower()
    local prev = {}
    for j = 0, #b do prev[j] = j end
    for i = 1, #a do
        local cur = { [0] = i }
        for j = 1, #b do
            local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        end
        prev = cur
    end
    return prev[#b]
end

local function didYouMean(word, candidates)
    if type(word) ~= "string" then return "" end
    local best, bestD
    for _, c in ipairs(candidates) do
        local d = distance(word, c)
        if not bestD or d < bestD then best, bestD = c, d end
    end
    if best and bestD > 0 and bestD <= math.max(2, math.floor(#word / 3)) then
        return " Did you mean " .. best .. "?"
    end
    return ""
end

local function keysOf(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

local function quoted(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = q(v) end
    return table.concat(out, ", ")
end

-- Check the plant config (/insanite.conf) before anything runs. Every device must be defined
-- explicitly; false means "none". Returns errors (the plugin will not start) and warnings (it
-- will, but something needs attention). Each message says what is wrong, where, and the exact
-- line to add. `network` (optional) = { [peripheralName] = { type, ... } } from the live wired
-- network: it lets messages suggest real names and catch a wrong device in the wrong place.
function Planner.validatePlant(plant, defaults, network)
    local errors, warnings = {}, {}
    local function err(...) errors[#errors + 1] = table.concat({ ... }, "\n   ") end
    local function warn(...) warnings[#warnings + 1] = table.concat({ ... }, "\n   ") end
    local used = {} -- peripheral name -> config path that uses it

    if type(plant) ~= "table" then
        err("The plant config must be one table: { bridge = ..., monitor = ..., machines = { ... }, reactors = { ... } }.",
            "It is " .. describe(plant) .. ".")
        return errors, warnings
    end

    local resources = defaults.resources or {}
    local deviceTypes = defaults.deviceTypes or {}

    local function typesOf(name) return network and network[name] end
    local function hasType(name, spec)
        for _, t in ipairs(typesOf(name) or {}) do
            for _, want in ipairs(spec.types) do
                if t == want then return true end
            end
        end
        return false
    end
    -- Unused peripherals of the right kind on the network, for suggestions. Network names come
    -- before computer sides ("left", "bottom"): a side is usually something else's device, and
    -- for the ME Bridge a side is never usable. `reserved` = names already suggested in this
    -- message, so a template never suggests the same peripheral twice.
    local function candidates(spec, reserved)
        local named, sides = {}, {}
        if network then
            for _, name in ipairs(keysOf(network)) do
                if not used[name] and not (reserved and reserved[name]) and hasType(name, spec) then
                    if SIDES[name] then
                        if not spec.noSides then sides[#sides + 1] = name end
                    else
                        named[#named + 1] = name
                    end
                end
            end
        end
        for _, name in ipairs(sides) do named[#named + 1] = name end
        return named
    end
    local function example(key, spec, reserved)
        local found = candidates(spec, reserved)
        if found[1] and reserved then reserved[found[1]] = true end
        return key .. " = " .. (found[1] and q(found[1]) or ('"<' .. spec.what .. ' name>"')) .. ","
    end
    local function networkHint(spec)
        if not network then return nil end
        local found = candidates(spec)
        if #found > 0 then return spec.what .. "s on the network now: " .. table.concat(found, ", ") end
        return "No unused " .. spec.what .. " is on the network. Put a wired modem on it and right-click the modem (it turns red); chat shows its name."
    end

    -- One device reference: missing / false / wrong type / duplicate / not on network / wrong kind.
    -- opts.purpose = what it is for; opts.where = the table it goes in; opts.none = the line to
    -- use for "no such device" (nil when the device is required); opts.wrongHint(types) = extra hint.
    local function checkDevice(path, key, value, spec, opts)
        if value == nil then
            local lines = { path .. " is missing: " .. opts.purpose .. ".",
                "Add inside " .. opts.where .. ":   " .. example(key, spec) }
            if opts.none then lines[#lines + 1] = "or, " .. opts.none end
            lines[#lines + 1] = networkHint(spec)
            err(table.unpack(lines))
            return
        end
        if value == false then
            if not opts.none then
                err(path .. " = false, but this device is required: " .. opts.purpose .. ".",
                    "Set it inside " .. opts.where .. ":   " .. example(key, spec), networkHint(spec))
            end
            return
        end
        if type(value) ~= "string" or value == "" then
            err(path .. " must be a peripheral name in quotes" .. (opts.none and " (or false)" or "")
                .. ", but it is " .. describe(value) .. ".",
                "Example:   " .. example(key, spec))
            return
        end
        if used[value] then
            err(q(value) .. " is used for both " .. used[value] .. " and " .. path .. ".",
                "Every device needs its own peripheral; check which one " .. q(value) .. " really is.")
            return
        end
        used[value] = path
        if network then
            if not network[value] then
                warn(path .. " = " .. q(value) .. " is not on the wired network right now.",
                    "Check the wired modem on that " .. spec.what .. " is switched on (red) and its chunk is loaded.",
                    networkHint(spec))
            elseif not hasType(value, spec) then
                local is = (typesOf(value) or {})[1] or "unknown"
                err(path .. " = " .. q(value) .. " is a " .. is .. ", but it must be a " .. spec.what
                    .. " (" .. table.concat(spec.types, " or ") .. ").",
                    opts.wrongHint and opts.wrongHint(typesOf(value)) or networkHint(spec))
            end
        end
    end

    -- Top-level: unknown keys (typos) and tuning overrides of the wrong type.
    local known = {}
    for k in pairs(DEVICE_KEYS) do known[#known + 1] = k end
    for k in pairs(defaults) do known[#known + 1] = k end
    table.sort(known)
    for _, k in ipairs(keysOf(plant)) do
        if not DEVICE_KEYS[k] and defaults[k] == nil then
            warn(tostring(k) .. " is not a known setting and is ignored." .. didYouMean(tostring(k), known))
        elseif defaults[k] ~= nil and type(defaults[k]) ~= "table" and type(plant[k]) ~= type(defaults[k]) then
            err(tostring(k) .. " must be a " .. type(defaults[k]) .. " (default: " .. tostring(defaults[k])
                .. "), but it is " .. describe(plant[k]) .. ".")
        end
    end

    -- ME Bridge (only ever usable through its network name, never a side)
    local bridgeSpec = { types = deviceTypes.bridge.types, what = deviceTypes.bridge.what, noSides = true }
    if type(plant.bridge) == "string" and SIDES[plant.bridge] then
        err("bridge = " .. q(plant.bridge) .. " is a side of the computer, not a network name.",
            "Through a side, the bridge can't reach the injectors or reactor ports on the wired network.",
            "Put a wired modem on the ME Bridge, right-click it, and use the name chat shows:   "
                .. example("bridge", bridgeSpec))
        used[plant.bridge] = "bridge"
    else
        checkDevice("bridge", "bridge", plant.bridge, bridgeSpec, {
            purpose = "the ME Bridge every item and fluid moves through, by its wired-network name",
            where = "the top-level table" })
    end

    -- Status monitor
    checkDevice("monitor", "monitor", plant.monitor, deviceTypes.monitor, {
        purpose = "the monitor that shows the factory status screen",
        where = "the top-level table",
        none = "monitor = false,   for no status monitor" })

    -- Machines: every machine the recipes use, with every port those recipes load.
    local need = {} -- machine -> { ports = { port -> { resource labels } }, recipes = { ids } }
    for _, p in ipairs(defaults.processes or {}) do
        local m = need[p.machine] or { ports = {}, recipes = {} }
        need[p.machine] = m
        m.recipes[#m.recipes + 1] = p.id
        for _, inp in ipairs(p.inputs or {}) do
            m.ports[inp.port] = m.ports[inp.port] or {}
            local label = (resources[inp.res] or {}).label or inp.res
            local seen = false
            for _, l in ipairs(m.ports[inp.port]) do if l == label then seen = true end end
            if not seen then table.insert(m.ports[inp.port], label) end
        end
    end
    local machineNames = keysOf(need)

    local function machineTemplate(name, reserved)
        local mdef = (defaults.machines or {})[name] or {}
        local parts = {}
        for _, port in ipairs(keysOf(need[name].ports)) do
            local spec = (mdef.portTypes or {})[port] or { types = {}, what = "injector" }
            parts[#parts + 1] = example(port, spec, reserved):gsub(",$", "")
        end
        return name .. " = { ports = { " .. table.concat(parts, ", ") .. " }, output = false },"
    end

    if plant.machines == nil or plant.machines == false then
        local lines = { "machines is missing: the ports of the " .. #machineNames .. " machines the recipes run on.",
            "Add to the top-level table:", "machines = {" }
        local reserved = {}
        for _, name in ipairs(machineNames) do lines[#lines + 1] = "  " .. machineTemplate(name, reserved) end
        lines[#lines + 1] = "},"
        err(table.unpack(lines))
    elseif type(plant.machines) ~= "table" then
        err("machines must be a table, but it is " .. describe(plant.machines) .. ".")
    else
        for _, name in ipairs(keysOf(plant.machines)) do
            if not need[name] then
                err("machines." .. tostring(name) .. " is not a machine the recipes use (they use: "
                    .. table.concat(machineNames, ", ") .. ")." .. didYouMean(tostring(name), machineNames))
            end
        end
        for _, name in ipairs(machineNames) do
            local m = plant.machines[name]
            local mdef = (defaults.machines or {})[name] or {}
            local path = "machines." .. name
            if m == nil or m == false then
                err(path .. " is missing: the " .. name .. " runs the " .. table.concat(need[name].recipes, ", ")
                    .. " recipe" .. (#need[name].recipes > 1 and "s" or "") .. ".",
                    "Add inside machines:   " .. machineTemplate(name, {}))
            elseif type(m) ~= "table" then
                err(path .. " must be a table like { ports = { ... }, output = false }, but it is " .. describe(m) .. ".")
            else
                for _, k in ipairs(keysOf(m)) do
                    local ok = false
                    for _, want in ipairs(MACHINE_KEYS) do if k == want then ok = true end end
                    if not ok then
                        err(path .. "." .. tostring(k) .. " is not a machine setting (expected: ports, output)."
                            .. didYouMean(tostring(k), MACHINE_KEYS))
                    end
                end
                local portNames = keysOf(need[name].ports)
                if m.ports == nil or m.ports == false then
                    local parts, reserved = {}, {}
                    for _, port in ipairs(portNames) do
                        parts[#parts + 1] = example(port, (mdef.portTypes or {})[port] or { types = {}, what = "injector" }, reserved)
                    end
                    err(path .. ".ports is missing: the injector the plugin loads for each input.",
                        "Add inside " .. path .. ":   ports = { " .. table.concat(parts, " ") .. " },")
                elseif type(m.ports) ~= "table" then
                    err(path .. ".ports must be a table like { " .. table.concat(portNames, " = ..., ") .. " = ... }, but it is "
                        .. describe(m.ports) .. ".")
                else
                    for _, k in ipairs(keysOf(m.ports)) do
                        if not need[name].ports[k] then
                            err(path .. ".ports." .. tostring(k) .. " is not a port the " .. name .. "'s recipes use (expected: "
                                .. table.concat(portNames, ", ") .. ")." .. didYouMean(tostring(k), portNames))
                        end
                    end
                    for _, port in ipairs(portNames) do
                        local spec = (mdef.portTypes or {})[port] or { types = {}, what = "injector" }
                        checkDevice(path .. ".ports." .. port, port, m.ports[port], spec, {
                            purpose = "the " .. spec.what .. " that receives " .. table.concat(need[name].ports[port], " / "),
                            where = path .. ".ports",
                            wrongHint = function(types)
                                for _, other in ipairs(portNames) do
                                    local ospec = (mdef.portTypes or {})[other]
                                    if other ~= port and ospec then
                                        for _, t in ipairs(types or {}) do
                                            for _, w in ipairs(ospec.types) do
                                                if t == w and ospec.what ~= spec.what then
                                                    return "That is the " .. ospec.what .. ": did you swap " .. port .. " and " .. other .. "?"
                                                end
                                            end
                                        end
                                    end
                                end
                                return networkHint(spec)
                            end,
                        })
                    end
                end
                if mdef.outputType then
                    checkDevice(path .. ".output", "output", m.output, mdef.outputType, {
                        purpose = "the " .. mdef.outputType.what .. ", if the plugin should empty it into ME",
                        where = path,
                        none = "output = false,   if pipes or AE2 buses already empty it into ME" })
                end
            end
        end
    end

    -- Reactors
    local fuels = keysOf(defaults.reactions or {})
    local producers = {} -- waste -> { reactor ids }
    local function wasteForms(fuel)
        local out = {}
        for _, w in ipairs((defaults.reactions or {})[fuel] or {}) do
            local kind = (resources[w] or {}).kind
            out[#out + 1] = q(w) .. (kind == "fluid" and " (fluid, from a Fuel Injection Port in outlet mode)"
                or " (ingots, from a Solid Access Port in outlet mode)")
        end
        return table.concat(out, " or ")
    end

    if plant.reactors == nil or plant.reactors == false then
        local lines = { "reactors is missing: every reactor in the factory, by its computer-port name.",
            "Add to the top-level table (one line per reactor):", "reactors = {" }
        local found = candidates(deviceTypes.reactor)
        if #found == 0 then found = { "<reactor computer port name>" } end
        for _, id in ipairs(found) do
            lines[#lines + 1] = '  [' .. q(id) .. '] = { fuel = "<' .. table.concat(fuels, "|")
                .. '>", waste = "<see fuel>", rodControl = "ratio", inlet = false, outlet = false },'
        end
        lines[#lines + 1] = "},"
        err(table.unpack(lines))
    elseif type(plant.reactors) ~= "table" then
        err("reactors must be a table keyed by reactor name, but it is " .. describe(plant.reactors) .. ".")
    elseif next(plant.reactors) == nil then
        err("reactors is empty: define at least one reactor.",
            networkHint(deviceTypes.reactor))
    else
        for _, id in ipairs(keysOf(plant.reactors)) do
            local r = plant.reactors[id]
            local path = "reactors[" .. q(id) .. "]"
            if type(r) ~= "table" then
                err(path .. " must be a table like { fuel = ..., waste = ..., rodControl = ..., inlet = ..., outlet = ... }, but it is "
                    .. describe(r) .. ".")
            else
                -- the reactor itself
                if network then
                    if not network[id] then
                        warn(path .. ": no reactor called " .. q(id) .. " is on the wired network right now.",
                            "Check the wired modem on its Computer Port is switched on (red).",
                            networkHint(deviceTypes.reactor))
                    elseif not hasType(id, deviceTypes.reactor) then
                        err(path .. ": " .. q(id) .. " is a " .. ((typesOf(id) or {})[1] or "unknown")
                            .. ", not a Reactor Computer Port. Reactors are keyed by their computer-port name.",
                            networkHint(deviceTypes.reactor))
                    end
                    used[id] = path
                end

                for _, k in ipairs(keysOf(r)) do
                    local ok = false
                    for _, want in ipairs(REACTOR_KEYS) do if k == want then ok = true end end
                    if not ok then
                        err(path .. "." .. tostring(k) .. " is not a reactor setting (expected: "
                            .. table.concat(REACTOR_KEYS, ", ") .. ")." .. didYouMean(tostring(k), REACTOR_KEYS))
                    end
                end

                local fuelOk = (defaults.reactions or {})[r.fuel] ~= nil
                if r.fuel == nil then
                    err(path .. ".fuel is missing: what this reactor burns.",
                        "Add inside " .. path .. ':   fuel = "' .. (fuels[1] or "yellorium") .. '",   (one of: ' .. quoted(fuels) .. ")")
                elseif not fuelOk then
                    err(path .. ".fuel = " .. q(r.fuel) .. " is not a fuel this plant uses (use one of: " .. quoted(fuels) .. ")."
                        .. didYouMean(tostring(r.fuel), fuels))
                end

                if r.waste == nil then
                    err(path .. ".waste is missing: what its outlet gives.",
                        fuelOk and ("For fuel = " .. q(r.fuel) .. " that is " .. wasteForms(r.fuel) .. ".")
                            or "It depends on the fuel: yellorium -> cyanite, blutonium -> magentite, verderium -> rossinite.")
                elseif fuelOk then
                    local okWaste = false
                    for _, w in ipairs(defaults.reactions[r.fuel]) do if w == r.waste then okWaste = true end end
                    if not okWaste then
                        err(path .. ".waste = " .. q(r.waste) .. " doesn't match fuel = " .. q(r.fuel) .. ".",
                            r.fuel .. " burns into " .. wasteForms(r.fuel) .. ".")
                    else
                        producers[r.waste] = producers[r.waste] or {}
                        table.insert(producers[r.waste], id)
                    end
                end

                if r.rodControl == nil then
                    err(path .. '.rodControl is missing: "ratio" (burns at its share of the locked plant rate) or "power" (stays on the core\'s energy-demand control).',
                        "Add inside " .. path .. ':   rodControl = "ratio",')
                else
                    local okMode = false
                    for _, m in ipairs(ROD_MODES) do if r.rodControl == m then okMode = true end end
                    if not okMode then
                        err(path .. ".rodControl = " .. q(r.rodControl) .. ' must be "ratio" or "power".'
                            .. didYouMean(tostring(r.rodControl), ROD_MODES))
                    end
                end

                local fuelKind = fuelOk and (resources[r.fuel] or {}).kind
                local inletSpec = (fuelKind == "fluid") and deviceTypes.fluidAccessPort or deviceTypes.solidAccessPort
                checkDevice(path .. ".inlet", "inlet", r.inlet, inletSpec, {
                    purpose = "the " .. inletSpec.what .. " in INLET mode that the plugin feeds "
                        .. (fuelOk and r.fuel or "fuel") .. " into",
                    where = path,
                    none = "inlet = false,   while it isn't connected (no fuel is fed to this reactor then)" })

                local wasteKind = (resources[r.waste] or {}).kind
                local outletSpec = (wasteKind == "fluid") and deviceTypes.fluidAccessPort or deviceTypes.solidAccessPort
                checkDevice(path .. ".outlet", "outlet", r.outlet, outletSpec, {
                    purpose = "the " .. outletSpec.what .. " in OUTLET mode that gives "
                        .. tostring(r.waste or "its waste") .. ", if the plugin should empty it into ME",
                    where = path,
                    none = "outlet = false,   if pipes or AE2 buses already empty it into ME" })
            end
        end

        -- Each waste must come from one reactor; every waste the recipes need should have one.
        for _, waste in ipairs(keysOf(producers)) do
            local ids = producers[waste]
            if #ids > 1 then
                err("Reactors " .. table.concat(ids, " and ") .. " all have waste = " .. q(waste) .. ".",
                    "Each waste must come from exactly one reactor. Give the extra one(s) a different outlet form or fuel.")
            end
        end
        for _, fuel in ipairs(fuels) do
            for _, waste in ipairs(defaults.reactions[fuel]) do
                if not producers[waste] then
                    local users = {}
                    for _, p in ipairs(defaults.processes or {}) do
                        for _, inp in ipairs(p.inputs or {}) do
                            if inp.res == waste then users[#users + 1] = p.id end
                        end
                    end
                    if #users > 0 then
                        local kind = (resources[waste] or {}).kind
                        warn("No reactor has waste = " .. q(waste) .. ", which the " .. table.concat(users, " and ")
                            .. " recipe" .. (#users > 1 and "s need" or " needs") .. ". It can only come from ME stock.",
                            "To make it: give a " .. fuel .. " reactor a "
                                .. (kind == "fluid" and "Fuel Injection Port" or "Solid Access Port")
                                .. " in outlet mode and set its waste = " .. q(waste) .. ".")
                    end
                end
            end
        end
    end

    -- Reference reactor for the deviation column (optional).
    if plant.referenceReactor ~= nil and plant.referenceReactor ~= false
        and type(plant.reactors) == "table" and next(plant.reactors) ~= nil then -- else already reported
        if plant.reactors[plant.referenceReactor] == nil then
            err("referenceReactor = " .. q(plant.referenceReactor) .. " is not one of the reactors defined in reactors ("
                .. quoted(keysOf(type(plant.reactors) == "table" and plant.reactors or {})) .. ")."
                .. didYouMean(tostring(plant.referenceReactor), keysOf(type(plant.reactors) == "table" and plant.reactors or {})))
        end
    end

    return errors, warnings
end

--endregion

_G.InsanitePlanner = Planner
