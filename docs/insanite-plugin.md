# Insanite factory plugin

Keeps the ME system stocked with a balanced **kit** for crafting Insanite Blocks: insanite and
inanite ingots plus everything upstream of them, each in recipe ratio. It does this by
controlling only two things:

1. **What goes into the reprocessor and fluidizer, and when.** One recipe at a time, in whole
   operations.
2. **How fast the four reactors burn.** One common rate, split in exact recipe ratio, so the
   yellorium reactors burn exactly as much as the blutonium and verderium reactors can, and the
   other way round.

It does **not** use AE2 autocrafting. Crafting the blocks out of the kit is up to you, by hand or
with your own AE2 setup.

The plugin lives entirely in `src/plugins/insanite/` (plus this doc, `install-insanite.lua` and
`test/insanite_sim.lua`). No core file is modified: `src/scripts/main.lua` already loads every
file under `src/`, and `hook.lua` wraps the core `main()` so the factory runs as a second
coroutine beside the reactor control loop.

## The ratios

All numbers are derived at boot from the recipe table in `config.lua`, starting from one kit
(**8 insanite + 8 inanite + 1 netherite block** = 1 Insanite Block):

| Step | Machine | Per Insanite Block |
| --- | --- | --- |
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
Reprocessor time per block: 156 ops × 2 s ≈ 5.2 min. The reprocessor sets the maximum pace,
about 10.4 blocks/h at 90% utilization.

## Reserves: what "correct ratios in ME" means

For each material, **coverage** = ME stock ÷ per-block need = "how many Insanite Blocks' worth
ME holds". Every material produced here is held at `stockBlocks` coverage (default 2), so ME
always contains the chain in recipe ratio. The status screen shows each material as
`have/target` in blocks.

## Batch machines

Every 5 s, every product below target that has inputs available becomes a candidate. Candidates
are sorted by coverage, lowest first, so:

- The single reprocessor always runs the recipe whose product is furthest behind.
- Scarce shared inputs (blutonium feeds the reprocessor, reactor 5 and the fluidizer; rossinite
  feeds two reprocessor recipes) go to whichever consumer's product is furthest behind.

Loads are always whole operations into an empty machine, so recipes never mix. A short load is
topped up, and contents that sit unchanged for `stallSeconds` are treated as stalled and topped
up to whole operations.

## Reactors: one locked rate

```
demand     = clamp(demandGain × (stockBlocks − finished kit in ME), 0, 1)
plant rate = max pace × demand, then capped by overflow and by the slowest reactor
reactor i  = plant rate × its fuel per block × trim_i
trim_i     = clamp(1 + trimGain × (stockBlocks − its waste in ME), 1 − maxTrim, 1 + maxTrim)
```

- **The reserve drives the rate.** "Finished kit" is the smaller of insanite ÷ 8 and inanite ÷ 8.
  When you craft blocks and the kit drops, the plant speeds up. Full speed is reached once the kit
  is a block or more short. When the kit is back at `stockBlocks`, all four reactors stop.
- **Locked ratio.** Each reactor gets the same plant rate times its fuel per block, i.e.
  184 : 32 : 16 : 24 mB of fuel, about 26.5 : 4.6 : 2.3 : 3.5 mB/t at max pace.
- **The slowest reactor sets the pace for all.** If a reactor's rods are fully out for
  `capacitySeconds` and it still burns below its target, its measured burn is recorded as its
  max. The plant rate drops so its target equals that max, and the other three drop with it. The
  same goes for any reactor, so it works in both directions. While it keeps up, the recorded max
  is raised 2% per cycle so the plant probes back up. It's forgotten once its rods are back above
  20%. The status screen names the limiting reactor.
- **Trim (±25%).** This only corrects leftover imbalances, such as a pre-existing cyanite
  surplus. Set `maxTrim = 0` for a strictly locked ratio.
