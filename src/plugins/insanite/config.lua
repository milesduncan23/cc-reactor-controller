-- Insanite factory plugin: default settings.
--
-- What the plugin does: keep the ME system stocked with a balanced "kit" for crafting Insanite
-- Blocks (insanite + inanite ingots and everything upstream of them, in recipe ratio) by
--   * dosing the reprocessor and fluidizer, and
--   * setting one common reaction rate for the four reactors, so each burns exactly its share
--     of the fuel per block and none outruns the others.
-- It never asks AE2 to craft anything except liquid cyanite and liquid magentite
-- (see `crafts`), and only those enabled in /insanite.conf. Reactor fuel is NOT handled here:
-- your own ME importer refuels the reactors; the plugin only sets their burn rates.
--
-- This file holds GAME DATA and TUNING only: item/fluid ids, recipes, machine capacities,
-- thresholds. It deliberately names no devices. Every device (ME Bridge, monitor, machine
-- ports, reactors and their ports) must be defined explicitly in the plant config file,
-- /insanite.conf on the computer (template: insanite.conf at the repo root). The plugin refuses
-- to start until that file defines them all (see InsanitePlanner.validatePlant).
--
-- Any tuning value below can also be overridden in /insanite.conf. Nested tables merge
-- key-by-key; lists (like `processes`) replace wholesale.
-- Nothing here is read by the core controller.

