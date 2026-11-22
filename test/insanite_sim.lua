-- Headless test for the Insanite factory plugin (src/plugins/insanite/).
-- Run from the project root:  lua test/insanite_sim.lua
--
-- Drives the real plugin code against a fake world: an ME Bridge over an in-memory ME store,
-- a reprocessor (1 item slot + 5000 mB tank, one 2-second operation at a time), a
-- solid-mixing fluidizer, four reactors that burn fuel into waste, and AE2 crafting.

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

local D = INSANITE_DEFAULTS
local function id(res) return D.resources[res].id end

--region 1. ratios

print("ratios per Insanite Block")
do
    local model, errors = InsanitePlanner.buildModel(D)
    check(#errors == 0, "default config builds (" .. table.concat(errors, "; ") .. ")")
    local need, ops = InsanitePlanner.computeNeeds(model)
    local expected = {
        insanite_block = 1, insanite = 8, inanite_block = 1, inanite = 8, netherite_block = 1,
        benitoite = 128, rossinite = 24000, verderium = 24000, ridiculite = 16, ludicrite = 32,
        magentite_fluid = 16000, cyanite_fluid = 32000, blutonium = 92, cyanite = 184,
        water = 92000, yellorium = 240,
    }
    for res, value in pairs(expected) do
        check(math.abs((need[res] or -1) - value) < 1e-9, string.format("need %-16s = %s (got %s)", res, value, tostring(need[res])))
    end
    local expectedOps = {
        blutonium = 92, ludicrite = 32, ridiculite = 16, inanite = 8, insanite = 8, verderium = 12,
        ["BigReactors-Reactor_6"] = 184, ["BigReactors-Reactor_8"] = 32,
        ["BigReactors-Reactor_5"] = 16, ["BigReactors-Reactor_7"] = 24,
    }
    for pid, value in pairs(expectedOps) do
        check(math.abs((ops[pid] or -1) - value) < 1e-9, string.format("ops %-22s = %s", pid, value))
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

    local W = { me = { item = {}, fluid = {} }, stats = { mixed = 0, stuck = 0, crafted = 0 } }
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
    local function inventoryPort(name, s)
        peripheral.register(name, "inventory", {
            list = function() return s.n > 0 and { [1] = { name = s.id, count = s.n } } or {} end,
            _insertItem = function(gid, n) return insert(s, gid, n) end,
        })
    end
    local function fluidPort(name, s)
        peripheral.register(name, "fluid_storage", {
            tanks = function() return s.n > 0 and { { name = s.id, amount = s.n } } or {} end,
            _insertFluid = function(gid, n) return insert(s, gid, n) end,
        })
    end

    -- Reprocessor
    local reprocessorSolids, reprocessorFluids, recipes = {}, {}, {}
    for _, p in ipairs(D.processes) do
        if p.machine == "reprocessor" then
            local solid, fluid
            for _, inp in ipairs(p.inputs) do
                if inp.port == "solid" then solid = inp else fluid = inp end
            end
            reprocessorSolids[id(solid.res)] = true
            reprocessorFluids[id(fluid.res)] = true
            recipes[#recipes + 1] = { solid = id(solid.res), sq = solid.qty, fluid = id(fluid.res), fq = fluid.qty, out = id(p.output) }
        end
    end
    local rs, rf = slot(64, reprocessorSolids), slot(5000, reprocessorFluids)
    W.reprocessor = { solid = rs, fluid = rf }
    inventoryPort(D.machines.reprocessor.ports.solid, rs)
    fluidPort(D.machines.reprocessor.ports.fluid, rf)
    local reprocessorTimer, reprocessorIdle = 0, 0

    -- Fluidizer (solid mixing): 2 yellorium + 1 blutonium -> 2000 mB verderium
    local fuelOk = { [id("yellorium")] = true, [id("blutonium")] = true }
    local fa, fb = slot(64, fuelOk), slot(64, fuelOk)
    W.fluidizer = { a = fa, b = fb }
    inventoryPort(D.machines.fluidizer.ports.a, fa)
    inventoryPort(D.machines.fluidizer.ports.b, fb)

    -- Reactors. Burn (mB/t) = maxBurn x (1 - rod/100) while fuel lasts. With opts.withCore, a
    -- fake core Reactor object per reactor sits in _G.reactors; its class updateRods is a
    -- stand-in "energy law" that sets rods to powerWant and records the share it was given.
    local maxBurn = opts.maxBurn or { ["BigReactors-Reactor_6"] = 60, ["BigReactors-Reactor_8"] = 15,
        ["BigReactors-Reactor_5"] = 10, ["BigReactors-Reactor_7"] = 10 }
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
        local R = { fuel = 0, waste = 0, cap = 20000, rod = 0, maxBurn = maxBurn[rid] or 0, burnedTotal = 0,
            fuelId = id(r.fuel), fuelKind = D.resources[r.fuel].kind,
            wasteId = id(r.waste), wasteKind = D.resources[r.waste].kind }
        W.reactors[rid] = R
        if opts.withCore then
            R.core = setmetatable({
                id = rid, active = true, activelyCooled = false, rodLevel = 0,
                averageFuelUsage = 0, averageLastRFT = 0,
                powerWant = (opts.powerWant or {})[rid] or 100,
                setRodLevels = function(level) R.rod = level end,
            }, { __index = FakeCore })
            _G.reactors[rid] = R.core
        end
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

    -- ME Bridge
    local function target(name) return peripheral._registry[name] and peripheral._registry[name].methods end
    local crafts = {
        [id("insanite_block")] = { { id("insanite"), 8 }, { id("inanite_block"), 1 } },
        [id("inanite_block")] = { { id("inanite"), 8 }, { id("netherite_block"), 1 } },
    }
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
        isCraftable = function(f) return opts.noPatterns ~= true and crafts[f.name] ~= nil end,
        isCrafting = function() return false end,
        craftItem = function(f)
            local recipe = crafts[f.name]
            if not recipe or opts.noPatterns then return nil, "NOT_CRAFTABLE" end
            local n = f.count or 1
            for _, ing in ipairs(recipe) do n = math.min(n, math.floor((me.item[ing[1]] or 0) / ing[2])) end
            if n <= 0 then return nil, "MISSING_ITEMS" end
            for _, ing in ipairs(recipe) do add("item", ing[1], -n * ing[2]) end
            add("item", f.name, n)
            W.stats.crafted = W.stats.crafted + n
            return true
        end,
    })

    -- One second of game time.
    function W.step()
        -- reprocessor: one operation per 2 s, outputs straight into ME (output port piped to ME)
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

        -- fluidizer: one operation per second
        local y = (fa.id == id("yellorium") and fa) or (fb.id == id("yellorium") and fb)
        local b = (fa.id == id("blutonium") and fa) or (fb.id == id("blutonium") and fb)
        if y and b and y.n >= 2 and b.n >= 1 then
            take(y, 2); take(b, 1)
            add("fluid", id("verderium"), 2000)
        end

        -- reactors: burn fuel into waste (rods set the rate); outlets piped straight into ME
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
            if R.core then
                R.core.averageFuelUsage = burn / 20 / 1000 -- B/t
                R.core.averageLastRFT = burn / 20 * 100
                R.core.rodLevel = R.rod
                R.core:updateRods()
            end
        end
    end

    W.reactorOverrides = inlets
    return W
