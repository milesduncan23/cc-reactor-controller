-- Insanite factory plugin: default settings.
--
-- Nothing here is read by the core controller. To change a value on the in-game computer,
-- put just the keys you want to change in /insanite.conf (a textutils-serialized table), e.g.
--
--   {
--     monitor = "monitor_2",
--     reactors = {
--       ["BigReactors-Reactor_5"] = { inlet = "bigreactors:reinforced_reactorsolidaccessport_0" },
--     },
--   }
--
-- Nested tables merge key-by-key; lists (like `processes`) replace wholesale; setting an entry
-- to `false` removes a default entry (e.g. `reactors = { ["BigReactors-Reactor_8"] = false }`).
--
-- Peripheral names below are the ones on this computer's wired network. Reactor access ports
-- were not on the network yet, so `inlet`/`outlet` are nil: fuel feeding for a reactor stays
-- off until its inlet port is attached and named here.

_G.INSANITE_DEFAULTS = {
    enabled = true,
    bridge = "me_bridge_2",

    -- Scheduling
    cycleSeconds = 5,        -- one planning pass every N seconds
    bufferBlocks = 2,        -- keep each intermediate topped up to this many Insanite Blocks' worth
    goalBlocks = 0,          -- stop crafting once ME holds this many Insanite Blocks (0 = never stop)
    maxBatchOps = 16,        -- most operations dosed into the reprocessor/fluidizer at once
    stallSeconds = 60,       -- machine contents unchanged this long = stalled (try to repair)
    autoCraft = true,        -- ask AE2 to craft Inanite/Insanite Blocks (needs patterns in AE2)
    maxCraftPerRequest = 4,

    -- Reactor fuel tanks: when fuel drops below fuelLowPct, top up toward fuelHighPct
    -- (fuel + waste, % of the reactor's fuel capacity).
    fuelLowPct = 40,
    fuelHighPct = 80,
    maxFuelItemsPerCycle = 64,
    maxFuelFluidPerCycle = 16000,  -- mB
    ejectWasteAbovePct = 0,        -- >0: call doEjectWaste() when waste exceeds this % (0 = off)

    -- Control rods by waste production speed (see rods.lua). Each reactor's nominal burn rate
    -- is (plant rate) x (its fuel per Insanite Block), so the reactors run in the recipe ratio.
    -- Plant rate = the slowest machine's pace (reprocessor) x plantUtilization, unless
    -- plantBlocksPerHour is set. The nominal rate is then scaled by how far the reactor's waste
    -- product is from target: x(1 + rateGain * (bufferBlocks - blocks held)), clamped to
    -- [0, rateMaxMult]. At target -> 1x; rateGain=0.5 stops a reactor at target + 2 blocks.
    plantBlocksPerHour = 0,   -- 0 = derive from the slowest machine
    plantUtilization = 0.9,
    rateGain = 0.5,
    rateMaxMult = 3,
    rodKi = 5,                -- rod-% per second at 100% burn-rate error
    rodDeadband = 0.02,       -- ignore burn-rate errors under 2%
    rodStaleSeconds = 60,     -- no fresh targets this long -> all reactors back to core energy law

    -- Status output. Set monitor to a peripheral name (e.g. "monitor_2") to dedicate that monitor
    -- to the plugin; the core controller stops drawing on it.
    monitor = nil,
    statusFile = "/insanite/status.txt",
    stateFile = "/insanite/state.conf",
    overrideFile = "/insanite.conf",

    -- What to make. The planner derives every ratio from `processes` + `reactors`, starting
    -- from one unit of `goal`.
    goal = "insanite_block",

    -- Every item/fluid the factory touches. kind = "item" (counted in items) or "fluid" (mB).
    resources = {
        yellorium       = { kind = "item",  id = "bigreactors:yellorium_ingot",   label = "Yellorium" },
        blutonium       = { kind = "item",  id = "bigreactors:blutonium_ingot",   label = "Blutonium" },
        cyanite         = { kind = "item",  id = "bigreactors:cyanite_ingot",     label = "Cyanite" },
        ludicrite       = { kind = "item",  id = "bigreactors:ludicrite_ingot",   label = "Ludicrite" },
        ridiculite      = { kind = "item",  id = "bigreactors:ridiculite_ingot",  label = "Ridiculite" },
        inanite         = { kind = "item",  id = "bigreactors:inanite_ingot",     label = "Inanite" },
        insanite        = { kind = "item",  id = "bigreactors:insanite_ingot",    label = "Insanite" },
        benitoite       = { kind = "item",  id = "bigreactors:benitoite_crystal", label = "Benitoite" },
        netherite_block = { kind = "item",  id = "minecraft:netherite_block",     label = "Netherite Blk" },
        inanite_block   = { kind = "item",  id = "bigreactors:inanite_block",     label = "Inanite Blk" },
        insanite_block  = { kind = "item",  id = "bigreactors:insanite_block",    label = "Insanite Blk" },
        water           = { kind = "fluid", id = "minecraft:water",               label = "Water" },
        cyanite_fluid   = { kind = "fluid", id = "bigreactors:cyanite",           label = "Cyanite (l)" },
        magentite_fluid = { kind = "fluid", id = "bigreactors:magentite",         label = "Magentite (l)" },
        verderium       = { kind = "fluid", id = "bigreactors:verderium",         label = "Verderium (l)" },
        rossinite       = { kind = "fluid", id = "bigreactors:rossinite",         label = "Rossinite (l)" },
    },

    -- Batch machines. `ports` maps an input slot name to the injector peripheral; `limits` is
    -- how much that injector can hold. `output` (optional) is an output-port peripheral the
    -- plugin should empty into ME; leave nil if pipes/AE2 buses already do that.
    machines = {
        reprocessor = {
            ports  = { solid = "bigreactors:reprocessorwasteinjector_0", fluid = "bigreactors:reprocessorfluidinjector_0" },
            limits = { solid = 64, fluid = 5000 },  -- reprocessor: 1 item slot, 5000 mB tank
            opsPerTick = 1 / 40,                     -- one operation per 40 ticks (mod constant)
            output = nil,
        },
        fluidizer = {  -- solid-mixing fluidizer (two solid injectors)
            ports  = { a = "bigreactors:fluidizersolidinjector_0", b = "bigreactors:fluidizersolidinjector_1" },
            limits = { a = 64, b = 64 },
            opsPerTick = nil,                        -- unknown; only 12 ops/block, never the bottleneck
            output = nil,
        },
    },

    -- Recipes, from the Extreme Reactors 2.4.28 / ATM10 data files. Order is the tie-break when
    -- two products are equally short (earlier = closer to the goal = preferred).
    -- machine = "ae2" means "ask AE2 to craft it" (requires a crafting pattern).
    processes = {
        { id = "insanite_block", machine = "ae2", output = "insanite_block", outQty = 1,
          inputs = { { res = "insanite", qty = 8 }, { res = "inanite_block", qty = 1 } } },
        { id = "inanite_block", machine = "ae2", output = "inanite_block", outQty = 1,
          inputs = { { res = "inanite", qty = 8 }, { res = "netherite_block", qty = 1 } } },
        { id = "insanite", machine = "reprocessor", output = "insanite", outQty = 1,
          inputs = { { res = "benitoite", qty = 16, port = "solid" }, { res = "rossinite", qty = 2000, port = "fluid" } } },
        { id = "inanite", machine = "reprocessor", output = "inanite", outQty = 1,
          inputs = { { res = "ridiculite", qty = 2, port = "solid" }, { res = "rossinite", qty = 1000, port = "fluid" } } },
        { id = "ridiculite", machine = "reprocessor", output = "ridiculite", outQty = 1,
          inputs = { { res = "ludicrite", qty = 2, port = "solid" }, { res = "magentite_fluid", qty = 1000, port = "fluid" } } },
        { id = "ludicrite", machine = "reprocessor", output = "ludicrite", outQty = 1,
          inputs = { { res = "blutonium", qty = 2, port = "solid" }, { res = "cyanite_fluid", qty = 1000, port = "fluid" } } },
        { id = "blutonium", machine = "reprocessor", output = "blutonium", outQty = 1,
          inputs = { { res = "cyanite", qty = 2, port = "solid" }, { res = "water", qty = 1000, port = "fluid" } } },
        { id = "verderium", machine = "fluidizer", output = "verderium", outQty = 2000,
          inputs = { { res = "yellorium", qty = 2, port = "a" }, { res = "blutonium", qty = 1, port = "b" } } },
    },

    -- Reactors burn fuel into waste 1:1 (per 1000 mB of reactant):
    --   yellorium -> cyanite, blutonium -> magentite, verderium -> rossinite.
    -- `waste` names the form the reactor's OUTLET produces: a Solid Access Port in outlet mode
    -- gives ingots ("cyanite"); a Fuel Injection Port in outlet mode gives fluid ("cyanite_fluid").
    -- mode = "always": keep fueled regardless of demand (power reactors).
    -- mode = "demand": only fuel while its waste product is below target (production reactors).
    -- inlet  = peripheral name of the inlet-mode access/injection port (required to feed fuel).
    -- outlet = optional outlet port the plugin empties into ME (nil if pipes/buses already do).
    -- rodControl = how the control rods are steered (see rods.lua):
    --   "waste"       burn at the waste production speed the factory needs (energy ignored)
    --   "waste+power" the same, but never slower than the core's energy-demand law
    --   "power"       the core's energy-demand law (original behaviour)
    reactors = {
        ["BigReactors-Reactor_6"] = { fuel = "yellorium", waste = "cyanite",         mode = "always", rodControl = "waste+power", inlet = nil, outlet = nil },
        ["BigReactors-Reactor_8"] = { fuel = "yellorium", waste = "cyanite_fluid",   mode = "always", rodControl = "waste+power", inlet = nil, outlet = nil },
        ["BigReactors-Reactor_5"] = { fuel = "blutonium", waste = "magentite_fluid", mode = "demand", rodControl = "waste",       inlet = nil, outlet = nil },
        ["BigReactors-Reactor_7"] = { fuel = "verderium", waste = "rossinite",       mode = "demand", rodControl = "waste",       inlet = nil, outlet = nil },
    },
}
