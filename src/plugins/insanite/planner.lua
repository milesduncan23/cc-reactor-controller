-- Insanite factory plugin: planning logic. Pure functions, no peripherals (unit-testable).
--
-- Model: every machine runs "processes" (recipes) that turn input resources into one output.
-- Reactors are processes too (fuel -> waste, per 1000 mB of reactant).
--
-- Ratios: computeNeeds() walks the recipe graph back from ONE unit of the goal (an Insanite
-- Block) and records how much of every resource that unit consumes. Those per-block numbers
-- are the "proper ratios".
--
-- Scheduling (pull system): each product's coverage = (ME stock + amount already in machines)
-- / per-block need, i.e. "how many Insanite Blocks' worth do we hold". A product is wanted
-- while its coverage is below its target. Every pass, wanted work is sorted by coverage, lowest
-- first, and greedily handed machines and inputs. So the product that is furthest behind gets
-- the shared machine (one reprocessor runs five recipes) and any scarce shared input (e.g.
-- blutonium feeds the reprocessor, a reactor and the fluidizer). Over time every product is
-- held at the same coverage, which is exactly the recipe ratio.

local Planner = {}

local HUGE = math.huge

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
        goal = cfg.goal,
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
                mode = r.mode or "demand",
                output = r.waste,
                outQty = unitOf(waste),
                inputs = { { res = r.fuel, qty = unitOf(fuel) } },
                order = #(cfg.processes or {}) + n,
            })
        end
    end

    if not model.resources[model.goal or ""] then
        errors[#errors + 1] = "unknown goal resource " .. tostring(model.goal)
    end
    return model, errors
end

-- Per-goal-unit requirement of every resource, and operations of every process per goal unit.
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
        local total = (res == model.goal) and 1 or 0
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

-- Target coverage (in goal units) for a resource.
function Planner.targetBlocks(cfg, model, res)
    if res == model.goal then
        local goal = cfg.goalBlocks or 0
        return goal > 0 and goal or HUGE
    end
    return cfg.bufferBlocks or 2
end

function Planner.coverage(need, projected, res)
    local n = need[res] or 0
    if n <= 0 then return HUGE end
    return (projected[res] or 0) / n
end

-- Operations of p still wanted before its output reaches target (HUGE = unbounded).
local function opsWanted(cfg, model, need, projected, p)
    if (need[p.output] or 0) <= 0 then return 0 end
    local target = Planner.targetBlocks(cfg, model, p.output)
    if target == HUGE then return HUGE end
    local deficit = target * need[p.output] - (projected[p.output] or 0)
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

-- One planning pass.
-- snap = {
--   stock     = { [res] = amount in ME (exportable) },
--   pending   = { [res] = amount already inside machines, on its way to ME },
--   busy      = { [machineName] = reason string or nil },
--   reactors  = { [id] = { present, feedable, fuelAmount, fuelCapacity, wasteAmount } },
--   crafting  = { [res] = true while an AE2 job for it is running },
--   craftable = { [res] = false when AE2 has no pattern },
-- }
-- Returns actions (list of { process, ops }) and notes ({ [processId] = human-readable state }).
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
            wanted = opsWanted(cfg, model, need, projected, p),
            class = 1,
        }

        if p.machine == "reactor" then
            local r = (snap.reactors or {})[p.reactor]
            local unit = p.inputs[1].qty
            if not r or not r.present then
                notes[p.id] = "not connected"
            elseif not r.feedable then
                notes[p.id] = "no inlet port set"
            elseif (r.fuelCapacity or 0) <= 0 then
                notes[p.id] = "no fuel capacity reported"
            elseif r.fuelAmount >= r.fuelCapacity * (cfg.fuelLowPct or 40) / 100 then
                notes[p.id] = "fuel ok"
            else
                local room = r.fuelCapacity * (cfg.fuelHighPct or 80) / 100 - r.fuelAmount - (r.wasteAmount or 0)
                local perCycle = (unit == 1) and (cfg.maxFuelItemsPerCycle or 64)
                    or math.floor((cfg.maxFuelFluidPerCycle or 16000) / unit)
                cand.cap = math.min(math.floor(room / 1000), perCycle)
                if p.mode == "always" then
                    cand.class = 0      -- power reactors are fed first, whatever the product stock
                    cand.wanted = HUGE
                end
                if cand.cap < 1 then
                    notes[p.id] = "tank full of waste"
                    cand.cap = nil
                end
            end
        elseif p.machine == "ae2" then
            if not cfg.autoCraft then
                notes[p.id] = "autoCraft off"
            elseif (snap.crafting or {})[p.output] then
                notes[p.id] = "AE2 crafting"
            elseif (snap.craftable or {})[p.output] == false then
                notes[p.id] = "no AE2 pattern"
            else
                cand.cap = cfg.maxCraftPerRequest or 4
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
        local exclusive = p.machine ~= "reactor" and p.machine ~= "ae2"
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
                notes[p.id] = "start x" .. ops
            else
                notes[p.id] = "needs " .. tostring(short)
            end
        end
    end

    return actions, notes, projected
end

-- Plant pace in Insanite Blocks per game tick: the slowest machine with a known speed
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

-- Burn-rate target (mB of fuel per tick) for every reactor whose rods follow waste demand.
-- nominal = plant rate x this reactor's fuel per block (one reactor op = 1000 mB reactant), so
-- the reactors burn in exactly the recipe ratio. Each is then scaled by how many blocks' worth
-- of its waste ME holds: 1x at bufferBlocks, faster below, slower above, 0 at
-- bufferBlocks + 1/rateGain.
function Planner.rateTargets(cfg, model, need, ops, stock, plantRate)
    local targets, detail = {}, {}
    for _, p in ipairs(model.processes) do
        if p.machine == "reactor" then
            local r = (cfg.reactors or {})[p.reactor]
            if r and (r.rodControl == "waste" or r.rodControl == "waste+power") then
                local nominal = plantRate * (ops[p.id] or 0) * 1000
                local held = Planner.coverage(need, stock, p.output)
                local mult = 1 + (cfg.rateGain or 0.5) * ((cfg.bufferBlocks or 2) - held)
                mult = math.max(0, math.min(cfg.rateMaxMult or 3, mult))
                targets[p.reactor] = nominal * mult
                detail[p.reactor] = { nominal = nominal, mult = mult, held = held }
            end
        end
    end
    return targets, detail
end

_G.InsanitePlanner = Planner
