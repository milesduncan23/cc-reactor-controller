-- Insanite factory plugin: planning logic. Pure functions, no peripherals (unit-testable).
--
-- Model: every machine runs "processes" (recipes) that turn input resources into one output.
--   * batch machines (reprocessor, fluidizer) are loaded by the plugin
--   * AE2 crafts: only liquid cyanite and liquid magentite, and only when enabled
--   * reactors: fuel -> waste, per 1000 mB of reactant. Reactors with the same waste form one
--     pool (e.g. R6 + R8 -> cyanite) that shares that waste's production.
-- Fuel is NOT planned: the player's own ME importer refuels the reactors.
--
-- Ratios: computeNeeds() walks the recipe graph back from ONE kit (what an Insanite Block is
-- crafted from: 8 insanite + 8 inanite + 1 netherite block) and records how much of every
-- resource that takes. Those per-block numbers are the "proper ratios".
--
-- Reserves: each product's coverage = its ME stock / per-block need = "how many Insanite
-- Blocks' worth ME holds". Everything is kept at stockBlocks coverage, i.e. in recipe ratio.
--
-- Batch machines and crafts (pull): wanted work is sorted by coverage, lowest first, and
-- greedily handed machines and inputs, so the single reprocessor always makes whatever is
-- furthest behind and a scarce shared input goes to the product that needs it most.
--
-- Reactors (locked rate): rateTargets() picks ONE plant rate (Insanite Blocks per tick) and
-- gives every "ratio" reactor pool rate x its fuel per block, so those pools burn in exact recipe
-- ratio. "stock" pools (e.g. the uranium reactors -> cyanite) are decoupled: they fill ME with
-- their waste up to a cap from the config and are not part of the lock.
-- The rate follows how far the finished kit in ME is below target, and is capped so no pool is
-- asked for more than it can burn: the cyanite reactors burn exactly as much as the blutonium
-- and verderium reactors can, and vice versa. Inside a pool, the target is split evenly, except
-- that a member at its max burn is held there and the others take the rest.

local Planner = {}

local HUGE = math.huge

-- The only things the plugin may ever ask AE2 to craft. Anything else is refused here and in
-- the factory, whatever the config says.
Planner.ALLOWED_CRAFTS = { cyanite_fluid = true, magentite_fluid = true }

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