- **Overflow guard.** If one reactor's waste piles up above `stockBlocks` (something downstream is
  blocked, e.g. no benitoite), the whole plant slows. It reaches a full stop at
  `stockBlocks + overflowBlocks`, instead of filling ME. A large alert says so and names the cause
  (see Alerts).
- **Fuel follows the rate.** Each reactor is kept fueled for `fuelLeadSeconds` at its target,
  within `fuelMinPct`–`fuelMaxPct` of its fuel capacity. Nothing is fed while its target is 0, so
  blutonium and verderium aren't hoarded in reactor tanks.

### How the rods are driven

The core steers rods for energy demand through `reactor:updateRods()`. For managed reactors,
`rods.lua` puts its own `updateRods` on the reactor object (no core file is edited).

Burn falls roughly in proportion to rod insertion. Each pass estimates the burn per % of rod
withdrawal at the reactor's current operating point (from the core's averaged
`fuelConsumedLastTick` and rod level), works out the rod level that gives the target, and moves
there with time constant `rodTau`. Because that estimate is re-measured where the reactor actually
is, the loop behaves the same for a 1 mB/t or a 100 mB/t reactor, and at high or low targets. Until
anything is burning, it steps at `rodKi`. It holds still while the reactor has no fuel, and always
lands exactly on 0% / 100% at the ends.

- **`rodControl = "ratio"`** (default for all four): part of the locked rate. Energy is a
  by-product and is **not** regulated.
- **`rodControl = "power"`**: left on the core's energy-demand law and kept fueled, but not
  rate-locked. Reactors on energy control (including any reactor not in the plugin config) share
  only the grid drain the ratio reactors don't already cover.

Safety and fallbacks:

- **SCRAM / OFF** are unchanged: they write rods directly, and the core only calls `updateRods`
  while RUNNING.
- **Errors:** if the substituted law throws, that pass falls back to the core energy law. A plugin
  bug can't trip the core's "control loop exception" SCRAM.
- **Stale targets:** if the factory stops sending targets for `rodStaleSeconds` (bridge missing,
  plugin crashed), every reactor reverts to the core energy law.

## Alerts and ratio deviation

Alerts appear as a **red banner across the top of the status monitor**. With `scadaAlarms` (default
on), they're also raised in the core's alarm list, so the main SCADA screen shows the alarm count
and the alarm page lists them. Alerts never SCRAM or stop anything.

| Alert | Raised when |
| --- | --- |
| `PLANT SLOWED to N%: <waste> piling up … Blocked: insanite needs benitoite` | The overflow guard has the plant `slowAlertPct` (25%) or more below what the kit reserve asks for. Raised immediately when a cause is found (a recipe waiting on a raw input, or a broken machine). With no cause found, only after `slowAlertSeconds` (10 min), since that's usually downstream catching up after a start. |
| `PLANT SLOWED to N%: R5 at its max burn …; other reactors matched` | A reactor's maximum burn is holding the whole plant 25%+ below the asked pace. |
| `R7 burning N% below its target … - out of fuel` | A reactor has been more than `deviationAlertPct` (15%) off its own burn target for `deviationAlertSeconds` (2 min). The reason is given where known: out of fuel, rods fully out, rods fully in. |
| `REPROCESSOR stalled on …` / `port missing` / `unknown contents` | A batch machine can't run. |
| `ME BRIDGE … NOT FOUND` | The factory is paused. |

An alert clears once its cause has been gone for `alertClearSeconds` (30 s). A slowdown alert stays
up until the plant is back within 15% of the asked pace, so it doesn't flicker around the threshold.

In simulation, a healthy plant never dips more than about 22% below the asked pace (normal buffer
swings). That's why the slowdown alert starts at 25%: it doesn't trip in normal running, and a real
blockage trips it straight away.