end

local function runWorld(W, seconds, overrides, onCycle)
    overrides = overrides or {}
    overrides.reactors = W.reactorOverrides
    InsaniteFactory.init(overrides)
    local cfg = InsaniteFactory.config()
    local peaks = {}
    for t = 1, seconds do
        _G.__simClock = t
        W.step()
        if t % cfg.cycleSeconds == 0 then
            InsaniteFactory.cycle()
            for res, def in pairs(cfg.resources) do
                local v = W.me[def.kind][def.id] or 0
                if v > (peaks[res] or 0) then peaks[res] = v end
            end
            if onCycle then onCycle(t) end
        end
    end
    return peaks
end

local function amount(W, res) return W.me[D.resources[res].kind][id(res)] or 0 end

--endregion

--region 3. full plant

print("full plant, 6 simulated hours, from raw materials only")
do
    local W = newWorld()
    W.me.item[id("yellorium")] = 100000
    W.me.fluid[id("water")] = 1e12
    W.me.item[id("benitoite")] = 10000
    W.me.item[id("netherite_block")] = 500

    local seconds = 6 * 3600
    local peaks = runWorld(W, seconds)
    local need = InsaniteFactory.needs()
    local blocks = amount(W, "insanite_block")

    check(W.stats.mixed == 0, "reprocessor never holds inputs from two recipes")
    check(W.stats.stuck == 0, "reprocessor never stuck with leftovers")
    check(blocks >= 40, string.format("produced %d Insanite Blocks (reprocessor-bound ideal ~%d)", blocks, math.floor(seconds / (2 * 156))))

    -- Demand-driven products never pile up past target (+ one batch / one reactor tank of slack).
    local slack = { blutonium = 64, ludicrite = 32, ridiculite = 16, inanite = 16, insanite = 8,
        magentite_fluid = 20000, rossinite = 20000, verderium = 32000 }
    for res, extra in pairs(slack) do
        local limit = D.bufferBlocks * need[res] + extra
        check((peaks[res] or 0) <= limit, string.format("%-15s peak %-7s <= %s", res, tostring(peaks[res]), tostring(limit)))
    end
    print(string.format("  info Insanite Blocks: %d, yellorium left %d, benitoite left %d, netherite left %d",
        blocks, amount(W, "yellorium"), amount(W, "benitoite"), amount(W, "netherite_block")))