local function shortName(id)
    return (tostring(id):gsub("BigReactors%-Reactor_", "R"))
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
        pools = {},        -- waste -> reactor pool process
        poolOf = {},       -- reactorId -> pool process
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

    local order = 0
    for _, src in ipairs(cfg.processes or {}) do
        local p = {}
        for k, v in pairs(src) do p[k] = v end
        order = order + 1
        p.order = order
        p.outQty = p.outQty or 1
        add(p)
    end

    -- AE2 crafts: only allowed ones, only when enabled in the plant config.
    for _, res in ipairs(sortedKeys(cfg.crafts)) do
        local c = cfg.crafts[res]
        if Planner.ALLOWED_CRAFTS[res] and (cfg.autocraft or {})[res] == true then
            order = order + 1
            local inputs = {}
            for _, inp in ipairs(c.inputs or {}) do inputs[#inputs + 1] = { res = inp.res, qty = inp.qty } end
            add({ id = "craft " .. res, machine = "ae2", output = res, outQty = c.outQty or 1,
                inputs = inputs, order = order })
        end
    end

    -- Reactor pools: every reactor with the same waste produces it together.
    local members = {}
    for _, id in ipairs(sortedKeys(cfg.reactors)) do
        local r = cfg.reactors[id]
        local fuel, waste = model.resources[r.fuel], model.resources[r.waste]
        if not fuel or not waste then
            errors[#errors + 1] = id .. ": unknown fuel/waste resource"
        else
            members[r.waste] = members[r.waste] or { fuel = r.fuel, ids = {} }
            if members[r.waste].fuel ~= r.fuel then
                errors[#errors + 1] = id .. ": reactors making " .. r.waste .. " burn different fuels"
            end
            table.insert(members[r.waste].ids, id)
        end
    end
    for _, waste in ipairs(sortedKeys(members)) do
        local m = members[waste]
        local rodControl, isStock = {}, false
        for _, id in ipairs(m.ids) do
            rodControl[id] = cfg.reactors[id].rodControl or "ratio"
            if rodControl[id] == "stock" then isStock = true end
        end
        local label = {}
        for _, id in ipairs(m.ids) do label[#label + 1] = shortName(id) end
        order = order + 1
        local pool = {
            id = "reactors " .. waste,
            label = table.concat(label, "+"),
            machine = "reactor",
            members = m.ids,
            rodControl = rodControl,
            stock = isStock,
            output = waste,
            outQty = unitOf(model.resources[waste]),
            inputs = { { res = m.fuel, qty = unitOf(model.resources[m.fuel]) } },
            order = order,
        }
        add(pool)
        if model.byId[pool.id] == pool then
            model.pools[waste] = pool
            for _, id in ipairs(m.ids) do model.poolOf[id] = pool end
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
-- (A reactor pool's ops are in units of 1000 mB of fuel.)
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

-- One planning pass over the batch machines and AE2 crafts (reactors aren't planned here).
-- snap = {
--   stock     = { [res] = amount in ME (exportable) },
--   pending   = { [res] = amount inside batch machines, on its way to ME },
--   busy      = { [machineName] = reason string or nil },
--   running   = { [machineName] = process id it holds, while busy },
--   crafting  = { [res] = true while an AE2 job for it is running },
--   craftsStopped = true while the machines stop button is on (no AE2 requests),
--   craftable = { [res] = false when AE2 has no pattern for it },
-- }
-- Returns actions (list of { process, ops }), notes ({ [processId] = state text }), projected.
--
-- A job is only planned for whole operations ME holds EVERY input for. Priority recipes
-- (priority = true in the recipe, e.g. blutonium) go before everything else, and while one is
-- below target and its machine is free or already running it, it holds its inputs (up to one
-- full load) even when there isn't enough yet for one operation: lower-priority recipes and AE2
-- crafts only get what's left over.
function Planner.plan(cfg, model, need, snap)
    local avail, projected = {}, {}
    for res in pairs(model.resources) do
        avail[res] = snap.stock[res] or 0
        projected[res] = avail[res] + ((snap.pending or {})[res] or 0)
    end

    local candidates, notes, holds = {}, {}, {}

    for _, p in ipairs(model.processes) do
        if p.machine ~= "reactor" then
            local cand = {
                p = p,
                cov = Planner.coverage(need, projected, p.output),
                wanted = opsWanted(cfg, need, projected, p),
            }
            if p.machine == "ae2" then
                local fluid = (model.resources[p.output] or {}).kind == "fluid"
                if not Planner.ALLOWED_CRAFTS[p.output] then
                    notes[p.id] = "not allowed"
                elseif snap.craftsStopped then
                    notes[p.id] = "crafts stopped"
                elseif (snap.crafting or {})[p.output] then
                    notes[p.id] = "AE2 crafting"
                elseif (snap.craftable or {})[p.output] == false then
                    notes[p.id] = "no AE2 pattern"
                else
                    local most = fluid and (cfg.maxCraftFluid or 16000) or (cfg.maxCraftItems or 64)
                    cand.cap = math.max(1, math.floor(most / p.outQty))
                end
            else
                local m = (cfg.machines or {})[p.machine]
                if not m then
                    notes[p.id] = "machine not configured"
                elseif (snap.busy or {})[p.machine] then
                    notes[p.id] = p.machine .. " " .. snap.busy[p.machine]
                    -- Already running a priority recipe: it keeps first claim on its inputs.
                    if p.priority and (snap.running or {})[p.machine] == p.id and cand.wanted > 0 then
                        holds[#holds + 1] = { p = p, ops = math.min(cand.wanted, Planner.machineCapacityOps(cfg, m, p)) }
                    end
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
    end

    table.sort(candidates, function(a, b)
        if (a.p.priority and true or false) ~= (b.p.priority and true or false) then return a.p.priority == true end
        if a.cov ~= b.cov then return a.cov < b.cov end
        return a.p.order < b.p.order
    end)

    -- Held inputs are out of reach for everything planned after the recipe holding them.
    local heldFor = {}
    local function hold(p, ops)
        for _, inp in ipairs(p.inputs) do
            local k = math.min(avail[inp.res] or 0, ops * inp.qty)
            if k > 0 then
                avail[inp.res] = avail[inp.res] - k
                heldFor[inp.res] = heldFor[inp.res] or p.id
            end
        end
    end
    for _, h in ipairs(holds) do hold(h.p, h.ops) end

    local actions, taken = {}, {}
    for _, c in ipairs(candidates) do
        local p = c.p
        local exclusive = p.machine ~= "ae2"
        if exclusive and taken[p.machine] then
            notes[p.id] = "waiting (" .. p.machine .. " -> " .. taken[p.machine] .. ")"
        else
            local full = math.min(c.wanted, c.cap)
            local short, shortOps = nil, HUGE
            for _, inp in ipairs(p.inputs) do
                local canDo = math.floor((avail[inp.res] or 0) / inp.qty)
                if canDo < shortOps then short, shortOps = inp.res, canDo end
            end
            local ops = math.min(full, shortOps)
            if ops >= 1 then
                for _, inp in ipairs(p.inputs) do
                    avail[inp.res] = avail[inp.res] - ops * inp.qty
                end
                if exclusive then taken[p.machine] = p.id end
                actions[#actions + 1] = { process = p, ops = ops }
                if p.machine == "ae2" then
                    local def = model.resources[p.output]
                    local amount = ops * p.outQty
                    notes[p.id] = "request " .. ((def.kind == "fluid") and string.format("%.1fB", amount / 1000) or tostring(amount))
                else
                    notes[p.id] = "start x" .. ops
                end
            elseif heldFor[short] and heldFor[short] ~= p.id then
                notes[p.id] = "needs " .. tostring(short) .. " (held for " .. heldFor[short] .. ")"
            else
                notes[p.id] = "needs " .. tostring(short)
            end
            -- A priority recipe holds what it would still load, even short of one operation.
            if p.priority then hold(p, full - math.max(ops, 0)) end
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

-- Split a pool's target among its members: evenly, except a member whose known max burn is
-- below its even portion is held at that max and the rest is shared by the others.
local function splitPool(total, ids, caps)
    local alloc, fixed = {}, {}
    local remaining, open = total, #ids
    local changed = true
    while changed and open > 0 do
        changed = false
        local each = remaining / open
        for _, id in ipairs(ids) do
            if not fixed[id] and caps[id] and caps[id] < each then
                alloc[id], fixed[id] = caps[id], true
                remaining, open, changed = remaining - caps[id], open - 1, true
            end
        end
    end
    for _, id in ipairs(ids) do
        if not fixed[id] then alloc[id] = remaining / math.max(open, 1) end
    end
    return alloc
end

-- The locked reaction rate. Returns targets ({ [reactorId] = mB/t }) and detail:
--   rate   = common plant rate (blocks/tick)     demand = 0..1 from the kit reserve
--   kit    = finished kit in ME (blocks)          limit  = what is holding the rate down
--   unconstrained = what the kit reserve alone asks for (rate < unconstrained = slowed)
--   pools[waste]  = { label, members, cov, trim, share (mB fuel/block), capacity, capRate }
--   reactors[id]  = { pool = waste, trim, cov, share (this member's mB fuel/block), capacity }
-- capacities[id] = a reactor's measured max burn (mB/t), when known (see rods.lua).
-- stockState = table the caller keeps between calls (stock pools' hysteresis state).
-- Stock pools are reported in detail.stockPools[waste] = { label, members, cap, have, state,
-- fuel, reserve, maxBurn }, and their reactors in detail.reactors with mode = "stock".
Planner.FULL_BURN = 1e9 -- "as hard as it can": rods fully out
function Planner.rateTargets(cfg, model, need, ops, stock, plantMax, capacities, stockState)
    capacities = capacities or {}
    stockState = stockState or {}
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

    local pools = {}
    for _, p in ipairs(model.processes) do
        if p.machine == "reactor" and not p.stock then
            local ratioIds = {}
            for _, id in ipairs(p.members) do
                if p.rodControl[id] ~= "power" then ratioIds[#ratioIds + 1] = id end
            end
            if #ratioIds > 0 then
                local cov = Planner.coverage(need, stock, p.output)
                local pool = {
                    waste = p.output, label = p.label, members = ratioIds, cov = cov,
                    trim = clamp(1 + trimGain * (K - cov), 1 - maxTrim, 1 + maxTrim),
                    share = (ops[p.id] or 0) * 1000, -- mB of fuel per block, whole pool
                }
                pools[#pools + 1] = pool

                -- A waste piling up means something downstream is blocked: slow everything.
                if overflow > 0 and cov > K then
                    local cap = plantMax * clamp(1 - (cov - K) / overflow, 0, 1)
                    if cap < rate then
                        rate, limit, limitKind, limitId = cap, "overflow " .. p.output, "overflow", p.output
                    end
                end
            end
        end
    end

    -- No pool may be asked for more than all its members together can burn; the others follow.
    for _, pool in ipairs(pools) do
        local total, known = 0, true
        for _, id in ipairs(pool.members) do
            if capacities[id] then total = total + capacities[id] else known = false end
        end
        if known and pool.share * pool.trim > 0 then
            pool.capacity = total
            pool.capRate = total / (pool.share * pool.trim)
            if pool.capRate < rate then
                rate, limit, limitKind, limitId = pool.capRate, pool.label .. " max burn", "capacity", pool.waste
            end
        end
    end

    local targets = {}
    local detail = { rate = rate, demand = demand, kit = kit, limit = limit, limitKind = limitKind,
        limitId = limitId, unconstrained = plantMax * demand, pools = {}, reactors = {}, stockPools = {} }
    for _, pool in ipairs(pools) do
        local poolTarget = rate * pool.share * pool.trim
        local alloc = splitPool(poolTarget, pool.members, capacities)
        for _, id in ipairs(pool.members) do
            targets[id] = alloc[id]
            -- this member's slice of the pool's fuel per block (alloc / rate / trim)
            local fraction = (poolTarget > 0) and (alloc[id] / poolTarget) or (1 / #pool.members)
            detail.reactors[id] = { pool = pool.waste, mode = "ratio", trim = pool.trim, cov = pool.cov,
                share = pool.share * fraction, capacity = capacities[id] }
        end
        detail.pools[pool.waste] = pool
    end

    -- Stock pools: decoupled from the lock. Each fills ME with its waste up to its cap
    -- (stockCaps), burning flat out (or at stockMaxBurn for the whole pool), with hysteresis:
    -- it stops at the cap and restarts once ME is stockTaperPct below it. It also stops while ME
    -- holds less of its fuel than stockFuelFloor (plant config), resuming stockFuelResumePct
    -- above it, so it can't burn through fuel you need elsewhere.
    for _, p in ipairs(model.processes) do
        if p.machine == "reactor" and p.stock then
            local ids = {}
            for _, id in ipairs(p.members) do
                if p.rodControl[id] == "stock" then ids[#ids + 1] = id end
            end
            local cap = (cfg.stockCaps or {})[p.output] or 0
            local have = stock[p.output] or 0
            local restartAt = cap * (1 - (cfg.stockTaperPct or 10) / 100)
            local state = stockState[p.output] or "filling"
            if have >= cap then state = "at cap" elseif have <= restartAt then state = "filling" end

            -- Fuel floor from the plant config (stockFuelFloor): stop while ME holds less of this
            -- pool's fuel than that, resume stockFuelResumePct above it.
            local fuel = p.inputs[1].res
            local reserve = tonumber((cfg.stockFuelFloor or {})[p.output]) or 0
            local fuelHave = stock[fuel] or 0
            local hold = stockState[p.output .. ":fuel"] == true
            if fuelHave < reserve then
                hold = true
            elseif fuelHave >= reserve * (1 + (cfg.stockFuelResumePct or 5) / 100) then
                hold = false
            end
            stockState[p.output], stockState[p.output .. ":fuel"] = state, hold

            local maxBurn = (cfg.stockMaxBurn or {})[p.output]
            if type(maxBurn) ~= "number" or maxBurn <= 0 then maxBurn = nil end
            local alloc = {}
            if state == "filling" and not hold then
                if maxBurn then
                    alloc = splitPool(maxBurn, ids, capacities)
                else
                    for _, id in ipairs(ids) do alloc[id] = Planner.FULL_BURN end
                end
            end
            local share = (ops[p.id] or 0) * 1000
            for _, id in ipairs(ids) do
                targets[id] = alloc[id] or 0
                detail.reactors[id] = { pool = p.output, mode = "stock", trim = 1, share = share / #ids,
                    capacity = capacities[id] }
            end
            detail.stockPools[p.output] = { waste = p.output, label = p.label, members = ids, cap = cap,
                have = have, restartAt = restartAt, state = hold and "holding" or state, fuel = fuel,
                reserve = reserve, maxBurn = maxBurn }
        end
    end
    return targets, detail
end

-- Ratio deviation of each pool's ACTUAL burn from the reference reactor's pool.
-- pace = pool's measured burn / its fuel per block (the Insanite Blocks per tick it amounts to).
-- dev  = pace / pace_ref - 1: 0 means exactly in recipe ratio with the reference.
-- expected = trim / trim_ref - 1: the part of dev that trim asked for on purpose.
-- Per reactor: its pool's dev, plus tracking = measured / own target - 1.
-- The reference is the pool of cfg.referenceReactor if it is burning, else the first burning one.
-- measured = { [reactorId] = mB/t }.
function Planner.deviations(cfg, detail, measured)
    local out = { reactors = {}, pools = {} }
    if not detail then return out end
    local function paceOf(pool)
        if pool.share <= 0 then return 0 end
        local sum = 0
        for _, id in ipairs(pool.members) do sum = sum + (measured[id] or 0) end
        return sum / pool.share
    end

    local refPool
    local refId = cfg.referenceReactor
    local refEntry = refId and detail.reactors[refId]
    local refCandidate = refEntry and detail.pools[refEntry.pool] -- nil for stock/power reactors
    if refCandidate and paceOf(refCandidate) > 0 then refPool = refCandidate end
    if not refPool then
        for _, waste in ipairs(sortedKeys(detail.pools)) do
            if paceOf(detail.pools[waste]) > 0 then refPool = detail.pools[waste]; break end
        end
    end
    out.ref = refPool and refPool.waste
    out.refLabel = refPool and refPool.label

    for waste, pool in pairs(detail.pools) do
        local e = { pace = paceOf(pool), isRef = (pool == refPool) }
        if refPool then
            e.dev = e.pace / paceOf(refPool) - 1
            e.expected = pool.trim / refPool.trim - 1
        end
        out.pools[waste] = e
    end
    for id, r in pairs(detail.reactors) do
        if r.mode == "stock" then
            out.reactors[id] = { stock = true, measured = measured[id] or 0 }
        else
            local pe = out.pools[r.pool] or {}
            local target = detail.rate * r.share * r.trim
            local e = { dev = pe.dev, expected = pe.expected, isRef = pe.isRef, target = target,
                measured = measured[id] or 0 }
            if target > 0 then e.tracking = (measured[id] or 0) / target - 1 end
            out.reactors[id] = e
        end
    end
    return out
end

--region plant config check

local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local DEVICE_KEYS = { bridge = true, monitor = true, referenceReactor = true, machines = true, reactors = true,
    autocraft = true, stockCaps = true, stockMaxBurn = true, stockFuelFloor = true }
local MACHINE_KEYS = { "ports", "output" }
local REACTOR_KEYS = { "fuel", "waste", "rodControl", "outlet" }
local RETIRED_REACTOR_KEYS = { inlet = "fuel is fed by your own ME importer, not the plugin" }
local ROD_MODES = { "ratio", "stock", "power" }
local ROD_MODE_HELP = '"ratio" (burns at its share of the locked plant rate), "stock" (fills ME with its waste up to '
    .. 'stockCaps, outside the lock) or "power" (stays on the core\'s energy-demand control)'

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
                .. '>", waste = "<see fuel>", rodControl = "ratio", outlet = false },'
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
                err(path .. " must be a table like { fuel = ..., waste = ..., rodControl = ..., outlet = ... }, but it is "
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
                    if RETIRED_REACTOR_KEYS[k] then
                        ok = true
                        warn(path .. "." .. k .. " is no longer used (" .. RETIRED_REACTOR_KEYS[k] .. ").",
                            "You can delete that line from " .. path .. ".")
                    end
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
                            or "It depends on the fuel: uranium or yellorium -> cyanite, blutonium -> magentite, verderium -> rossinite.")
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
                    err(path .. ".rodControl is missing: " .. ROD_MODE_HELP .. ".",
                        "Add inside " .. path .. ':   rodControl = "ratio",')
                else
                    local okMode = false
                    for _, m in ipairs(ROD_MODES) do if r.rodControl == m then okMode = true end end
                    if not okMode then
                        err(path .. ".rodControl = " .. q(r.rodControl) .. ' must be "ratio", "stock" or "power".'
                            .. didYouMean(tostring(r.rodControl), ROD_MODES))
                    end
                end

                local wasteKind = (resources[r.waste] or {}).kind
                local outletSpec = (wasteKind == "fluid") and deviceTypes.fluidAccessPort or deviceTypes.solidAccessPort
                checkDevice(path .. ".outlet", "outlet", r.outlet, outletSpec, {
                    purpose = "the " .. outletSpec.what .. " in OUTLET mode that gives "
                        .. tostring(r.waste or "its waste") .. ", if the plugin should empty it into ME",
                    where = path,
                    none = "outlet = false,   if pipes or AE2 buses already empty it into ME" })
            end
        end

    end

    -- Stock pools: every reactor making one waste must agree on "stock", and each stock waste
    -- needs a cap. stockMaxBurn (optional) caps the pool's total burn.
    local stockWastes, stockFuel = {}, {}
    if type(plant.reactors) == "table" then
        local modesByWaste = {}
        for _, id in ipairs(keysOf(plant.reactors)) do
            local r = plant.reactors[id]
            if type(r) == "table" and type(r.waste) == "string" and type(r.rodControl) == "string" then
                modesByWaste[r.waste] = modesByWaste[r.waste] or {}
                table.insert(modesByWaste[r.waste], { id = id, mode = r.rodControl, fuel = r.fuel })
            end
        end
        for _, waste in ipairs(keysOf(modesByWaste)) do
            local list, stockIds, otherIds = modesByWaste[waste], {}, {}
            for _, e in ipairs(list) do
                if e.mode == "stock" then
                    stockIds[#stockIds + 1] = shortName(e.id)
                    if type(e.fuel) == "string" then stockFuel[waste] = e.fuel end
                elseif e.mode == "ratio" then otherIds[#otherIds + 1] = shortName(e.id) end
            end
            if #stockIds > 0 and #otherIds > 0 then
                err("Reactors making " .. q(waste) .. " disagree: " .. table.concat(stockIds, "+")
                    .. (#stockIds > 1 and ' are' or ' is') .. ' "stock" but '
                    .. table.concat(otherIds, "+") .. (#otherIds > 1 and ' are' or ' is') .. ' "ratio".',
                    "Reactors that share a waste work as one pool: give them all the same rodControl.")
            elseif #stockIds > 0 then
                stockWastes[waste] = table.concat(stockIds, "+")
            end
        end
    end
    local function stockExample(waste)
        local kind = (resources[waste] or {}).kind
        return waste .. " = " .. (kind == "fluid" and "64000" or "4096") .. ","
            .. (kind == "fluid" and "   (mB)" or "   (ingots)")
    end
    if next(stockWastes) then
        if plant.stockCaps == nil or plant.stockCaps == false then
            local lines = { "stockCaps is missing: how much of each \"stock\" reactor's waste to keep in ME.",
                "Add to the top-level table:   stockCaps = {" }
            for _, waste in ipairs(keysOf(stockWastes)) do
                local several = stockWastes[waste]:find("+", 1, true) ~= nil
                lines[#lines + 1] = "  " .. stockExample(waste) .. "   -- " .. stockWastes[waste]
                    .. (several and " burn" or " burns") .. " until ME holds this"
            end
            lines[#lines + 1] = "},"
            err(table.unpack(lines))
        elseif type(plant.stockCaps) ~= "table" then
            err("stockCaps must be a table like { cyanite = 4096 }, but it is " .. describe(plant.stockCaps) .. ".")
        else
            for _, waste in ipairs(keysOf(stockWastes)) do
                local v = plant.stockCaps[waste]
                if v == nil then
                    local several = stockWastes[waste]:find("+", 1, true) ~= nil
                    err("stockCaps." .. waste .. " is missing: how much " .. waste .. " " .. stockWastes[waste]
                        .. (several and " keep" or " keeps") .. " in ME ("
                        .. (several and "they burn" or "it burns") .. " until ME holds this, then stop" .. (several and "" or "s") .. ").",
                        "Add inside stockCaps:   " .. stockExample(waste))
                elseif type(v) ~= "number" or v <= 0 then
                    err("stockCaps." .. waste .. " must be a positive number, but it is " .. describe(v) .. ".")
                end
            end
            for _, waste in ipairs(keysOf(plant.stockCaps)) do
                if not stockWastes[waste] then
                    warn("stockCaps." .. tostring(waste) .. " is ignored: no reactor with rodControl = \"stock\" makes "
                        .. tostring(waste) .. "." .. didYouMean(tostring(waste), keysOf(stockWastes)))
                end
            end
        end
    elseif type(plant.stockCaps) == "table" and next(plant.stockCaps) then
        warn("stockCaps is ignored: no reactor has rodControl = \"stock\".")
    end

    -- Fuel floor per stock pool: it stops while ME holds less of its fuel than this.
    local function floorExample(waste)
        local fuel = stockFuel[waste] or "fuel"
        local kind = (resources[fuel] or {}).kind
        return waste .. " = " .. (kind == "fluid" and "64000" or "200000") .. ",   -- "
            .. stockWastes[waste] .. " stop while ME holds less " .. fuel .. " than this"
            .. (kind == "fluid" and " (mB)" or " (ingots)")
    end
    if next(stockWastes) then
        if plant.stockFuelFloor == nil or plant.stockFuelFloor == false then
            local lines = { "stockFuelFloor is missing: the least of each \"stock\" pool's fuel to leave in ME "
                .. "(the pool stops below it, so it can't use up fuel you need elsewhere).",
                "Add to the top-level table:   stockFuelFloor = {" }
            for _, waste in ipairs(keysOf(stockWastes)) do lines[#lines + 1] = "  " .. floorExample(waste) end
            lines[#lines + 1] = "},"
            err(table.unpack(lines))
        elseif type(plant.stockFuelFloor) ~= "table" then
            err("stockFuelFloor must be a table like { cyanite = 200000 }, but it is " .. describe(plant.stockFuelFloor) .. ".")
        else
            for _, waste in ipairs(keysOf(stockWastes)) do
                local v = plant.stockFuelFloor[waste]
                if v == nil then
                    err("stockFuelFloor." .. waste .. " is missing: how much " .. (stockFuel[waste] or "fuel")
                        .. " must stay in ME before " .. stockWastes[waste] .. " stop (0 = no floor).",
                        "Add inside stockFuelFloor:   " .. floorExample(waste))
                elseif type(v) ~= "number" or v < 0 then
                    err("stockFuelFloor." .. waste .. " must be a number (0 or more), but it is " .. describe(v) .. ".")
                end
            end
            for _, waste in ipairs(keysOf(plant.stockFuelFloor)) do
                if not stockWastes[waste] then
                    warn("stockFuelFloor." .. tostring(waste) .. " is ignored: no reactor with rodControl = \"stock\" makes "
                        .. tostring(waste) .. "." .. didYouMean(tostring(waste), keysOf(stockWastes)))
                end
            end
        end
    elseif type(plant.stockFuelFloor) == "table" and next(plant.stockFuelFloor) then
        warn("stockFuelFloor is ignored: no reactor has rodControl = \"stock\".")
    end
    if plant.stockMaxBurn ~= nil and plant.stockMaxBurn ~= false then
        if type(plant.stockMaxBurn) ~= "table" then
            err("stockMaxBurn must be a table like { cyanite = 20 } (mB/t for the whole pool), but it is "
                .. describe(plant.stockMaxBurn) .. ".")
        else
            for _, waste in ipairs(keysOf(plant.stockMaxBurn)) do
                local v = plant.stockMaxBurn[waste]
                if not stockWastes[waste] then
                    warn("stockMaxBurn." .. tostring(waste) .. " is ignored: no reactor with rodControl = \"stock\" makes "
                        .. tostring(waste) .. ".")
                elseif v ~= false and (type(v) ~= "number" or v <= 0) then
                    err("stockMaxBurn." .. waste .. " must be a positive number of mB/t (or false for flat out), but it is "
                        .. describe(v) .. ".")
                end
            end
        end
    end

    -- AE2 autocraft: exactly which of the three allowed crafts are on. Must be stated explicitly.
    local craftNames = keysOf(Planner.ALLOWED_CRAFTS)
    local crafts = defaults.crafts or {}
    local function craftLine(res)
        local c = crafts[res] or {}
        local made = (resources[res] or {}).label or res
        if #(c.inputs or {}) == 0 then return made .. " (ingredients are up to your AE2 pattern)" end
        local from = {}
        for _, inp in ipairs(c.inputs) do from[#from + 1] = inp.qty .. " " .. ((resources[inp.res] or {}).label or inp.res) end
        return made .. " from " .. table.concat(from, " + ")
    end
    local craftOn = {}
    if plant.autocraft == nil or plant.autocraft == false then
        local lines = { "autocraft is missing: which of the " .. #craftNames
            .. " allowed AE2 crafts the plugin may request (true) or never request (false).",
            "Add to the top-level table:", "autocraft = {" }
        for _, res in ipairs(craftNames) do
            lines[#lines + 1] = "  " .. res .. " = true,   -- " .. craftLine(res) .. "; needs an AE2 pattern"
        end
        lines[#lines + 1] = "},"
        err(table.unpack(lines))
    elseif type(plant.autocraft) ~= "table" then
        err("autocraft must be a table like { cyanite_fluid = true, ... }, but it is " .. describe(plant.autocraft) .. ".")
    else
        for _, k in ipairs(keysOf(plant.autocraft)) do
            if not Planner.ALLOWED_CRAFTS[k] then
                err("autocraft." .. tostring(k) .. ": the plugin may only ask AE2 to craft "
                    .. table.concat(craftNames, ", ") .. "." .. didYouMean(tostring(k), craftNames),
                    "Remove that line; anything else has to be crafted by you or your own AE2 setup.")
            end
        end
        for _, res in ipairs(craftNames) do
            local v = plant.autocraft[res]
            if v == nil then
                err("autocraft." .. res .. " is missing: true lets the plugin ask AE2 for " .. craftLine(res)
                    .. " (needs an AE2 pattern); false = never.",
                    "Add inside autocraft:   " .. res .. " = true,")
            elseif type(v) ~= "boolean" then
                err("autocraft." .. res .. " must be true or false, but it is " .. describe(v) .. ".")
            elseif v then
                craftOn[res] = true
            end
        end
    end

    -- Sources: nothing may come from two places, and everything the recipes use should come
    -- from somewhere (a reactor, an enabled AE2 craft, or a batch recipe).
    local madeBy = {} -- res -> list of human-readable sources
    for _, p in ipairs(defaults.processes or {}) do
        madeBy[p.output] = madeBy[p.output] or {}
        table.insert(madeBy[p.output], "the " .. p.id .. " recipe")
    end
    for _, waste in ipairs(keysOf(producers)) do
        local names = {}
        for _, id in ipairs(producers[waste]) do names[#names + 1] = "reactors[" .. q(id) .. "]" end
        madeBy[waste] = madeBy[waste] or {}
        table.insert(madeBy[waste], table.concat(names, " + ") .. " (waste = " .. q(waste) .. ")")
    end
    for _, res in ipairs(craftNames) do
        if craftOn[res] then
            madeBy[res] = madeBy[res] or {}
            table.insert(madeBy[res], "autocraft." .. res)
        end
    end
    for _, res in ipairs(keysOf(madeBy)) do
        if #madeBy[res] > 1 then
            local fix = ""
            if craftOn[res] and producers[res] then
                local form = (res:gsub("_fluid$", ""))
                fix = "Pick one: let the reactor output " .. q(form) .. " ingots (Solid Access Port) and keep autocraft."
                    .. res .. " = true, or set autocraft." .. res .. " = false."
            end
            err(q(res) .. " would come from both " .. table.concat(madeBy[res], " and ") .. ".", fix)
        end
    end
    local usedBy = {} -- res -> consumers (recipes and enabled crafts)
    for _, p in ipairs(defaults.processes or {}) do
        for _, inp in ipairs(p.inputs or {}) do
            usedBy[inp.res] = usedBy[inp.res] or {}
            table.insert(usedBy[inp.res], "the " .. p.id .. " recipe")
        end
    end
    for _, res in ipairs(craftNames) do
        if craftOn[res] then
            for _, inp in ipairs((crafts[res] or {}).inputs or {}) do
                usedBy[inp.res] = usedBy[inp.res] or {}
                table.insert(usedBy[inp.res], "autocraft." .. res)
            end
        end
    end
    if type(plant.reactors) == "table" then
        local burners = {}
        for _, id in ipairs(keysOf(plant.reactors)) do
            local r = plant.reactors[id]
            if type(r) == "table" and type(r.fuel) == "string" then
                burners[r.fuel] = burners[r.fuel] or {}
                table.insert(burners[r.fuel], shortName(id))
            end
        end
        for fuel, ids in pairs(burners) do
            usedBy[fuel] = usedBy[fuel] or {}
            table.insert(usedBy[fuel], "reactor" .. (#ids > 1 and "s " or " ") .. table.concat(ids, "+") .. " (via your ME importer)")
        end
    end
    local wasteFuel = {}
    for fuel, wastes in pairs(defaults.reactions or {}) do
        for _, w in ipairs(wastes) do wasteFuel[w] = fuel end
    end
    for _, res in ipairs(keysOf(usedBy)) do
        local producible = wasteFuel[res] or Planner.ALLOWED_CRAFTS[res]
        if producible and not madeBy[res] then
            local ways = {}
            if wasteFuel[res] then
                local kind = (resources[res] or {}).kind
                ways[#ways + 1] = "give a " .. wasteFuel[res] .. " reactor a "
                    .. (kind == "fluid" and "Fuel Injection Port" or "Solid Access Port")
                    .. " in outlet mode and set its waste = " .. q(res)
            end
            if Planner.ALLOWED_CRAFTS[res] then
                ways[#ways + 1] = "set autocraft." .. res .. " = true (needs an AE2 pattern for " .. craftLine(res) .. ")"
            end
            warn("Nothing here produces " .. q(res) .. ", which " .. table.concat(usedBy[res], " and ")
                .. (#usedBy[res] > 1 and " use" or " uses") .. ". It can only come from ME stock.",
                "To make it: " .. table.concat(ways, ", or ") .. ".")
        end
    end

    -- Reference reactor for the deviation column (optional).
    if plant.referenceReactor ~= nil and plant.referenceReactor ~= false
        and type(plant.reactors) == "table" and next(plant.reactors) ~= nil then -- else already reported
        local ref = plant.reactors[plant.referenceReactor]
        if ref == nil then
            err("referenceReactor = " .. q(plant.referenceReactor) .. " is not one of the reactors defined in reactors ("
                .. quoted(keysOf(type(plant.reactors) == "table" and plant.reactors or {})) .. ")."
                .. didYouMean(tostring(plant.referenceReactor), keysOf(type(plant.reactors) == "table" and plant.reactors or {})))
        elseif type(ref) == "table" and (ref.rodControl == "stock" or ref.rodControl == "power") then
            local ratioIds = {}
            for _, id in ipairs(keysOf(plant.reactors)) do
                local r = plant.reactors[id]
                if type(r) == "table" and r.rodControl == "ratio" then ratioIds[#ratioIds + 1] = id end
            end
            warn("referenceReactor = " .. q(plant.referenceReactor) .. " has rodControl = " .. q(ref.rodControl)
                .. ", so it isn't part of the locked ratio; the dev column will use another reactor instead.",
                #ratioIds > 0 and ("Set it to one of the ratio reactors:   referenceReactor = " .. q(ratioIds[1]) .. ",")
                    or "No reactor uses rodControl = \"ratio\", so there is no ratio to compare.")
        end
    end

    return errors, warnings
end

--endregion

_G.InsanitePlanner = Planner