**Deviation column.** Each reactor's `dev` is its burn pace compared with the reference reactor
(`referenceReactor`, default R6), in recipe ratio: `dev = (burn ÷ fuel per block) ÷ (R6's) − 1`.
0% means exactly in ratio. Trim moves this on purpose, so the line under the table lists what trim
alone accounts for (e.g. `R5 -40%`). A `!` and orange text mark a reactor that is off by more than
trim explains. If R6 isn't burning, the first burning reactor becomes the reference.

## In-world setup checklist

1. **Reactor ports on the wired network.** Put a wired modem on every reactor port the plugin
   uses, right-click it, and copy the name into that reactor's `inlet` / `outlet` in
   `/insanite.conf` (they're `false` until then). Fuel feeding for a reactor is off while its
   `inlet` is `false`.
2. **Port modes per reactor** (a reactor holds one fuel type at a time):
   - Reactor 6 (yellorium): Solid Access Port **inlet**, Solid Access Port **outlet** → cyanite
     ingots.
   - Reactor 8 (yellorium): Solid Access Port **inlet**, Fuel Injection Port **outlet** →
     cyanite *fluid*.
   - Reactor 5 (blutonium): Solid Access Port **inlet**, Fuel Injection Port **outlet** →
     magentite *fluid*.
   - Reactor 7 (verderium): Fuel Injection Port **inlet**, Fuel Injection Port **outlet** →
     rossinite fluid.
3. **Outputs back to ME.** Reactor outlets, the Reprocessor Output Port and the Fluidizer Output
   Port must end up in ME. Either pipe or import-bus them, or put them on the wired network and set
   `outlet` / `machines.<name>.output` so the plugin empties them.
4. **Nothing else may feed** the reprocessor injectors, fluidizer injectors or reactor inlets.
   The reprocessor's single fluid injector is shared by water, cyanite, magentite and rossinite,
   so water must come from ME too.
5. **ME stock**: yellorium, water, benitoite crystals (mined), netherite blocks.
6. **Power.** The four reactors no longer follow energy demand. They stop when the kit is full.
   If your base depends on one of them for power, set that reactor's `rodControl = "power"` (it
   then leaves the locked ratio).

## Configuration

Configuration is split in two, and no peripheral name appears in any Lua file:

| File | Holds |
| --- | --- |
| **`/insanite.conf`** (on the computer; template `insanite.conf` in the repo) | **Every device, explicitly**: ME Bridge, status monitor, each machine's ports and output, and each reactor with its fuel, waste, rod mode, inlet and outlet. Optionally, any tuning override. |
| `src/plugins/insanite/config.lua` | Game data and tuning only: item/fluid ids, recipes, machine capacities, peripheral kinds, thresholds. |

### Device definitions (`/insanite.conf`)

The repo's `insanite.conf` is your current in-game setup:

| Key | Value | Meaning |
| --- | --- | --- |
| `bridge` | `"me_bridge_2"` | ME Bridge, by its **network** name (`bottom` is refused, with an explanation) |
| `monitor` | `"monitor_2"` | Status monitor (`false` = none). **Check this is the right one.** |
| `referenceReactor` | `"BigReactors-Reactor_6"` | Reactor the `dev` column compares against (optional) |
| `machines.reprocessor.ports` | `solid` = `…reprocessorwasteinjector_0`, `fluid` = `…reprocessorfluidinjector_0` | The two injectors |
| `machines.fluidizer.ports` | `a` = `…fluidizersolidinjector_0`, `b` = `…_1` | `a` gets yellorium, `b` blutonium |
| `machines.<name>.output` | `false` | Output port for the plugin to empty into ME (`false` = piped/bused) |
| `reactors[id]` | 5 blutonium→magentite (fluid), 6 yellorium→cyanite, 7 verderium→rossinite, 8 yellorium→cyanite (fluid); all `rodControl = "ratio"`, `inlet = false`, `outlet = false` | Every factory reactor |

**Nothing may be left out.** `false` means "none" and has to be written explicitly. At boot the
plugin checks the file against the devices actually on the network. If anything is wrong, it does
**not start**. Reactors stay on the core's energy control, and it says exactly what to fix on:

- the computer screen
- the status monitor (if `monitor` is usable)
- the SCADA alarm list
- `/insanite/config-problems.txt`

It re-checks every 30 s and starts by itself once the file is fixed. The installer runs the same
check.

It catches, among others:

| Mistake | Message (abridged) |
| --- | --- |
| Missing device | `machines.reprocessor.ports.fluid is missing: the Reprocessor Fluid Injector that receives Rossinite (l) / Magentite (l) / Cyanite (l) / Water. Add inside machines.reprocessor.ports: fluid = "bigreactors:reprocessorfluidinjector_0",` (the name found on your network) |
| Swapped ports | `machines.reprocessor.ports.fluid = "…wasteinjector_0" is a bigreactors:reprocessorwasteinjector, but it must be a Reprocessor Fluid Injector … did you swap fluid and solid?` |
| Typo'd key | `reactors["BigReactors-Reactor_5"].inlett is not a reactor setting (expected: fuel, waste, rodControl, inlet, outlet). Did you mean inlet?` |
| Fuel/waste mismatch | `….waste = "cyanite" doesn't match fuel = "blutonium". blutonium burns into "magentite_fluid" (fluid, from a Fuel Injection Port in outlet mode).` |
| Same peripheral twice | `"…fluidizersolidinjector_0" is used for both machines.fluidizer.ports.a and reactors["…_6"].inlet.` |
| Side instead of network name | `bridge = "bottom" is a side of the computer, not a network name … use … bridge = "me_bridge_2",` |
| Syntax error | `/insanite.conf has a syntax error: /insanite.conf:16: '}' expected … Usually a missing comma after an entry …` |
| Whole section missing | A ready-to-paste `machines = { … }` / `reactors = { … }` block filled with the names on your network |

Warnings don't stop the plugin and show in yellow on the status screen. Examples: a defined device
that's offline (the message lists what *is* on the network), no reactor producing a waste a recipe
needs, a tuning key that isn't a setting (`Did you mean stockBlocks?`).

### Tuning (defaults in `config.lua`, override in `/insanite.conf`)

| Key | Default | Meaning |
| --- | --- | --- |
| `kit` | 8 insanite, 8 inanite, 1 netherite | What one Insanite Block is crafted from |
| `stockBlocks` | 2 | Reserve target for every material, in Insanite Blocks' worth |
| `cycleSeconds` | 5 | Planning interval |
| `maxBatchOps` | 16 | Max operations loaded into a batch machine at once |
| `stallSeconds` | 60 | Unchanged machine contents for this long → repair attempt |
| `plantBlocksPerHour` | 0 | Max pace override (0 = from the reprocessor × `plantUtilization`) |
| `plantUtilization` | 0.9 | Derating of the derived max pace |
| `demandGain` | 1 | Pace per block of kit shortage (1 = full speed at 1 block short) |
| `maxTrim` / `trimGain` | 0.25 / 0.25 | Per-reactor ratio correction (0 = strictly locked) |
| `overflowBlocks` | 4 | Waste this far above target stops the plant |
| `rodTau` | 5 | Seconds for the rods to settle on a new target |
| `rodKi` / `rodDeadband` | 5 / 0.02 | Start-up step (%/s) before burn-per-% is known; ignored error |
| `deviationAlertPct` / `deviationAlertSeconds` | 15 / 120 | Reactor off its own target by this much, this long → alert |
| `slowAlertPct` | 25 | Plant this much slower than the reserve asks → alert |
| `slowAlertSeconds` | 600 | …but only after this long when no cause is found |
| `alertClearSeconds` | 30 | Alert clears once its cause has been gone this long |
| `scadaAlarms` | true | Also raise alerts in the core's alarm list (SCADA screen) |
| `capacitySeconds` | 30 | Rods fully out this long and still short → reactor at its max |
| `rodStaleSeconds` | 60 | Revert to the core energy law if targets stop arriving |
| `fuelLeadSeconds` | 600 | Fuel kept in a reactor, in seconds of burn at its target |
| `fuelMinPct` / `fuelMaxPct` | 10 / 80 | Bounds on that fuel, % of reactor fuel capacity |
| `ejectWasteAbovePct` | 0 | >0 calls `doEjectWaste()` above this waste % |
| `machines[name]` | see file | Capacities: `limits`, `opsPerTick` (ports come from `/insanite.conf`) |

