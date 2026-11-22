# Insanite factory plugin

Turns the reactor controller computer into the scheduler for an Extreme Reactors Insanite line.
The plugin lives entirely in `src/plugins/insanite/` (plus this doc, `install-insanite.lua` and
`test/insanite_sim.lua`). No core file is modified: `src/scripts/main.lua` already loads every
file under `src/`, and `hook.lua` wraps the core `main()` so the factory runs as a second
coroutine beside the reactor control loop.

## What it does

Through the ME Bridge (`me_bridge_2`) it:

- **Doses the reprocessor** (`reprocessorwasteinjector_0` + `reprocessorfluidinjector_0`) with
  one recipe at a time, in whole operations, so it always drains clean before the next recipe.
- **Doses the solid-mixing fluidizer** (`fluidizersolidinjector_0`/`_1`) with 2 yellorium +
  1 blutonium per operation → verderium.
- **Fuels each reactor** with its own fuel. Power reactors (`mode = "always"`) are kept fueled.
  Production reactors (`mode = "demand"`) are fueled only while their waste product is short.
- **Asks AE2 to craft** Inanite Blocks and Insanite Blocks when the ingredients are there.
- **Steers control rods by waste production speed** instead of energy demand (`rods.lua`, see
  below), so each reactor burns at the rate the recipe ratio needs.

## The ratios

All numbers are derived at boot from the recipe table in `config.lua`, starting from
**one Insanite Block**. With the default plant:

| Step | Machine | Per Insanite Block |
| --- | --- | --- |
| Insanite Block = 8 insanite ingot + 1 inanite block | AE2 craft | 1 craft |
| Inanite Block = 8 inanite ingot + 1 netherite block | AE2 craft | 1 craft, **1 netherite block** |
| 16 benitoite + 2 B rossinite → insanite ingot | Reprocessor | 8 ops |
| 2 ridiculite + 1 B rossinite → inanite ingot | Reprocessor | 8 ops |
| 2 ludicrite + 1 B magentite → ridiculite | Reprocessor | 16 ops |
| 2 blutonium + 1 B cyanite fluid → ludicrite | Reprocessor | 32 ops |
| 2 cyanite + 1 B water → blutonium | Reprocessor | 92 ops |
| 2 yellorium + 1 blutonium → 2 B verderium | Fluidizer (mixing) | 12 ops |
| verderium → rossinite (fluid) | Reactor 7 | 24 B burned |
| blutonium → magentite (fluid) | Reactor 5 | 16 ingots burned |
| yellorium → cyanite (fluid) | Reactor 8 | 32 ingots burned |
| yellorium → cyanite (ingots) | Reactor 6 | 184 ingots burned |

Raw inputs per block: **240 yellorium, 128 benitoite, 92 B water, 1 netherite block**.
Reprocessor time per block: 156 ops × 2 s ≈ 5.2 min. The reprocessor is the bottleneck.

## How the scheduling keeps the ratios

Each product has a **coverage** = (ME stock + amount already inside machines) / per-block
need, i.e. "how many Insanite Blocks' worth we hold". A product is wanted while its coverage
is below `bufferBlocks` (default 2). Every `cycleSeconds` all wanted work is sorted by
coverage, lowest first, and handed machines and inputs greedily. So:

- The single reprocessor always runs the recipe whose product is furthest behind.
- Scarce shared inputs (blutonium feeds the reprocessor, reactor 5 and the fluidizer;
  rossinite feeds two reprocessor recipes) go to whichever consumer's product is furthest
  behind.
- Products settle at equal coverage, which is exactly the recipe ratio, and nothing piles up
  beyond `bufferBlocks` (+ one batch).

The Insanite Block itself is the goal. It keeps being crafted until `goalBlocks` (0 = forever).
Without AE2 patterns the ingots stop at the buffer target.

## Control rods: waste production speed instead of energy demand

The core steers rods so reactors follow grid energy demand. For the reactors in the plugin
config, `rods.lua` replaces that law on the reactor object (`reactor.updateRods`; no core file is
edited). Per reactor, `rodControl` picks the law:

| `rodControl` | Rods follow | Default for |
| --- | --- | --- |
| `waste` | the burn rate the factory needs; energy is a by-product | reactors 5, 7 |
| `waste+power` | the same, but never slower than the core's energy law (the more withdrawn rod level wins) | reactors 6, 8 |
| `power` | the core's energy law (original behaviour) | — |

**Target burn rate** (mB of fuel per tick) for each reactor:

```
nominal = plant pace (blocks/tick) x this reactor's fuel per block x 1000 mB
target  = nominal x clamp(1 + rateGain x (bufferBlocks - blocks of its waste in ME), 0, rateMaxMult)
```

- **Plant pace:** the reprocessor's speed (1 operation per 40 ticks ÷ 156 operations per block)
  × `plantUtilization` ≈ 10.4 blocks/h. Override it with `plantBlocksPerHour`.
- **Nominal rates:** reactor 6 ≈ 26.5, reactor 8 ≈ 4.6, reactor 5 ≈ 2.3, reactor 7 ≈ 3.5 mB/t.
  That's exactly the 184 : 32 : 16 : 24 recipe ratio.
- **Correction:** a reactor whose waste is short runs faster (up to 2× when ME has none). One
  with surplus slows down, and stops at `bufferBlocks + 1/rateGain` blocks of stock.
- **Rod loop:** an integral loop moves rods `rodKi` %/s per 100% burn-rate error, measured from
  the core's averaged `fuelConsumedLastTick`. It holds still while the reactor has no fuel.

Safety and fallbacks:

- **SCRAM / OFF** are unchanged: they write rods directly, and the core only calls
  `updateRods` while RUNNING.
