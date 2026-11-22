-- Headless test for the Insanite factory plugin (src/plugins/insanite/).
-- Run from the project root:  lua test/insanite_sim.lua
--
-- Drives the real plugin code against a fake world: an ME Bridge over an in-memory ME store,
-- a reprocessor (1 item slot + 5000 mB tank, one 2-second operation at a time), a
-- solid-mixing fluidizer, and four reactors whose burn rate follows their control rods, each
-- with a stand-in core Reactor object whose updateRods the plugin replaces. A simulated player
-- crafts Insanite Blocks out of ME by hand; the plugin must never call AE2 crafting.

dofile("test/cc_stubs.lua")
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end
table.unpack = table.unpack or unpack

dofile("src/plugins/insanite/config.lua")
dofile("src/plugins/insanite/planner.lua")
dofile("src/plugins/insanite/factory.lua")
dofile("src/plugins/insanite/rods.lua")

local failures = 0
local function check(cond, msg)
    if cond then
        print("  ok   " .. msg)
    else
        failures = failures + 1
        print("  FAIL " .. msg)
    end
end

-- The plant config shipped in the repo (= what /insanite.conf holds in game). D = defaults merged
-- with it, i.e. the effective config.
local PLANT_TEXT = io.open("insanite.conf"):read("a")
local PLANT = assert(load("return " .. PLANT_TEXT, "=insanite.conf", "t", {}))()
local D = InsaniteFactory.deepMerge(InsaniteFactory.deepMerge(INSANITE_DEFAULTS, {}), PLANT)
local function writePlant(text)
    local f = fs.open(INSANITE_DEFAULTS.plantFile, "w"); f.write(text); f.close()
end
local function id(res) return D.resources[res].id end
local R5, R6, R7, R8 = "BigReactors-Reactor_5", "BigReactors-Reactor_6", "BigReactors-Reactor_7", "BigReactors-Reactor_8"
local SHARE = { [R6] = 184, [R8] = 32, [R5] = 16, [R7] = 24 } -- fuel per Insanite Block (x1000 mB)

--region 1. ratios