## Status screen

A 4×4 Advanced Monitor fits it (about 45 lines, 79 characters wide). It shows:

- **Alert banner** (only when there are alerts): red, full width, at the top.
- **Header:** kit coverage, how many blocks you could craft right now, and the plant rate vs max
  pace with what's limiting it (`kit reserve`, `kit full`, `R5 max burn`, `overflow rossinite`…).
- **Resources:** ME stock, per-block need and coverage. Green = at target, orange = short, red =
  a raw input under one block's worth.
- **Machines:** batch machine state and what each recipe is doing (`start x5`, `needs water`,
  `waiting`, `at target`).
- **Reactors:** mode, trim, fuel %, rods %, burn vs target (mB/t), deviation from the reference
  reactor, and `max` when its capacity is the limit.
- **Events:** the last 8 actions.

It's also written to `/insanite/status.txt` every cycle.

## Install / update

```text
wget run https://raw.githubusercontent.com/milesduncan23/cc-reactor-controller/main/install-insanite.lua
reboot
```

The installer handles `/insanite.conf` like this:

- **No file yet:** it creates one from the repo's `insanite.conf`.
- **An old-style file** (only tuning overrides, no devices): it moves it to `/insanite.conf.old`,
  installs the repo's file, and prints which settings the old file had so you can copy them over.
- **A file that already defines devices:** it keeps it.

It then checks the config against the network and prints any problems.

The core `install.lua` updates only its own files, so the plugin survives core updates.

## Limits worth knowing

- **Rod loop tuning is untested in-game.** If a reactor's burn hunts, raise `rodTau` (slower,
  smoother). If it's sluggish, lower it.
- **Fuel load affects max burn.** In Extreme Reactors, a reactor with little fuel can't reach high
  burn rates. If a reactor is constantly the limit, raise `fuelMinPct` or `fuelLeadSeconds`.
- **Mixed outlets.** Give each reactor one outlet type. A reactor with both solid and fluid
  outlets splits its waste unpredictably between them.

## Tests

```text
lua test/insanite_sim.lua
```

The test checks:

- per-block amounts
- the hook into the core `main()`
- locked rate targets: ratio, full/empty kit, slowest-reactor cap in both directions, trim,
  strict lock, overflow
- the rod loop: settling, following, max-burn learning and probing, stale and error fallback,
  energy share
- a 9-hour plant with a simulated player crafting blocks by hand. It asserts no AE2 calls, no
  recipe mixing or stuck batches, bounded reserves and fuel burned in recipe ratio, and that the
  kit refills and every reactor stops when crafting stops.
- a weak blutonium reactor pulling the yellorium reactors down to its pace
- stall repair after a reboot
- nothing being fueled when the kit is already full
- ratio deviation maths and reference fallback
- no benitoite: the plant slows, the alert names "insanite needs benitoite", it reaches the core
  alarm list, and it all clears once benitoite arrives
- the max-burn alert for a weak reactor
- a starved reactor (fluidizer port missing) giving "out of fuel" and machine alerts, and not
  being mistaken for a max-burn limit
- a healthy plant raising no alerts at all
- the config checker against the in-game peripheral list: the repo `insanite.conf` passes clean,
  and each common mistake gives its precise message (missing device or section, swapped ports,
  typos, fuel/waste mismatch, duplicate peripherals, side names, wrong value types, offline
  devices, missing file, syntax error with line number); the plugin refuses to start and writes
  `/insanite/config-problems.txt`