end

--endregion

--region 4. no AE2 patterns

print("no AE2 patterns: finals stop at the buffer target")
do
    local W = newWorld({ noPatterns = true })
    W.me.item[id("yellorium")] = 20000
    W.me.fluid[id("water")] = 1e12
    W.me.item[id("benitoite")] = 10000
    W.me.item[id("netherite_block")] = 500
    local peaks = runWorld(W, 2 * 3600)
    local need = InsaniteFactory.needs()
    check(W.stats.crafted == 0, "no crafting attempted without patterns")
    check(amount(W, "insanite") >= D.bufferBlocks * need.insanite, "insanite ingots reach target")
    check((peaks.insanite or 0) <= D.bufferBlocks * need.insanite + 8, "insanite ingots stop near target")
    check((peaks.inanite or 0) <= D.bufferBlocks * need.inanite + 16, "inanite ingots stop near target")
    check(InsaniteFactory.lastNotes().insanite_block == "no AE2 pattern", "status explains why blocks aren't crafted")
end

--endregion

--region 5. stall repair + recipe inference after reboot

print("leftovers after a reboot are inferred and topped up to whole operations")
do
    local W = newWorld()
    W.me.item[id("cyanite")] = 100
    W.me.fluid[id("water")] = 1e9
    -- 3 cyanite + 1000 mB water = 1.5 operations: one runs, one cyanite is stranded.
    W.reprocessor.solid.id, W.reprocessor.solid.n = id("cyanite"), 3
    W.reprocessor.fluid.id, W.reprocessor.fluid.n = id("water"), 1000
    local repaired = false
    runWorld(W, 200, { stallSeconds = 30 }, function()
        for _, e in ipairs(InsaniteFactory.events()) do
            if e:find("stalled on blutonium") then repaired = true end
        end
    end)
    local st = InsaniteFactory.machineState().reprocessor
    check(W.stats.mixed == 0, "no mixing while repairing")
    check(W.reprocessor.solid.n % 2 == 0 and W.reprocessor.fluid.n == W.reprocessor.solid.n / 2 * 1000,
        string.format("contents are whole operations (%d cyanite, %d mB water)", W.reprocessor.solid.n, W.reprocessor.fluid.n))
    check(st ~= nil, "reprocessor tracked")
    check(repaired, "stall detected on the inferred recipe (blutonium) and repaired")
end

--endregion

--region 6. demand reactors idle when their product is at target

print("production reactors are only fueled while their waste is needed")
do
    local W = newWorld()
    W.me.item[id("blutonium")] = 5000
    W.me.fluid[id("magentite_fluid")] = 1e9 -- already far above target
    W.me.fluid[id("verderium")] = 1e9
    W.me.fluid[id("rossinite")] = 1e9
    W.me.item[id("yellorium")] = 5000
    runWorld(W, 60)
    check(W.reactors["BigReactors-Reactor_5"].fuel == 0, "blutonium reactor not fueled (magentite at target)")
    check(W.reactors["BigReactors-Reactor_7"].fuel == 0, "verderium reactor not fueled (rossinite at target)")
    check(W.reactors["BigReactors-Reactor_6"].fuel > 0, "power reactor 6 fueled anyway (mode always)")
end

--endregion

--region 7. rod control by waste production speed