print("ratios per Insanite Block (kit = 8 insanite + 8 inanite + 1 netherite block)")
do
    local model, errors = InsanitePlanner.buildModel(D)
    check(#errors == 0, "default config builds (" .. table.concat(errors, "; ") .. ")")
    local need, ops = InsanitePlanner.computeNeeds(model)
    local expected = {
        insanite = 8, inanite = 8, netherite_block = 1,
        benitoite = 128, rossinite = 24000, verderium = 24000, ridiculite = 16, ludicrite = 32,
        magentite_fluid = 16000, cyanite_fluid = 32000, blutonium = 92, cyanite = 184,
        water = 92000, yellorium = 240,
    }
    for res, value in pairs(expected) do
        check(math.abs((need[res] or -1) - value) < 1e-9, string.format("need %-16s = %s", res, value))
    end
    local expectedOps = { blutonium = 92, ludicrite = 32, ridiculite = 16, inanite = 8, insanite = 8, verderium = 12,
        [R6] = 184, [R8] = 32, [R5] = 16, [R7] = 24 }
    for pid, value in pairs(expectedOps) do
        check(math.abs((ops[pid] or -1) - value) < 1e-9, string.format("ops %-22s = %s", pid, value))
    end
    for _, p in ipairs(model.processes) do
        check(p.machine ~= "ae2", "no AE2 crafting process: " .. p.id)
    end
end

--endregion

--region 2. hook

print("hook")
do
    local saved = parallel
    local seen = {}
    parallel = { waitForAll = function(...) seen.fns = { ... } end }
    dofile("src/plugins/insanite/hook.lua")
    check(getmetatable(_G) ~= nil, "watcher installed before controller.lua defines main")
    local coreMain = function() seen.core = true end
    _G.main = coreMain
    check(_G.main ~= coreMain, "main() wrapped")
    check(getmetatable(_G) == nil, "watcher removed after wrapping")
    _G.main()
    check(seen.fns and #seen.fns == 2 and seen.fns[2] == InsaniteFactory.runForever, "core + factory run in parallel")
    seen.fns[1]()
    check(seen.core == true, "wrapped main still runs the core")
    rawset(_G, "main", nil)
    parallel = saved
end

--endregion

--region fake world

local function newWorld(opts)
    opts = opts or {}
    peripheral._registry = {}
    fs.delete(D.stateFile)

    local W = { me = { item = {}, fluid = {} }, stats = { mixed = 0, stuck = 0, aeCalls = 0, crafted = 0 } }
    local me = W.me
    local function add(kind, gid, n) me[kind][gid] = (me[kind][gid] or 0) + n end

    -- A slot holds one item/fluid type.
    local function slot(limit, accepts) return { id = nil, n = 0, limit = limit, accepts = accepts } end
    local function insert(s, gid, n)
        if not s.accepts[gid] then return 0 end
        if s.n > 0 and s.id ~= gid then return 0 end
        local k = math.min(s.limit - s.n, n)
        if k <= 0 then return 0 end
        s.id, s.n = gid, s.n + k
        return k
    end
    local function take(s, n)
        local k = math.min(s.n, n)
        s.n = s.n - k
        if s.n == 0 then s.id = nil end
        return k
    end
    local function inventoryPort(name, s, ptype)
        peripheral.register(name, ptype or "inventory", {
            list = function() return s.n > 0 and { [1] = { name = s.id, count = s.n } } or {} end,
            _insertItem = function(gid, n) return insert(s, gid, n) end,
        })
    end
    local function fluidPort(name, s, ptype)
        peripheral.register(name, ptype or "fluid_storage", {
            tanks = function() return s.n > 0 and { { name = s.id, amount = s.n } } or {} end,
            _insertFluid = function(gid, n) return insert(s, gid, n) end,
        })
    end

    -- Reprocessor
    local solids, fluids, recipes = {}, {}, {}
    for _, p in ipairs(D.processes) do
        if p.machine == "reprocessor" then
            local solid, fluid
            for _, inp in ipairs(p.inputs) do
                if inp.port == "solid" then solid = inp else fluid = inp end
            end
            solids[id(solid.res)] = true
            fluids[id(fluid.res)] = true
            recipes[#recipes + 1] = { solid = id(solid.res), sq = solid.qty, fluid = id(fluid.res), fq = fluid.qty, out = id(p.output) }
        end
    end
    local rs, rf = slot(64, solids), slot(5000, fluids)
    W.reprocessor = { solid = rs, fluid = rf }
    inventoryPort(D.machines.reprocessor.ports.solid, rs, "bigreactors:reprocessorwasteinjector")
    fluidPort(D.machines.reprocessor.ports.fluid, rf, "bigreactors:reprocessorfluidinjector")
    local reprocessorTimer, reprocessorIdle = 0, 0

    -- Fluidizer (solid mixing): 2 yellorium + 1 blutonium -> 2000 mB verderium
    local fuelOk = { [id("yellorium")] = true, [id("blutonium")] = true }
    local fa, fb = slot(64, fuelOk), slot(64, fuelOk)
    inventoryPort(D.machines.fluidizer.ports.a, fa, "bigreactors:fluidizersolidinjector")
    inventoryPort(D.machines.fluidizer.ports.b, fb, "bigreactors:fluidizersolidinjector")

    -- Reactors: burn (mB/t) = maxBurn x (1 - rod/100) while fuel lasts. Each has a stand-in core
    -- Reactor object in _G.reactors whose class updateRods ("energy law") sets rods to powerWant.
    local maxBurn = { [R6] = 60, [R8] = 15, [R5] = 10, [R7] = 10 }
    for rid, v in pairs(opts.maxBurn or {}) do maxBurn[rid] = v end
    W.reactors = {}
    _G.reactors = {}
    _G.overallStats = { rfLost = opts.rfLost or 0, rfLostPerReactor = 0 }
    local FakeCore = {
        updateRods = function(self)
            self.seenShare = _G.overallStats.rfLostPerReactor
            self.setRodLevels(self.powerWant or 100)
        end,
    }
    local inlets = {}
    for rid, r in pairs(D.reactors) do
        local R = { fuel = 0, waste = 0, cap = 20000, rod = 100, maxBurn = maxBurn[rid], burnedTotal = 0,
            fuelId = id(r.fuel), fuelKind = D.resources[r.fuel].kind,
            wasteId = id(r.waste), wasteKind = D.resources[r.waste].kind }
        W.reactors[rid] = R
        R.core = setmetatable({
            id = rid, active = true, activelyCooled = false, rodLevel = 100,
            averageFuelUsage = 0, averageLastRFT = 0, powerWant = 100,
            setRodLevels = function(level) R.rod = level end,
        }, { __index = FakeCore })
        _G.reactors[rid] = R.core
        peripheral.register(rid, "BigReactors-Reactor", {
            getFuelStats = function() return { fuelAmount = R.fuel, fuelCapacity = R.cap, wasteAmount = R.waste } end,
        })
        local inlet = "test:inlet_" .. rid
        inlets[rid] = { inlet = inlet }
        peripheral.register(inlet, "inventory", {
            _insertItem = function(gid, n)
                if R.fuelKind ~= "item" or gid ~= R.fuelId then return 0 end
                local k = math.min(n, math.floor((R.cap - R.fuel - R.waste) / 1000))
                if k <= 0 then return 0 end
                R.fuel = R.fuel + k * 1000
                return k
            end,
            _insertFluid = function(gid, n)
                if R.fuelKind ~= "fluid" or gid ~= R.fuelId then return 0 end
                local k = math.min(n, R.cap - R.fuel - R.waste)
                if k <= 0 then return 0 end
                R.fuel = R.fuel + k
                return k
            end,
        })
    end

    -- ME Bridge (AE2 crafting methods exist but must never be used)
    local function target(name) return peripheral._registry[name] and peripheral._registry[name].methods end
    local function aeCall() W.stats.aeCalls = W.stats.aeCalls + 1; return nil, "NOT_ALLOWED" end
    peripheral.register(D.bridge, "me_bridge", {
        getItem = function(f) return { name = f.name, amount = me.item[f.name] or 0 } end,
        getFluid = function(f) return { name = f.name, amount = me.fluid[f.name] or 0 } end,
        exportItem = function(t, f)
            local p = target(t)
            if not p or not p._insertItem then return nil, "TARGET_NOT_FOUND" end
            local n = p._insertItem(f.name, math.min(f.count or 64, me.item[f.name] or 0))
            add("item", f.name, -n)
            return n
        end,
        exportFluid = function(t, f)
            local p = target(t)
            if not p or not p._insertFluid then return nil, "TARGET_NOT_FOUND" end
            local n = p._insertFluid(f.name, math.min(f.amount or 1000, me.fluid[f.name] or 0))
            add("fluid", f.name, -n)
            return n
        end,
        importItem = function() return 0 end,
        importFluid = function() return 0 end,
        isCraftable = aeCall, isCrafting = aeCall, craftItem = aeCall, getCraftingTasks = aeCall,
    })

    -- The player crafting one Insanite Block by hand (8 insanite + 8 inanite + 1 netherite).
    function W.craftBlock()
        local i, a, n = id("insanite"), id("inanite"), id("netherite_block")
        if (me.item[i] or 0) >= 8 and (me.item[a] or 0) >= 8 and (me.item[n] or 0) >= 1 then
            add("item", i, -8); add("item", a, -8); add("item", n, -1)
            W.stats.crafted = W.stats.crafted + 1
            return true
        end
        return false
    end

    -- One second of game time.
    function W.step()
        local recipe
        if rs.n > 0 and rf.n > 0 then
            for _, r in ipairs(recipes) do
                if r.solid == rs.id and r.fluid == rf.id then recipe = r end
            end
            if not recipe then W.stats.mixed = W.stats.mixed + 1 end
        end
        if recipe and rs.n >= recipe.sq and rf.n >= recipe.fq then
            reprocessorTimer = reprocessorTimer + 1
            reprocessorIdle = 0
            if reprocessorTimer >= 2 then
                reprocessorTimer = 0
                take(rs, recipe.sq); take(rf, recipe.fq)
                add("item", recipe.out, 1)
            end
        elseif rs.n > 0 or rf.n > 0 then
            reprocessorIdle = reprocessorIdle + 1
            if reprocessorIdle > (D.stallSeconds + 2 * D.cycleSeconds + 5) then W.stats.stuck = W.stats.stuck + 1 end
        end

        local y = (fa.id == id("yellorium") and fa) or (fb.id == id("yellorium") and fb)
        local b = (fa.id == id("blutonium") and fa) or (fb.id == id("blutonium") and fb)
        if y and b and y.n >= 2 and b.n >= 1 then
            take(y, 2); take(b, 1)
            add("fluid", id("verderium"), 2000)
        end

        for _, R in pairs(W.reactors) do
            local burn = math.min(20 * R.maxBurn * (1 - R.rod / 100), R.fuel)
            R.fuel = R.fuel - burn
            R.waste = R.waste + burn
            R.burnedTotal = R.burnedTotal + burn
            if R.wasteKind == "fluid" then
                add("fluid", R.wasteId, R.waste); R.waste = 0
            else
                while R.waste >= 1000 do add("item", R.wasteId, 1); R.waste = R.waste - 1000 end
            end
            -- the core's tick loop: refresh averages, then run the steering pass
            R.core.averageFuelUsage = burn / 20 / 1000 -- B/t
            R.core.averageLastRFT = burn / 20 * 100
            R.core.rodLevel = R.rod
            R.core.averageRodLevel = R.rod
            R.core:updateRods()
        end
    end

    W.reactorOverrides = inlets
    return W
end

local function stockUp(W)
    W.me.item[id("yellorium")] = 100000
    W.me.fluid[id("water")] = 1e12
    W.me.item[id("benitoite")] = 10000
    W.me.item[id("netherite_block")] = 500
end

-- Runs the world; craftEvery = seconds between the player's crafting attempts (nil = never).
local function runWorld(W, seconds, overrides, opts)
    opts = opts or {}
    if not opts.continue then
        overrides = overrides or {}
        overrides.reactors = overrides.reactors or {}
        for rid, inl in pairs(W.reactorOverrides) do
            overrides.reactors[rid] = overrides.reactors[rid] or {}
            overrides.reactors[rid].inlet = inl.inlet
        end
        writePlant(PLANT_TEXT)
        InsaniteFactory.init(overrides)
        W.t = 0
    end
    local cfg = InsaniteFactory.config()
    W.peaks = W.peaks or {}
    for _ = 1, seconds do
        W.t = W.t + 1
        _G.__simClock = (_G.__simClock or 0) + 1
        W.step()
        if opts.craftEvery and W.t % opts.craftEvery == 0 then W.craftBlock() end
        if W.t % cfg.cycleSeconds == 0 then
            InsaniteFactory.cycle()
            for res, def in pairs(cfg.resources) do
                local v = W.me[def.kind][def.id] or 0
                if v > (W.peaks[res] or 0) then W.peaks[res] = v end
            end
            if opts.onCycle then opts.onCycle(W.t) end
        end
    end
end

local function amount(W, res) return W.me[D.resources[res].kind][id(res)] or 0 end

local function burnRatioOk(W, tolerance)
    local b = {}
    for rid, R in pairs(W.reactors) do b[rid] = R.burnedTotal / 1000 end
    local ok = true
    for _, rid in ipairs({ R6, R8, R7 }) do
        local want = SHARE[rid] / SHARE[R5]
        if b[R5] <= 0 or math.abs((b[rid] / b[R5]) / want - 1) > tolerance then ok = false end
    end
    return ok, string.format("%.0f:%.0f:%.0f:%.0f", b[R6], b[R8], b[R5], b[R7])
end

--endregion

--region 3. locked rate targets

print("locked reactor rates")
do
    local model = InsanitePlanner.buildModel(D)
    local need, ops = InsanitePlanner.computeNeeds(model)
    local maxPace = InsanitePlanner.plantRate(D, model, ops)
    check(math.abs(maxPace * 72000 - 0.9 * 72000 / 40 / 156) < 1e-6,
        string.format("max pace from the reprocessor: %.2f blocks/h", maxPace * 72000))

    -- Wastes at target (trim 1), finished kit empty (demand 1).
    local stock = {}
    for res, n in pairs(need) do stock[res] = D.stockBlocks * n end
    stock.insanite, stock.inanite = 0, 0
    local t, d = InsanitePlanner.rateTargets(D, model, need, ops, stock, maxPace, {})
    check(math.abs(t[R6] / t[R5] - 184 / 16) < 1e-9 and math.abs(t[R8] / t[R5] - 2) < 1e-9 and math.abs(t[R7] / t[R5] - 1.5) < 1e-9,
        string.format("burn ratio R6:R8:R5:R7 = 184:32:16:24 (%.2f:%.2f:%.2f:%.2f mB/t)", t[R6], t[R8], t[R5], t[R7]))
    check(d.demand == 1 and d.limit == "max pace", "empty kit -> full pace")

    stock.insanite, stock.inanite = D.stockBlocks * 8, D.stockBlocks * 8
    t, d = InsanitePlanner.rateTargets(D, model, need, ops, stock, maxPace, {})
    check(d.rate == 0 and t[R6] == 0 and t[R5] == 0 and d.limit == "kit full", "full kit -> every reactor stops")

    stock.insanite, stock.inanite = (D.stockBlocks - 0.5) * 8, D.stockBlocks * 8
    t, d = InsanitePlanner.rateTargets(D, model, need, ops, stock, maxPace, {})
    check(math.abs(d.rate / maxPace - 0.5) < 1e-9, "half a block short -> half pace (demandGain 1)")

    -- The slowest reactor sets the pace for all four.
    stock.insanite, stock.inanite = 0, 0
    local full = InsanitePlanner.rateTargets(D, model, need, ops, stock, maxPace, {})
    t, d = InsanitePlanner.rateTargets(D, model, need, ops, stock, maxPace, { [R5] = full[R5] / 2 })
    check(math.abs(t[R5] - full[R5] / 2) < 1e-9 and math.abs(t[R6] - full[R6] / 2) < 1e-9 and math.abs(t[R7] - full[R7] / 2) < 1e-9,
        "reactor 5 at half its share -> yellorium & verderium reactors halve too")
    check(d.limit == R5 .. " max burn", "status names the limiting reactor")
    t = InsanitePlanner.rateTargets(D, model, need, ops, stock, maxPace, { [R6] = full[R6] / 4 })
    check(math.abs(t[R5] - full[R5] / 4) < 1e-9, "and vice versa: reactor 6 at a quarter -> reactor 5 at a quarter")

    -- Trim: a surplus/shortage of one waste nudges only that reactor, within +-maxTrim.
    stock.cyanite = (D.stockBlocks + 1) * need.cyanite
    stock.magentite_fluid = 0
    t, d = InsanitePlanner.rateTargets(D, model, need, ops, stock, maxPace, {})
    check(math.abs(d.reactors[R6].trim - 0.75) < 1e-9 and math.abs(d.reactors[R5].trim - 1.25) < 1e-9,
        "cyanite surplus trims reactor 6 down, magentite shortage trims reactor 5 up (clamped to 25%)")
    local strict = InsanitePlanner.rateTargets(setmetatable({ maxTrim = 0 }, { __index = D }),
        model, need, ops, stock, maxPace, {})
    check(math.abs(strict[R6] / strict[R5] - 184 / 16) < 1e-9, "maxTrim = 0 -> strictly locked ratio despite the imbalance")

    -- Overflow: a waste far above target means something downstream is blocked.
    stock.cyanite = D.stockBlocks * need.cyanite
    stock.magentite_fluid = D.stockBlocks * need.magentite_fluid
    stock.rossinite = (D.stockBlocks + D.overflowBlocks) * need.rossinite
    t, d = InsanitePlanner.rateTargets(D, model, need, ops, stock, maxPace, {})
    check(d.rate == 0 and d.limit == "overflow rossinite", "rossinite piling up (no benitoite?) -> plant stops")
end

--endregion

--region 4. rod law

print("rod law")
do
    local rod = 100
    local core = setmetatable({
        id = "R", active = true, activelyCooled = false, rodLevel = 100, averageFuelUsage = 0,
        averageLastRFT = 0, powerWant = 100,
        setRodLevels = function(level) rod = level end,
    }, { __index = { updateRods = function(self) self.setRodLevels(self.powerWant) end } })
    _G.reactors = { R = core }
    _G.overallStats = { rfLost = 0, rfLostPerReactor = 0 }
    local maxBurn = 10

    local function run(seconds, target, feed)
        for s = 1, seconds do
            _G.__simClock = _G.__simClock + 1
            if feed ~= false and s % 5 == 0 then
                InsaniteRods.update({ R = target }, { R = { present = true, fuelAmount = 1e6 } })
            end
            core.averageFuelUsage = maxBurn * (1 - rod / 100) / 1000
            core.rodLevel = rod
            core:updateRods()
        end
        return maxBurn * (1 - rod / 100)
    end

    _G.__simClock = 0
    InsaniteRods.configure({ reactors = { R = { rodControl = "ratio" } } })
    InsaniteRods.update({ R = 2.3 }, { R = { present = true, fuelAmount = 1e6 } })
    InsaniteRods.install()
    check(rawget(core, "updateRods") == InsaniteRods._managedUpdateRods, "managed law installed on the core reactor object")
    local burn = run(180, 2.3)
    check(math.abs(burn - 2.3) / 2.3 < 0.05, string.format("burn settles on target (%.2f vs 2.30 mB/t, rods %.1f%%)", burn, rod))
    burn = run(120, 6.0)
    check(math.abs(burn - 6.0) / 6.0 < 0.05, string.format("follows a new target (%.2f vs 6.00 mB/t)", burn))
    run(10, 0)
    check(rod == 100, "target 0 -> rods fully inserted")

    -- Max-burn learning: the reactor can only do 2 mB/t but is asked for 4.
    maxBurn = 2
    run(90, 4) -- ~27 s to withdraw fully, then capacitySeconds (30) of confirmation
    local cap = InsaniteRods.capacities().R
    check(rod <= 1 and cap and math.abs(cap - 2) < 0.05, string.format("saturated reactor's max burn learned (%.2f mB/t)", cap or -1))
    run(30, 1.9) -- planner lowered the target just under capacity: reactor keeps up, rods ~5%
    check(InsaniteRods.capacities().R ~= nil and InsaniteRods.capacities().R > cap,
        string.format("capacity probes upward while it keeps up (%.2f -> %.2f)", cap or -1, InsaniteRods.capacities().R or -1))
    maxBurn = 10
    run(120, 1.5)
    check(InsaniteRods.capacities().R == nil, "capacity forgotten once rods are well inserted again")

    core.powerWant = 35
    run(D.rodStaleSeconds + 5, 2.3, false)
    check(math.abs(rod - 35) < 0.01 and InsaniteRods.modeOf("R") == "power", "stale targets -> back to the core energy law")

    InsaniteRods.update({ R = 2.3 }, { R = { present = true, fuelAmount = 1e6 } })
    core.averageFuelUsage = {} -- force an error inside the ratio law
    core.powerWant = 55
    local ok = pcall(core.updateRods, core)
    check(ok and rod == 55, "error in the ratio law falls back to the core law (no SCRAM-triggering error)")
    check(InsaniteRods.state("R").lastError ~= nil, "error is reported in status")

    -- Energy share for reactors left on "power": only the drain the ratio reactors don't cover.
    local function stub(rid, rft)
        return setmetatable({ id = rid, active = true, activelyCooled = false, rodLevel = 100,
            averageFuelUsage = 0, averageLastRFT = rft, setRodLevels = function() end },
            { __index = { updateRods = function(self) self.seenShare = _G.overallStats.rfLostPerReactor end } })
    end
    _G.reactors = { A = stub("A", 500), B = stub("B", 300), P = stub("P", 0), Q = stub("Q", 0) }
    _G.overallStats = { rfLost = 2000, rfLostPerReactor = 500 }
    InsaniteRods.configure({ reactors = { A = { rodControl = "ratio" }, B = { rodControl = "ratio" },
        P = { rodControl = "power" } } })
    InsaniteRods.update({ A = 1, B = 1 }, {})
    InsaniteRods.install()
    _G.reactors.P:updateRods()
    _G.reactors.Q:updateRods()
    check(_G.reactors.P.seenShare == 600 and _G.reactors.Q.seenShare == 600,
        "energy reactors share only the drain the ratio reactors don't cover ((2000-800)/2)")
    check(_G.overallStats.rfLostPerReactor == 500, "core's share value restored afterwards")
end

--endregion

--region 5. full plant

print("full plant: player crafts a block every 400 s for 6 h, then stops for 3 h")
do
    _G.__simClock = 0
    local W = newWorld()
    stockUp(W)
    local raised = {}
    runWorld(W, 6 * 3600, {}, { craftEvery = 400, onCycle = function()
        for _, a in ipairs(InsaniteFactory.alerts()) do raised[a.key] = a.text end
    end })
    local need = InsaniteFactory.needs()
    local crafted = W.stats.crafted
    check(next(raised) == nil, "healthy plant raised no alerts (" .. tostring(next(raised) and raised[next(raised)]) .. ")")

    check(W.stats.aeCalls == 0, "AE2 crafting never called")
    check(W.stats.mixed == 0 and W.stats.stuck == 0, "reprocessor never mixed recipes or got stuck")
    check(crafted >= 40, string.format("player crafted %d of 54 attempted blocks (max pace %.1f/h)", crafted,
        InsaniteFactory.plantRate() * 72000))
    local ok, ratio = burnRatioOk(W, 0.10)
    check(ok, "fuel burned R6:R8:R5:R7 = " .. ratio .. " (recipe 184:32:16:24, within 10%)")
    for _, res in ipairs({ "blutonium", "ludicrite", "ridiculite", "inanite", "insanite", "verderium" }) do
        local limit = D.stockBlocks * need[res] + ((D.resources[res].kind == "fluid") and 32000 or 32)
        check((W.peaks[res] or 0) <= limit, string.format("%-15s peak %-7s <= %s", res, tostring(W.peaks[res]), tostring(limit)))
    end
    for _, res in ipairs({ "cyanite", "cyanite_fluid", "magentite_fluid", "rossinite" }) do
        local limit = (D.stockBlocks + D.overflowBlocks) * need[res]
        check((W.peaks[res] or 0) <= limit, string.format("%-15s peak %-7s <= %s", res, tostring(W.peaks[res]), tostring(limit)))
    end

    -- Player stops crafting: the kit fills to target and the reactors stop.
    runWorld(W, 3 * 3600, nil, { continue = true })
    local d = InsaniteFactory.rateDetail()
    local kit = InsanitePlanner.kitCoverage(InsanitePlanner.buildModel(D), {
        insanite = amount(W, "insanite"), inanite = amount(W, "inanite") })
    check(kit >= D.stockBlocks - 0.15, string.format("kit refilled to %.2f of %d blocks", kit, D.stockBlocks))
    check(d.rate == 0 and d.limit == "kit full", "plant rate 0 once the kit is full")
    local allIn = true
    for _, R in pairs(W.reactors) do if R.rod < 99.9 then allIn = false end end
    check(allIn, "all four reactors' rods fully inserted")
    print("  info " .. InsaniteFactory.statusLines()[2].text)
end

print("weak blutonium reactor (1 mB/t max, needs 2.3): the yellorium reactors slow to match")
do
    _G.__simClock = 0
    local W = newWorld({ maxBurn = { [R5] = 1.0 } })
    stockUp(W)
    local limitedTicks, cycles = 0, 0
    runWorld(W, 4 * 3600, {}, { craftEvery = 200, onCycle = function(t)
        if t > 3600 then
            cycles = cycles + 1
            local d = InsaniteFactory.rateDetail()
            if d and d.limit == R5 .. " max burn" then limitedTicks = limitedTicks + 1 end
        end
    end })
    check(limitedTicks / cycles > 0.8, string.format("reactor 5 is the named limit %.0f%% of the time", 100 * limitedTicks / cycles))
    local ok, ratio = burnRatioOk(W, 0.10)
    check(ok, "fuel burned still in recipe ratio: " .. ratio)
    check(W.reactors[R6].rod > 10, string.format("reactor 6 throttled to match (rods %.0f%% in, not flat out)", W.reactors[R6].rod))
    check(W.stats.mixed == 0 and W.stats.stuck == 0 and W.stats.aeCalls == 0, "no mixing, no stuck batches, no AE2 calls")
end

--endregion

--region 6. stall repair + recipe inference after reboot

print("leftovers after a reboot are inferred and topped up to whole operations")
do
    _G.__simClock = 0
    local W = newWorld()
    W.me.item[id("cyanite")] = 100
    W.me.fluid[id("water")] = 1e9
    W.reprocessor.solid.id, W.reprocessor.solid.n = id("cyanite"), 3
    W.reprocessor.fluid.id, W.reprocessor.fluid.n = id("water"), 1000
    local repaired = false
    runWorld(W, 200, { stallSeconds = 30 }, { onCycle = function()
        for _, e in ipairs(InsaniteFactory.events()) do
            if e:find("stalled on blutonium") then repaired = true end
        end
    end })
    check(W.stats.mixed == 0, "no mixing while repairing")
    check(W.reprocessor.solid.n % 2 == 0 and W.reprocessor.fluid.n == W.reprocessor.solid.n / 2 * 1000,
        string.format("contents are whole operations (%d cyanite, %d mB water)", W.reprocessor.solid.n, W.reprocessor.fluid.n))
    check(repaired, "stall detected on the inferred recipe (blutonium) and repaired")
end

--endregion

--region 7. kit full from the start

print("kit already full: nothing is fueled or burned")
do
    _G.__simClock = 0
    local W = newWorld()
    stockUp(W)
    local model = InsanitePlanner.buildModel(D)
    local need = InsanitePlanner.computeNeeds(model)
    for res, n in pairs(need) do
        local def = D.resources[res]
        if res ~= "water" and res ~= "yellorium" and res ~= "benitoite" and res ~= "netherite_block" then
            W.me[def.kind][def.id] = D.stockBlocks * n
        end
    end
    runWorld(W, 120)
    local fed = false
    for _, R in pairs(W.reactors) do if R.fuel > 0 or R.burnedTotal > 0 then fed = true end end
    check(not fed, "no reactor fueled or burning while the kit is at target")
    check(InsaniteFactory.lastNotes()[R5] == "idle (rate 0)", "status says why (rate 0)")
end

--endregion

--region 8. ratio deviation + alerts

print("ratio deviation vs the reference reactor")
do
    local model = InsanitePlanner.buildModel(D)
    local need, ops = InsanitePlanner.computeNeeds(model)
    local maxPace = InsanitePlanner.plantRate(D, model, ops)
    local stock = {}
    for res, n in pairs(need) do stock[res] = D.stockBlocks * n end
    stock.insanite, stock.inanite = 0, 0
    local t, d = InsanitePlanner.rateTargets(D, model, need, ops, stock, maxPace, {})
    local measured = { [R6] = t[R6], [R8] = t[R8], [R5] = t[R5] / 2, [R7] = t[R7] * 1.1 }
    local dev = InsanitePlanner.deviations(D, d, measured)
    check(dev.ref == R6 and dev.reactors[R6].isRef, "reference is reactor 6")
    check(math.abs(dev.reactors[R8].dev) < 1e-9, "R8 on target -> 0% deviation")
    check(math.abs(dev.reactors[R5].dev + 0.5) < 1e-9 and math.abs(dev.reactors[R5].tracking + 0.5) < 1e-9,
        "R5 burning half its share -> -50% vs R6 and -50% vs its own target")
    check(math.abs(dev.reactors[R7].dev - 0.1) < 1e-9, "R7 10% fast -> +10%")
    measured[R6] = 0
    dev = InsanitePlanner.deviations(D, d, measured)
    check(dev.ref == R5, "reference falls back to a burning reactor when R6 is idle")
    local wrapped = InsaniteFactory.wrapText("PLANT SLOWED to 40%: Rossinite piling up in ME", 16, "  ")
    local fits, joined = true, {}
    for _, l in ipairs(wrapped) do
        if #l > 16 then fits = false end
        joined[#joined + 1] = (l:gsub("^%s+", ""))
    end
    check(#wrapped > 1 and fits and table.concat(joined, " ") == "PLANT SLOWED to 40%: Rossinite piling up in ME",
        "banner text word-wraps to the monitor width without losing words")
end

-- Fake core alarm list, to see what reaches the SCADA screen.
local scada = {}
_G.AlarmManager = {
    raise = function(code, severity, message) scada[code] = message end,
    clear = function(code) scada[code] = nil end,
}
local function alertKeys()
    local keys = {}
    for _, a in ipairs(InsaniteFactory.alerts()) do keys[a.key] = a.text end
    return keys
end

print("no benitoite: plant slows, alert names the real cause, clears once fixed")
do
    _G.__simClock = 0
    scada = {}
    local W = newWorld()
    stockUp(W)
    W.me.item[id("benitoite")] = 0
    runWorld(W, 4 * 3600)
    local d = InsaniteFactory.rateDetail()
    local overflowKey, overflowText
    for key, text in pairs(alertKeys()) do
        if key == "overflow" then overflowKey, overflowText = key, text end
    end
    check(d.limitKind == "overflow" and d.rate < d.unconstrained, string.format("plant slowed (%s, %.1f of %.1f blk/h)",
        d.limit, d.rate * 72000, d.unconstrained * 72000))
    check(overflowKey ~= nil and overflowText:find("benitoite") ~= nil,
        "alert: " .. tostring(overflowText))
    check(scada["insanite:" .. tostring(overflowKey)] ~= nil, "same alert raised in the core alarm list (SCADA)")
    local lines = InsaniteFactory.statusLines()
    check(lines[1].bg == colors.red and lines[2].text:find("ALERT") ~= nil, "red alert banner at the top of the screen")

    W.me.item[id("benitoite")] = 10000
    runWorld(W, 3 * 3600, nil, { continue = true })
    check(next(alertKeys()) == nil, "all alerts cleared after benitoite arrives")
    check(next(scada) == nil, "and cleared from the core alarm list")
    check(W.stats.mixed == 0 and W.stats.stuck == 0, "no mixing or stuck batches throughout")
end

print("weak reactor: max-burn alert")
do
    _G.__simClock = 0
    scada = {}
    local W = newWorld({ maxBurn = { [R5] = 1.0 } })
    stockUp(W)
    runWorld(W, 3600, {}, { craftEvery = 200 })
    local text = alertKeys()["capacity:" .. R5]
    check(text ~= nil and text:find("R5 at its max burn") ~= nil, "alert: " .. tostring(text))
    local dev = InsaniteFactory.deviation()
    local worst = 0
    for rid, e in pairs(dev.reactors) do
        if e.dev and not e.isRef then worst = math.max(worst, math.abs(e.dev - e.expected)) end
    end
    check(worst < 0.10, string.format("all reactors still within %.0f%% of the locked ratio (beyond trim)", worst * 100))
end

print("starved reactor: fluidizer port missing -> no verderium -> reactor 7 out of fuel")
do
    _G.__simClock = 0
    scada = {}
    local W = newWorld()
    stockUp(W)
    peripheral._registry[D.machines.fluidizer.ports.a] = nil
    runWorld(W, 1800)
    local keys = alertKeys()
    check(keys["machine:fluidizer"] ~= nil, "alert: " .. tostring(keys["machine:fluidizer"]))
    check(keys["track:" .. R7] ~= nil and keys["track:" .. R7]:find("out of fuel") ~= nil,
        "alert: " .. tostring(keys["track:" .. R7]))
    check(InsaniteFactory.rateDetail().limit ~= R7 .. " max burn", "an empty reactor is not mistaken for a max-burn limit")
end

_G.AlarmManager = nil

--endregion

--region 9. plant config check

print("plant config check (network = the in-game `peripherals` list)")
do
    -- Exactly what `peripherals` showed on the controller computer.
    local NET = {
        bottom = { "me_bridge", "storage_bridge", "multi_drive" },
        top = { "modem", "peripheral_hub" },
        me_bridge_2 = { "me_bridge", "storage_bridge", "multi_drive" },
        ["bigreactors:reprocessorwasteinjector_0"] = { "bigreactors:reprocessorwasteinjector", "inventory" },
        ["bigreactors:reprocessorfluidinjector_0"] = { "bigreactors:reprocessorfluidinjector", "fluid_storage" },
        ["bigreactors:fluidizersolidinjector_0"] = { "bigreactors:fluidizersolidinjector", "inventory" },
        ["bigreactors:fluidizersolidinjector_1"] = { "bigreactors:fluidizersolidinjector", "inventory" },
        monitor_2 = { "monitor" },
        left = { "monitor" },
        [R5] = { "BigReactors-Reactor" }, [R6] = { "BigReactors-Reactor" },
        [R7] = { "BigReactors-Reactor" }, [R8] = { "BigReactors-Reactor" },
    }
    local function copy(t)
        if type(t) ~= "table" then return t end
        local o = {}
        for k, v in pairs(t) do o[k] = copy(v) end
        return o
    end
    local function check_(mutate)
        local plant = copy(PLANT)
        mutate(plant)
        return InsanitePlanner.validatePlant(plant, INSANITE_DEFAULTS, NET)
    end
    local function has(list, ...)
        for _, msg in ipairs(list) do
            local all = true
            for _, needle in ipairs({ ... }) do
                if not msg:find(needle, 1, true) then all = false end
            end
            if all then return true end
        end
        return false
    end
    local function show(list) return (list[1] or "(none)"):gsub("\n%s*", " | ") end

    local e, w = InsanitePlanner.validatePlant(PLANT, INSANITE_DEFAULTS, NET)
    check(#e == 0 and #w == 0, "repo insanite.conf matches the in-game network: no problems (" .. show(e) .. show(w) .. ")")

    e = check_(function(p) p.bridge = nil end)
    check(has(e, "bridge is missing", 'bridge = "me_bridge_2",'), "missing bridge, suggests the real name: " .. show(e))

    e = check_(function(p) p.bridge = "bottom" end)
    check(has(e, "is a side of the computer", 'bridge = "me_bridge_2",'), "bridge = bottom explained: " .. show(e))

    e = check_(function(p) p.machines.reprocessor.ports.fluid = nil end)
    check(has(e, "machines.reprocessor.ports.fluid is missing", "Reprocessor Fluid Injector",
        'fluid = "bigreactors:reprocessorfluidinjector_0",'), "missing port names the injector and the line to add: " .. show(e))

    e = check_(function(p)
        local m = p.machines.reprocessor.ports
        m.solid, m.fluid = m.fluid, m.solid
    end)
    check(has(e, "did you swap solid and fluid?"), "swapped injectors caught: " .. show(e))

    e = check_(function(p) p.reactors[R5].inlet = nil; p.reactors[R5].inlett = false end)
    check(has(e, ".inlett is not a reactor setting", "Did you mean inlet?"), "typo'd key: " .. show(e))
    check(has(e, '.inlet is missing', "inlet = false,"), "missing inlet offers both choices")

    e = check_(function(p) p.reactors[R5].waste = "cyanite" end)
    check(has(e, "doesn't match fuel", '"magentite_fluid" (fluid, from a Fuel Injection Port in outlet mode)'),
        "waste/fuel mismatch explained: " .. show(e))

    e, w = check_(function(p) p.reactors[R8].waste = "cyanite" end)
    check(has(e, "all have waste = \"cyanite\""), "two reactors making the same waste: " .. show(e))
    check(has(w, 'No reactor has waste = "cyanite_fluid"', "ludicrite", "Fuel Injection Port"),
        "and the now-missing cyanite fluid is flagged: " .. show(w))

    e = check_(function(p) p.reactors[R6].inlet = "bigreactors:fluidizersolidinjector_0" end)
    check(has(e, "is used for both machines.fluidizer.ports.a and reactors"), "one peripheral used twice: " .. show(e))

    e = check_(function(p) p.reactors[R6].inlet = "bigreactors:reprocessorwasteinjector_0"; p.machines.reprocessor.ports.solid = "x" end)
    check(has(e, "is a bigreactors:reprocessorwasteinjector, but it must be a Reactor Solid Access Port"),
        "wrong kind of device: " .. show(e))

    e, w = check_(function(p) p.stockBlock = 3 end)
    check(#e == 0 and has(w, "stockBlock is not a known setting", "Did you mean stockBlocks?"), "typo'd setting: " .. show(w))

    e = check_(function(p) p.stockBlocks = "2" end)
    check(has(e, "stockBlocks must be a number", 'the text "2"'), "wrong type: " .. show(e))

    e, w = check_(function(p) p.monitor = "monitor_9" end)
    check(#e == 0 and has(w, 'monitor = "monitor_9" is not on the wired network', "Monitors on the network now: monitor_2, left"),
        "device not on the network lists the real ones: " .. show(w))

    e = check_(function(p) p.monitor = nil end)
    check(has(e, "monitor is missing", "monitor = false,"), "monitor must be stated (or false): " .. show(e))

    e = check_(function(p) p.machines = nil end)
    check(#e == 1 and has(e, "machines is missing", "reprocessor = { ports = { fluid = \"bigreactors:reprocessorfluidinjector_0\"",
        "fluidizer = { ports = { a = \"bigreactors:fluidizersolidinjector_0\", b = \"bigreactors:fluidizersolidinjector_1\""),
        "whole machines section missing -> one ready-to-paste block from the network: " .. show(e))

    e = check_(function(p) p.reactors = nil end)
    check(#e == 1 and has(e, "reactors is missing", '["BigReactors-Reactor_5"]', '["BigReactors-Reactor_8"]'),
        "reactors section missing -> template with the 4 reactors on the network")

    e, w = check_(function(p) p.reactors["BigReactors-Reactor_9"] = p.reactors[R8]; p.reactors[R8] = nil end)
    check(has(w, 'no reactor called "BigReactors-Reactor_9" is on the wired network', "BigReactors-Reactor_8"),
        "unknown reactor name suggests the unused one on the network: " .. show(w))

    e = check_(function(p) p.referenceReactor = "BigReactors-Reactor_66" end)
    check(has(e, "referenceReactor", "is not one of the reactors"), "bad referenceReactor: " .. show(e))

    e = check_(function(p) p.reactors[R7].fuel = nil end)
    check(has(e, ".fuel is missing", '"blutonium", "verderium", "yellorium"'), "missing fuel lists the choices: " .. show(e))

    e = check_(function(p) p.reactors[R7].rodControl = "rate" end)
    check(has(e, 'must be "ratio" or "power"', "Did you mean ratio?"), "bad rodControl: " .. show(e))

    -- File-level problems, through the real loader.
    fs.delete(INSANITE_DEFAULTS.plantFile)
    local plant, errs = InsaniteFactory.checkPlant()
    check(plant == nil and has(errs, "/insanite.conf not found", "install-insanite.lua"), "missing file: " .. show(errs))

    writePlant(PLANT_TEXT:gsub('bridge = "me_bridge_2",', 'bridge = "me_bridge_2"', 1))
    plant, errs = InsaniteFactory.checkPlant()
    check(plant == nil and has(errs, "syntax error", "/insanite.conf:", "missing comma"), "syntax error with line number: " .. show(errs))

    -- The plugin refuses to start and writes the full list where the player can read it.
    writePlant(PLANT_TEXT:gsub('monitor = "monitor_2",', '', 1))
    local ok, problem = pcall(InsaniteFactory.init)
    check(not ok and type(problem) == "table" and has(problem.plantErrors, "monitor is missing"), "init refuses to start on a bad config")
    local saved = print
    print = function() end
    InsaniteFactory.reportPlantProblems(problem, true)
    print = saved
    local f = fs.open("/insanite/config-problems.txt", "r")
    local report = f and f.readAll() or ""
    check(report:find("NOT running: 1 problem", 1, true) and report:find("PROBLEM 1: monitor is missing", 1, true),
        "problem list written to /insanite/config-problems.txt")
    writePlant(PLANT_TEXT)
end

--endregion

print(failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