_G.INSANITE_DEFAULTS = {
    enabled = true,

    -- The kit: what one Insanite Block takes, in the items you craft it from.
    -- Insanite Block = 8 insanite ingots + 1 Inanite Block; Inanite Block = 8 inanite ingots +
    -- 1 netherite block. Netherite isn't produced here; it's listed so the status screen shows
    -- whether you have enough of it.
    kit = { insanite = 8, inanite = 8, netherite_block = 1 },

    -- Inputs, by how they reach ME:
    --   * autocraftedInputs: prerequisites AE2 crafts itself inside the craft that needs them
    --     (netherite blocks, inside the Insanite Block job). Never waited on and not shown on the
    --     status screen; if AE2 can't make them, the refused craft raises an alert.
    --   * raw: everything nothing here makes (benitoite, uranium, water), plus rawResources (what
    --     the plant also makes but you supply: cyanite from MA crops). Not craftable: recipes and
    --     AE2 crafts wait until ME holds them, the status screen shows them as raw (red under one
    --     block's worth), and a slowdown names them as the cause when they run out.
    autocraftedInputs = { netherite_block = true },
    rawResources = { cyanite = true },

    -- The finished block. Once ME holds the full kit target (stockBlocks' worth of insanite and
    -- inanite) and autocraft.insanite_block is on, the plugin asks AE2 for as many Insanite Blocks
    -- as the insanite and inanite cover (netherite blocks are autocrafted, see above). AE2 needs patterns for the Insanite Block
    -- and the Inanite Block. The kit then empties and the plant refills it.
    blockCraft = "insanite_block",

    -- Reserve target: ME should hold this many Insanite Blocks' worth of every material in the
    -- chain, each in recipe ratio. The whole plant slows as the kit fills and stops when full.
    stockBlocks = 2,

    -- Scheduling
    cycleSeconds = 5,        -- one planning pass every N seconds
    maxBatchOps = 16,        -- most operations dosed into the reprocessor/fluidizer at once
    stallSeconds = 60,       -- machine contents unchanged this long = stalled (try to repair)

    -- Reaction rate (see planner.lua rateTargets / rods.lua):
    --   plant rate = max pace x demand, capped by overflow and by the slowest reactor
    --   demand     = clamp(demandGain x (stockBlocks - finished kit in ME), 0, 1)
    --   reactor i  = plant rate x its fuel per block x trim_i
    --   trim_i     = clamp(1 + trimGain x (stockBlocks - its waste in ME), 1 - maxTrim, 1 + maxTrim)
    plantBlocksPerHour = 0,   -- max pace; 0 = the reprocessor's pace x plantUtilization
    plantUtilization = 0.9,
    demandGain = 1,           -- full speed once the kit is 1 block or more short of target
    maxTrim = 0.25,           -- per-reactor ratio correction; 0 = strictly locked ratio
    trimGain = 0.25,
    overflowBlocks = 4,       -- a waste this far above target stops the plant (blocked downstream)
    -- "stock" reactors (rodControl = "stock" in /insanite.conf) burn outside the lock: flat out
    -- (or at stockMaxBurn) until ME holds stockCaps of their waste, then stop until ME has
    -- dropped stockTaperPct below the cap. They also stop while ME holds less of their fuel than
    -- stockFuelFloor (set per pool in /insanite.conf, e.g. 200000 uranium ingots).
    stockTaperPct = 10,
    stockFuelResumePct = 5,   -- after stopping at stockFuelFloor, resume once ME fuel is this % above it
    rodTau = 5,               -- seconds for the rods to settle on a new target
    rodKi = 5,                -- start-up step (rod-%/s) before the burn-per-% estimate exists
    rodDeadband = 0.02,       -- ignore burn-rate errors under 2%
    rodStaleSeconds = 60,     -- no fresh targets this long -> reactors back to core energy law
    capacitySeconds = 30,     -- rods fully out this long and still short = reactor at its max

    ejectWasteAbovePct = 0,   -- >0: call doEjectWaste() when a reactor's waste exceeds this % (0 = off)

    -- AE2 autocraft requests that keep ME stocked (the block itself is blockCraft, above). With
    -- the Insanite Block these are the ONLY things the plugin may ever ask AE2 to craft (also
    -- enforced in code). Each must be switched on in /insanite.conf (autocraft = { ... }) and
    -- needs a matching pattern in AE2. A request is made when ME holds less than stockBlocks'
    -- worth and AE2 isn't already crafting it. `inputs`/`outQty` describe one craft so the
    -- ratios include what it consumes; match them to your AE2 pattern.
    crafts = {
        cyanite_fluid   = { outQty = 1000, inputs = { { res = "cyanite", qty = 1 } } },    -- 1 cyanite ingot -> 1000 mB
        magentite_fluid = { outQty = 1000, inputs = { { res = "magentite", qty = 1 } } },  -- 1 magentite ingot -> 1000 mB
        -- A reprocessor of its own, driven by an AE2 processing pattern (2 cyanite -> 1 blutonium;
        -- its water is piped in separately, but counted here so the plan stays right). When on,
        -- it takes over the shared reprocessor's blutonium recipe.
        -- priority: it claims cyanite before the liquid-cyanite craft.
        blutonium       = { outQty = 1, priority = true,
                            inputs = { { res = "cyanite", qty = 2 }, { res = "water", qty = 1000 } } },
    },
    maxCraftItems = 64,       -- most ingots per AE2 request
    maxCraftFluid = 16000,    -- most mB per AE2 request

    -- Alerts (a window over the bottom-right of the status monitor, and in the core's alarm list
    -- when scadaAlarms):
    --   * plant slowed: by a waste piling up (overflow) or by a reactor at its max burn
    --   * a reactor off its own burn target by more than deviationAlertPct for
    --     deviationAlertSeconds (out of fuel, stuck rods, ...)
    --   * a batch machine stalled, holding unknown items, or with a missing port
    --   * a batch machine at capacity: actually working machineAlertPct of the last
    --     machineAlertSeconds (loaded operations x time per operation) with ready work waiting in
    --     machineBacklogPct of the cycles (it is limiting throughput; advisory in SCADA)
    -- The reactor table shows each reactor's % deviation from the plant config's referenceReactor.
    deviationAlertPct = 15,
    deviationAlertSeconds = 120,
    slowAlertPct = 25,        -- alert when the plant runs this much slower than the reserve asks
                              -- (a healthy plant dips at most ~20% from normal buffer swings)
    slowAlertSeconds = 600,   -- overflow slowdowns with no identified cause must last this long
    machineAlertPct = 75,     -- a machine is "at capacity" when it's working this % of the time
    machineBacklogPct = 50,   -- ... and ready work waited for it in this % of the cycles
    machineAlertSeconds = 300,-- ... over this window
    craftFailAlertCount = 3,  -- alert when AE2 refuses the same craft this many times in a row
    alertClearSeconds = 30,   -- an alert clears once its cause has been gone this long
    scadaAlarms = true,

    -- Files on the computer.
    plantFile = "/insanite.conf",          -- device definitions (+ optional tuning overrides)
    statusFile = "/insanite/status.txt",
    stateFile = "/insanite/state.conf",
    pauseFile = "/insanite/paused",        -- which stop buttons are on (exists while any is)

    -- Every item/fluid the factory touches. kind = "item" (counted in items) or "fluid" (mB).
    resources = {
        yellorium       = { kind = "item",  id = "bigreactors:yellorium_ingot",   label = "Yellorium" },
        uranium         = { kind = "item",  id = "alltheores:uranium_ingot",      label = "Uranium" },  -- ATM10's unified uranium
        blutonium       = { kind = "item",  id = "bigreactors:blutonium_ingot",   label = "Blutonium" },
        cyanite         = { kind = "item",  id = "bigreactors:cyanite_ingot",     label = "Cyanite" },
        ludicrite       = { kind = "item",  id = "bigreactors:ludicrite_ingot",   label = "Ludicrite" },
        ridiculite      = { kind = "item",  id = "bigreactors:ridiculite_ingot",  label = "Ridiculite" },
        inanite         = { kind = "item",  id = "bigreactors:inanite_ingot",     label = "Inanite" },
        insanite        = { kind = "item",  id = "bigreactors:insanite_ingot",    label = "Insanite" },
        insanite_block  = { kind = "item",  id = "bigreactors:insanite_block",    label = "Insanite Blk" },
        benitoite       = { kind = "item",  id = "bigreactors:benitoite_crystal", label = "Benitoite" },
        netherite_block = { kind = "item",  id = "minecraft:netherite_block",     label = "Netherite Blk" },
        water           = { kind = "fluid", id = "minecraft:water",               label = "Water" },
        cyanite_fluid   = { kind = "fluid", id = "bigreactors:cyanite",           label = "Cyanite (l)" },
        magentite       = { kind = "item",  id = "bigreactors:magentite_ingot",   label = "Magentite" },
        magentite_fluid = { kind = "fluid", id = "bigreactors:magentite",         label = "Magentite (l)" },
        verderium       = { kind = "fluid", id = "bigreactors:verderium",         label = "Verderium (l)" },
        rossinite       = { kind = "fluid", id = "bigreactors:rossinite",         label = "Rossinite (l)" },
    },

    -- Batch machine capacities (mod constants). Which peripherals each machine's ports are is
    -- defined in /insanite.conf (machines.<name>.ports / .output), never here.
    --   limits     = how much each input port can hold, per port name the recipes use
    --   opsPerTick = machine speed, used for the plant's max pace (nil = unknown)
    --   portTypes / outputType = which kind of peripheral each port must be (used to check the
    --                plant config and to suggest names from the network)
    machines = {
        reprocessor = {
            limits = { solid = 64, fluid = 5000 },  -- reprocessor: 1 item slot, 5000 mB tank
            opsPerTick = 1 / 40,                     -- one operation per 40 ticks
            portTypes = {
                solid = { types = { "bigreactors:reprocessorwasteinjector" }, what = "Reprocessor Waste Injector" },
                fluid = { types = { "bigreactors:reprocessorfluidinjector" }, what = "Reprocessor Fluid Injector" },
            },
            outputType = { types = { "bigreactors:reprocessoroutputport" }, what = "Reprocessor Output Port" },
        },
        fluidizer = {  -- solid-mixing fluidizer (two solid injectors)
            limits = { a = 64, b = 64 },
            opsPerTick = nil,                        -- unknown; only 12 ops/block, never the bottleneck
            portTypes = {
                a = { types = { "bigreactors:fluidizersolidinjector" }, what = "Fluidizer Solid Injector" },
                b = { types = { "bigreactors:fluidizersolidinjector" }, what = "Fluidizer Solid Injector" },
            },
            outputType = { types = { "bigreactors:fluidizeroutputport" }, what = "Fluidizer Output Port" },
        },
    },

    -- Other peripheral kinds the plant config refers to (for checking and suggestions).
    deviceTypes = {
        bridge          = { types = { "me_bridge" }, what = "ME Bridge" },
        monitor         = { types = { "monitor" }, what = "Monitor" },
        reactor         = { types = { "BigReactors-Reactor", "extremereactor-reactorComputerPort" }, what = "Reactor Computer Port" },
        solidAccessPort = { types = { "bigreactors:reinforced_reactorsolidaccessport", "bigreactors:basic_reactorsolidaccessport" },
                            what = "Reactor Solid Access Port" },
        fluidAccessPort = { types = { "bigreactors:reinforced_reactorfluidaccessport" }, what = "Reactor Fuel Injection Port" },
    },

    -- What each reactor fuel burns into, per outlet form (ingots via a Solid Access Port,
    -- fluid via a Fuel Injection Port).
    reactions = {
        yellorium = { "cyanite", "cyanite_fluid" },
        uranium   = { "cyanite", "cyanite_fluid" },  -- Extreme Reactors burns uranium ingots as yellorium
        blutonium = { "magentite", "magentite_fluid" },
        verderium = { "rossinite" },
    },

    -- Recipes, from the Extreme Reactors 2.4.28 / ATM10 data files. Order is the tie-break when
    -- two products are equally short (earlier = closer to the kit = preferred).
    processes = {
        { id = "insanite", machine = "reprocessor", output = "insanite", outQty = 1,
          inputs = { { res = "benitoite", qty = 16, port = "solid" }, { res = "rossinite", qty = 2000, port = "fluid" } } },
        { id = "inanite", machine = "reprocessor", output = "inanite", outQty = 1,
          inputs = { { res = "ridiculite", qty = 2, port = "solid" }, { res = "rossinite", qty = 1000, port = "fluid" } } },
        { id = "ridiculite", machine = "reprocessor", output = "ridiculite", outQty = 1,
          inputs = { { res = "ludicrite", qty = 2, port = "solid" }, { res = "magentite_fluid", qty = 1000, port = "fluid" } } },
        { id = "ludicrite", machine = "reprocessor", output = "ludicrite", outQty = 1,
          inputs = { { res = "blutonium", qty = 2, port = "solid" }, { res = "cyanite_fluid", qty = 1000, port = "fluid" } } },
        -- priority: when it's the reprocessor's pick (furthest behind) or already running, it holds
        -- its cyanite, so the liquid-cyanite craft can't take single ingots it is waiting to pair
        -- up. It doesn't jump the reprocessor's queue: that starved every other recipe once
        -- cyanite was plentiful (MA crops).
        { id = "blutonium", machine = "reprocessor", output = "blutonium", outQty = 1, priority = true,
          inputs = { { res = "cyanite", qty = 2, port = "solid" }, { res = "water", qty = 1000, port = "fluid" } } },
        { id = "verderium", machine = "fluidizer", output = "verderium", outQty = 2000,
          inputs = { { res = "uranium", qty = 2, port = "a" }, { res = "blutonium", qty = 1, port = "b" } } },
    },

    -- Reactors are defined only in /insanite.conf. For reference, reactors burn fuel into waste
    -- 1:1 (per 1000 mB): yellorium -> cyanite, blutonium -> magentite, verderium -> rossinite.
    -- Several reactors may produce the same waste (e.g. two uranium reactors -> cyanite):
    -- they share that waste's target, and the plant only slows when all of them are maxed.
}