print("rod targets follow the recipe ratio")
do
    local model = InsanitePlanner.buildModel(D)
    local need, ops = InsanitePlanner.computeNeeds(model)
    local rate = InsanitePlanner.plantRate(D, model, ops)
    check(math.abs(rate * 72000 - 0.9 * 72000 / 40 / 156) < 1e-6,
        string.format("plant pace from the reprocessor: %.2f blocks/h", rate * 72000))

    local atTarget, empty, flooded = {}, {}, {}
    for res, n in pairs(need) do
        atTarget[res] = D.bufferBlocks * n
        empty[res] = 0
        flooded[res] = (D.bufferBlocks + 1 / D.rateGain) * n
    end
    local t = InsanitePlanner.rateTargets(D, model, need, ops, atTarget, rate)
    local r6, r8, r5, r7 = t["BigReactors-Reactor_6"], t["BigReactors-Reactor_8"], t["BigReactors-Reactor_5"], t["BigReactors-Reactor_7"]
    check(math.abs(r6 / r5 - 184 / 16) < 1e-9 and math.abs(r8 / r5 - 32 / 16) < 1e-9 and math.abs(r7 / r5 - 24 / 16) < 1e-9,
        string.format("burn ratio R6:R8:R5:R7 = 184:32:16:24 (%.2f:%.2f:%.2f:%.2f mB/t)", r6, r8, r5, r7))
    local e = InsanitePlanner.rateTargets(D, model, need, ops, empty, rate)
    check(math.abs(e["BigReactors-Reactor_5"] / r5 - 2) < 1e-9, "waste empty -> 2x nominal")
    local f = InsanitePlanner.rateTargets(D, model, need, ops, flooded, rate)
    check(f["BigReactors-Reactor_5"] == 0, "waste at target + 2 blocks -> stop")
end

print("rod law")
do
    -- One fake reactor: max 10 mB/t at rods 0. The core law (stand-in) wants rods at powerWant.
    local rod = 100
    local core = setmetatable({
        id = "R", active = true, activelyCooled = false, rodLevel = 100, averageFuelUsage = 0,
        averageLastRFT = 0, powerWant = 100,
        setRodLevels = function(level) rod = level end,
    }, { __index = { updateRods = function(self) self.setRodLevels(self.powerWant) end } })
    _G.reactors = { R = core }
    _G.overallStats = { rfLost = 0, rfLostPerReactor = 0 }

    local function run(seconds, target, mode, feed)
        for _ = 1, seconds do
            _G.__simClock = _G.__simClock + 1
            if feed ~= false then
                InsaniteRods.update({ R = target }, { R = { present = true, fuelAmount = 1e6 } })
            end
            core.averageFuelUsage = 10 * (1 - rod / 100) / 1000
            core.rodLevel = rod
            core:updateRods()
        end
        return 10 * (1 - rod / 100)
    end

    _G.__simClock = 0
    InsaniteRods.configure({ reactors = { R = { rodControl = "waste" } } })
    InsaniteRods.install()
    check(rawget(core, "updateRods") == InsaniteRods._managedUpdateRods, "managed law installed on the core reactor object")
    local burn = run(180, 2.3)
    check(math.abs(burn - 2.3) / 2.3 < 0.05, string.format("waste: burn settles on target (%.2f vs 2.30 mB/t, rods %.1f%%)", burn, rod))
    burn = run(120, 6.0)
    check(math.abs(burn - 6.0) / 6.0 < 0.05, string.format("waste: follows a new target (%.2f vs 6.00 mB/t)", burn))
    run(5, 0)
    check(rod == 100, "waste: target 0 -> rods fully inserted")

    InsaniteRods.configure({ reactors = { R = { rodControl = "waste+power" } } })
    core.powerWant = 20
    run(60, 2.3)
    check(math.abs(rod - 20) < 0.01, string.format("waste+power: energy demand wins when it needs more burn (rods %.1f%%)", rod))
    core.powerWant = 100
    burn = run(240, 2.3)
    check(math.abs(burn - 2.3) / 2.3 < 0.05, string.format("waste+power: waste law governs when energy demand is low (%.2f mB/t)", burn))

    core.powerWant = 35
    run(D.rodStaleSeconds + 5, 2.3, "waste+power", false)
    check(math.abs(rod - 35) < 0.01 and InsaniteRods.modeOf("R") == "power", "stale targets -> back to the core energy law")

    InsaniteRods.configure({ reactors = { R = { rodControl = "waste" } } })
    InsaniteRods.update({ R = 2.3 }, { R = { present = true, fuelAmount = 1e6 } })
    core.averageFuelUsage = {} -- force an error inside the waste law
    core.powerWant = 55
    local ok = pcall(core.updateRods, core)
    check(ok and rod == 55, "error in the waste law falls back to the core law (no SCRAM-triggering error)")
    check(InsaniteRods.state("R").lastError ~= nil, "error is reported in status")

    -- Energy share: two waste-only reactors make 800 RF/t of the 2000 RF/t drain, so the two
    -- energy-following reactors split the remaining 1200.
    local function stub(rid, rft)
        return setmetatable({ id = rid, active = true, activelyCooled = false, rodLevel = 100,
            averageFuelUsage = 0, averageLastRFT = rft, powerWant = 100, setRodLevels = function() end },
            { __index = { updateRods = function(self) self.seenShare = _G.overallStats.rfLostPerReactor end } })
    end
    _G.reactors = { W5 = stub("W5", 500), W7 = stub("W7", 300), P6 = stub("P6", 0), P8 = stub("P8", 0) }
    _G.overallStats = { rfLost = 2000, rfLostPerReactor = 500 }
    InsaniteRods.configure({ reactors = { W5 = { rodControl = "waste" }, W7 = { rodControl = "waste" },
        P6 = { rodControl = "power" }, P8 = { rodControl = "waste+power" } } })
    InsaniteRods.update({ W5 = 1, W7 = 1, P8 = 0 }, {})
    InsaniteRods.install()
    _G.reactors.P6:updateRods()
    _G.reactors.P8:updateRods()
    check(_G.reactors.P6.seenShare == 600 and _G.reactors.P8.seenShare == 600,
        string.format("energy reactors share only the uncovered drain (%s, %s of 2000-800)/2",
            tostring(_G.reactors.P6.seenShare), tostring(_G.reactors.P8.seenShare)))
    check(_G.overallStats.rfLostPerReactor == 500, "core's share value restored afterwards")