- **Errors:** if the substituted law throws, that pass falls back to the core energy law. A
  plugin bug can't trip the core's "control loop exception" SCRAM.
- **Stale targets:** if the factory stops sending targets for `rodStaleSeconds` (bridge
  missing, plugin crashed), every reactor reverts to the core energy law.
- **Energy share:** reactors still on energy control (`power`, `waste+power`, and reactors not in
  the plugin config) share only the grid drain the `waste` reactors don't already cover. Without
  this, they would under-produce because the core splits demand across every reactor.

## In-world setup checklist

1. **Reactor ports on the wired network.** Put a wired modem on every reactor port the plugin
   uses, right-click it, and copy the name into `/insanite.conf` (`inlet` / `outlet`).
   Fuel feeding for a reactor is off until its `inlet` is set.
2. **Port modes per reactor** (a reactor holds one fuel type at a time):
   - Reactor 6 (yellorium): Solid Access Port **inlet**, Solid Access Port **outlet**
     → cyanite ingots.
   - Reactor 8 (yellorium): Solid Access Port **inlet**, Fuel Injection Port **outlet**
     → cyanite *fluid*. Not connected yet; it's in the config already.
   - Reactor 5 (blutonium): Solid Access Port **inlet**, Fuel Injection Port **outlet**
     → magentite *fluid* (no single-solid fluidizer needed).
   - Reactor 7 (verderium): Fuel Injection Port **inlet**, Fuel Injection Port **outlet**
     → rossinite fluid.
3. **Outputs back to ME.** Reactor outlets, the Reprocessor Output Port and the Fluidizer
   Output Port must end up in ME. Either pipe/import-bus them, or put them on the wired
   network and set `outlet` / `machines.<name>.output` so the plugin empties them.
4. **Nothing else may feed** the reprocessor injectors, fluidizer injectors or reactor inlets.
   Remove export buses/pipes into them. In particular, the reprocessor's single fluid injector is
   shared by water, cyanite, magentite and rossinite, so water must come from ME too.
5. **ME stock**: yellorium, water, benitoite crystals (mined), netherite blocks.
6. **AE2 patterns** (optional, for `autoCraft`): Inanite Block and Insanite Block shaped
   crafting patterns with molecular assemblers.

## Configuration

Defaults: `src/plugins/insanite/config.lua`. Per-computer overrides: `/insanite.conf` (only the
keys you set; nested tables merge, lists replace, `false` removes a default entry).

| Key | Default | Meaning |
| --- | --- | --- |
| `bridge` | `me_bridge_2` | ME Bridge peripheral name (network name, not `bottom`) |
| `cycleSeconds` | 5 | Planning interval |
| `bufferBlocks` | 2 | Intermediates are held at this many blocks' worth |
| `goalBlocks` | 0 | Stop crafting Insanite Blocks at this many in ME (0 = never) |
| `maxBatchOps` | 16 | Max operations loaded into a batch machine at once |
| `stallSeconds` | 60 | Unchanged machine contents for this long → repair attempt |
| `autoCraft` | true | Request AE2 crafts for the blocks |
| `fuelLowPct` / `fuelHighPct` | 40 / 80 | Reactor fuel top-up band |
| `ejectWasteAbovePct` | 0 | >0 calls `doEjectWaste()` above this waste % |
| `monitor` | nil | Peripheral name of a monitor to dedicate to the status screen |
| `plantBlocksPerHour` | 0 | Pace the rod targets are sized for (0 = from the reprocessor) |
| `plantUtilization` | 0.9 | Derating of the derived pace |
| `rateGain` / `rateMaxMult` | 0.5 / 3 | Burn-rate correction per block of waste surplus/shortage, and its cap |
| `rodKi` / `rodDeadband` | 5 / 0.02 | Rod loop speed (%/s at 100% error) and ignored error |
| `rodStaleSeconds` | 60 | Revert to the core energy law if targets stop arriving |
| `reactors[id]` | see file | `fuel`, `waste`, `mode` (`always`/`demand`), `rodControl`, `inlet`, `outlet` |
| `machines[name]` | see file | `ports`, `limits`, optional `output` |

Status is also written to `/insanite/status.txt` every cycle, but a dedicated `monitor` is the
practical way to watch it while the controller is running.

## Install / update

```text
wget run https://raw.githubusercontent.com/milesduncan23/cc-reactor-controller/main/install-insanite.lua
reboot
```

The core `install.lua` updates only its own files, so the plugin survives core updates.

## Limits worth knowing

- **Energy from `waste` reactors is not regulated.** Reactors 5 and 7 make whatever energy
  their burn rate gives. If you also need reactors 6/8 purely for waste, set them to `waste`.
  The grid is then no longer protected by energy demand.
- **Rod loop tuning is untested in-game.** If a reactor's burn hunts or reacts slowly, change
  `rodKi` (lower = smoother, higher = faster).
- **Mixed outlets.** Give each reactor one outlet type. A reactor with both solid and fluid
  outlets splits its waste unpredictably between them.

## Tests

```text
lua test/insanite_sim.lua
```

The test checks the per-block numbers, the hook, and a 6-hour fake plant built from raw
materials. It asserts no recipe mixing, no stuck leftovers, bounded intermediates and
throughput near the reprocessor limit. It also covers the no-pattern case, stall repair after
a reboot, and demand-only fueling. For rod control it checks:

- burn targets in the recipe ratio
- the rod loop settling on and following targets
- `waste+power` arbitration
- stale-target and error fallback to the core law
- the corrected energy share
- a 6-hour plant where fuel burned per reactor matches the recipe ratio