end

print("full plant with rods driven by waste demand (no energy demand), 6 simulated hours")
do
    local W = newWorld({ withCore = true })
    W.me.item[id("yellorium")] = 100000
    W.me.fluid[id("water")] = 1e12
    W.me.item[id("benitoite")] = 10000
    W.me.item[id("netherite_block")] = 500
    _G.__simClock = 0
    local peaks = runWorld(W, 6 * 3600)
    local need, ops = InsaniteFactory.needs()
    local blocks = amount(W, "insanite_block")
    check(W.stats.mixed == 0 and W.stats.stuck == 0, "no recipe mixing or stuck leftovers")
    check(blocks >= 40, string.format("produced %d Insanite Blocks", blocks))
    for _, res in ipairs({ "blutonium", "ludicrite", "ridiculite", "magentite_fluid", "rossinite", "verderium" }) do
        local slack = (D.resources[res].kind == "fluid") and 32000 or 64 -- one batch / one reactor tank
        local limit = (D.bufferBlocks + 1 / D.rateGain) * need[res] + slack
        check((peaks[res] or 0) <= limit, string.format("%-15s peak %-7s <= %s", res, tostring(peaks[res]), tostring(limit)))
    end
    -- Fuel actually burned tracks the recipe ratio (pull system + rate targets).
    local burned = {}
    for rid, R in pairs(W.reactors) do burned[rid] = R.burnedTotal / 1000 end
    local function ratio(a, b) return burned[a] / burned[b] end
    local function near(x, want) return math.abs(x / want - 1) < 0.2 end
    local r75 = ratio("BigReactors-Reactor_7", "BigReactors-Reactor_5")
    local r65 = ratio("BigReactors-Reactor_6", "BigReactors-Reactor_5")
    local r85 = ratio("BigReactors-Reactor_8", "BigReactors-Reactor_5")
    check(near(r75, 24 / 16) and near(r65, 184 / 16) and near(r85, 32 / 16),
        string.format("fuel burned R6:R8:R5:R7 = %.0f:%.0f:%.0f:%.0f (recipe 184:32:16:24 per block, x%d blocks)",
            burned["BigReactors-Reactor_6"], burned["BigReactors-Reactor_8"], burned["BigReactors-Reactor_5"],
            burned["BigReactors-Reactor_7"], blocks))
    local rods = {}
    for rid, R in pairs(W.reactors) do rods[#rods + 1] = rid:gsub("BigReactors%-Reactor_", "R") .. "=" .. string.format("%.0f%%", R.rod) end
    table.sort(rods)
    print("  info final rods " .. table.concat(rods, " "))
end

--endregion

print(failures == 0 and "ALL PASSED" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
