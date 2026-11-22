# Insanite factory plugin

Keeps the ME system stocked with a balanced **kit** for crafting Insanite Blocks: insanite and
inanite ingots plus everything upstream of them, each in recipe ratio. It does this by
controlling three things:

1. **What goes into the reprocessor and fluidizer, and when.** One recipe at a time, in whole
   operations.
2. **How fast the four reactors burn.** Only the burn rate: **reactor fuel is fed by your own ME
   importer**, never by the plugin.
   - **R5 and R7 are locked together:** one common rate, split in exact recipe ratio, set by the
     kit reserve.
   - **R6 + R8 burn uranium ingots and are a "stock" pool, outside the lock.** They burn flat out
     until ME holds a configured amount of cyanite (`stockCaps.cyanite`, default 4096), giving you
     energy and spare cyanite, and stop while ME holds fewer than `stockFuelFloor.cyanite`
     (200,000) uranium ingots. The rest of the plant draws on that cyanite as it needs.
3. **Two AE2 craft requests, and nothing else:** liquid cyanite (from cyanite ingots) and liquid
   magentite (from magentite ingots). Each is requested only while ME holds
   less than its target, and only if `autocraft` in `/insanite.conf` allows it. Crafting the
   blocks out of the kit is up to you.

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
| 2 uranium + 1 blutonium → 2 B verderium (ATM10's recipe) | Fluidizer (mixing) | 12 ops |
| 1 cyanite ingot → 1 B liquid cyanite | AE2 craft | 32 crafts |
| 1 magentite ingot → 1 B liquid magentite | AE2 craft | 16 crafts |
| verderium → rossinite (fluid) | Reactor 7 | 24 B burned |
| blutonium → magentite (ingots) | Reactor 5 | 16 ingots burned |
| uranium → cyanite (ingots) | Reactors 6 + 8 (stock pool) | 216 ingots' worth; they burn more to fill the cyanite cap |

Extreme Reactors burns uranium ingots exactly like yellorium. ATM10 replaces the fluidizer's
verderium recipe (2 yellorium ingots + 1 blutonium in the base mod) with 2 uranium ingots +
1 blutonium (`kubejs/server_scripts/mods/ExtremeReactors/Recipes.js`), so no yellorium is used
anywhere.

Raw inputs per block: **240 uranium ingots** (216 burned by reactors 6 + 8, 24 into the fluidizer
for verderium), **128 benitoite, 92 B water, 1 netherite block**.
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

- The single reprocessor runs the recipe whose product is furthest behind, except that the
  **blutonium recipe always goes first** (see below).
- Other scarce shared inputs (blutonium feeds the reprocessor and the fluidizer; rossinite feeds
  two reprocessor recipes) go to whichever consumer's product is furthest behind.

**Blutonium first.** The blutonium recipe is marked `priority = true` in `config.lua`. While
blutonium is below target and the reprocessor is free or already running blutonium, the recipe
is planned before everything else and **holds its cyanite** (up to one full load, 10 ingots),
even when there's only one ingot and it needs two. The liquid-cyanite craft only gets cyanite
beyond that: when more than a full load is waiting, when blutonium is at target, or while the
reprocessor is busy with another recipe. The status screen shows the craft as
`needs cyanite (held for blutonium)`. A held ingot doesn't block the reprocessor: it runs other
recipes while blutonium waits for its pair.

**All inputs or nothing.** A job is only planned for whole operations ME holds every input for.
Just before loading, the plugin reads ME again (an importer may have taken something since the
cycle began) and loads only what every input is still there for. It loads the scarcest input
first (fluidizer: blutonium before uranium; reprocessor: cyanite before water), so if that one
can't be moved, nothing has gone in. The status screen then says
`needs blutonium (gone before loading)`.

Loads are always whole operations into an empty machine, so recipes never mix. If a later input
still comes up short (another device took it in the moment between the two exports), the load is
topped up, and contents that sit unchanged for `stallSeconds` are treated as stalled and topped
up to whole operations.

None of this touches your ME importers: holds are only the plugin's own planning, nothing in ME
is locked, and the importers can take anything at full speed.

## Reactors: one locked rate, plus a stock pool

Reactors that make the same waste form a **pool**: R6 + R8 (cyanite), R5 (magentite),
R7 (rossinite). Each reactor's `rodControl` decides how its pool runs:

| `rodControl` | Pool | Behaviour |
| --- | --- | --- |
| `ratio` | R5, R7 | Locked: burns exactly its recipe share of the common plant rate |
| `stock` | R6 + R8 | Outside the lock: fills ME with its waste up to `stockCaps` |
| `power` | — | Left on the core's energy-demand control |

### Stock pool (R6 + R8 → cyanite)

- **Filling:** below the cap, R6 and R8 burn flat out. With `stockMaxBurn.cyanite = N`, they burn
  N mB/t together instead, split evenly unless one is at its max.
- **At the cap** (`stockCaps.cyanite`, ingots) they stop. They restart once ME has dropped
  `stockTaperPct` (10%) below the cap, so they don't flicker on and off.
- **Fuel floor:** your importer feeds them uranium straight from ME, so they stop whenever ME
  holds fewer than `stockFuelFloor.cyanite` uranium ingots (200,000 in `/insanite.conf`). They
  resume `stockFuelResumePct` (5%) above it, at 210,000. The fluidizer uses that same uranium,
  so the floor also keeps it supplied. The status line then reads
  `stopped: ME uranium … is under the 200000 floor (resumes at 210000)`.
- **Outside the safeguards meant for the lock:** the overflow guard ignores cyanite (a full cap is
  the point, not a blockage), it isn't part of the slowest-reactor limit, and it has no `dev`
  value. The only alert it raises is running out of fuel while filling.
- **Status screen:** a `Stock R6+R8 -> cyanite 1758/4096: filling` line, cyanite shown as
  `cap 4096`, and stock reactors in cyan with `max` as their target.

### Locked pools (R5, R7)

```
demand     = clamp(demandGain × (stockBlocks − finished kit in ME), 0, 1)
plant rate = max pace × demand, then capped by overflow and by the slowest pool
pool p     = plant rate × its fuel per block × trim_p
trim_p     = clamp(1 + trimGain × (stockBlocks − its waste in ME), 1 − maxTrim, 1 + maxTrim)
```

- **The reserve drives the rate.** "Finished kit" is the smaller of insanite ÷ 8 and inanite ÷ 8.
  When you craft blocks and the kit drops, the plant speeds up. Full speed is reached once the kit
  is a block or more short. When the kit is back at `stockBlocks`, all four reactors stop.
- **Locked ratio.** Each ratio pool gets the same plant rate times its fuel per block: R5 : R7 =
  16 : 24 mB of fuel, about 2.3 : 3.5 mB/t at max pace. If you set R6 + R8 back to `ratio`, they
  join the lock at 216 per block (about 31.2 mB/t between them).
- **Inside a pool** with several reactors, the target is split evenly. A member that can't reach
  its share is held at its maximum, and the others take the rest.
- **The slowest ratio pool sets the pace for all ratio pools.** If a reactor's rods are fully out for
  `capacitySeconds` and it still burns below its target, its measured burn is recorded as its max.
  Once every member of a pool is at its max, the plant rate drops so the pool's target equals its
  combined max, and the other pools drop with it. This works in both directions. While a reactor
  keeps up, its recorded max is raised 2% per cycle so the plant probes back up. It's forgotten
  once its rods are back above 20%. The status screen names the limit, e.g. `R5 max burn` or
  `R6+R8 max burn`.
- **Trim (±25%).** This only corrects leftover imbalances, such as a pre-existing cyanite
  surplus. Set `maxTrim = 0` for a strictly locked ratio.
- **Overflow guard.** If one reactor's waste piles up above `stockBlocks` (something downstream is
  blocked, e.g. no benitoite), the whole plant slows. It reaches a full stop at
  `stockBlocks + overflowBlocks`, instead of filling ME. A large alert says so and names the cause
  (see Alerts).
- **Fuel is not the plugin's job.** Your ME importer refuels the reactors. The plugin only reads
  each reactor's fuel level. A reactor with an empty tank holds its rods still, shows
  `out of fuel (ME importer?)`, and after `deviationAlertSeconds` raises an alert.

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
- **`rodControl = "power"`**: left on the core's energy-demand law, not rate-locked. Reactors on energy control (including any reactor not in the plugin config) share
  only the grid drain the ratio reactors don't already cover.

Safety and fallbacks:

- **SCRAM / OFF** are unchanged: they write rods directly, and the core only calls `updateRods`
  while RUNNING.
- **Errors:** if the substituted law throws, that pass falls back to the core energy law. A plugin
  bug can't trip the core's "control loop exception" SCRAM.
- **Stale targets:** if the factory stops sending targets for `rodStaleSeconds` (bridge missing,
  plugin crashed), every reactor reverts to the core energy law.

## AE2 craft requests (two, and only two)

| Craft | Used for | Per Insanite Block |
| --- | --- | --- |
| `cyanite_fluid` | The ludicrite recipe; made by AE2 from cyanite ingots | 32 B (32 ingots) |
| `magentite_fluid` | The ridiculite recipe; made by AE2 from magentite ingots | 16 B (16 ingots) |

- **When:** a craft is requested when ME holds less than `stockBlocks` worth, AE2 has a pattern,
  and AE2 isn't already crafting it. The amount is the shortfall, at most `maxCraftItems` (64)
  ingots or `maxCraftFluid` (16 B) per request.
- **Competing for cyanite:** the liquid-cyanite craft and the blutonium recipe both use cyanite
  ingots. The blutonium recipe gets them first (see "Blutonium first" above); the craft gets what's
  left over.
- **Turning one off:** `autocraft.<name> = false` in `/insanite.conf`.
- **Limit:** the allowlist is enforced in the model and again just before calling AE2, so nothing
  else can ever be requested, whatever the config says.
- **Missing pattern:** if a pattern is missing, the status screen says `no AE2 pattern` and a
  slowdown alert names it as the blocker.
- **Different recipe ratio:** if your pattern converts at a different ratio than 1 ingot →
  1000 mB, change `crafts.<name>.outQty` / `inputs` in `/insanite.conf` so the ratios stay right.

## Stop buttons

The **top row of the status monitor** holds two separate buttons, side by side with a gap. Each
one works on its own; tap it again to undo. A tap takes effect at once, without waiting for the
next 5 s cycle. A repeat tap on the same button within a second is ignored, since a held click
can fire twice.

| Button (gray = running) | When tapped (orange) | What it stops |
| --- | --- | --- |
| `[ STOP R5+R7 ]` | `[ R5+R7 STOPPED - START ]` | Every `"ratio"` reactor (R5 + R7) held at **exactly 100% rods**. R6 + R8 (`"stock"`) keep running exactly as before, cap and uranium floor included. |
| `[ STOP MACHINES + CRAFTS ]` | `[ MACHINES STOPPED - START ]` | **Nothing goes into the reprocessor or fluidizer**, not even the stall top-ups, and **no AE2 crafts** are requested. A batch already inside finishes on its own; a half-loaded machine waits. |

- **The reactor stop always holds.** It doesn't depend on the ME Bridge or on the plugin's cycle:
  if the bridge disappears or a cycle errors, R5 + R7 stay fully in instead of falling back to the
  core's energy control after `rodStaleSeconds`. When a reactor reconnects (the core builds a
  fresh reactor object with its energy law), the stop is re-applied on that same event.
- **AE2 crafts** (liquid cyanite, liquid magentite) stop with the machines button, and the recipes
  read `crafts stopped`. The reactor button doesn't affect them.
- **Your ME importers** are untouched by both.
- **No alarms of their own:** while either stop is on there are no slowdown alerts, and R5 + R7
  raise no off-target alerts while stopped. The screen shows an orange line for each stop that's
  on, recipes read `reprocessor loading stopped` (crafts: `crafts stopped`), and R5 + R7 read
  `stopped (rods in)`.
- **Survives reboots:** saved in `/insanite/paused` (`pauseFile`). Without a status monitor there
  are no buttons: delete that file and reboot to start everything again.

## Alerts and ratio deviation

Alerts appear as a **red banner across the top of the status monitor**. With `scadaAlarms` (default
on), they're also raised in the core's alarm list, so the main SCADA screen shows the alarm count
and the alarm page lists them. Alerts never SCRAM or stop anything.

| Alert | Raised when |
| --- | --- |
| `PLANT SLOWED to N%: <waste> piling up … Blocked: insanite needs benitoite` | The overflow guard has the plant `slowAlertPct` (25%) or more below what the kit reserve asks for. Raised immediately when a cause is found (a recipe waiting on a raw input, or a broken machine). With no cause found, only after `slowAlertSeconds` (10 min), since that's usually downstream catching up after a start. |
| `PLANT SLOWED to N%: R5 at its max burn …; other reactors matched` | A reactor's maximum burn is holding the whole plant 25%+ below the asked pace. |
| `PLANT SLOWED to N%: … Blocked: craft magentite_fluid: no AE2 pattern` | A missing AE2 pattern is the cause of a slowdown. |
| `R7 burning N% below its target … - out of fuel (check its ME importer)` | A reactor has been more than `deviationAlertPct` (15%) off its own burn target for `deviationAlertSeconds` (2 min). The reason is given where known: out of fuel, rods fully out, rods fully in. |
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

1. **Reactor fuel comes from your own ME importer** (not the plugin): uranium ingots into
   reactors 6 and 8, blutonium ingots into 5, liquid verderium into 7.
2. **Waste outlets** (a reactor holds one fuel type at a time):
   - Reactors 6 and 8 (uranium): Solid Access Port **outlet** → cyanite ingots.
   - Reactor 5 (blutonium): Solid Access Port **outlet** → magentite ingots.
   - Reactor 7 (verderium): Fuel Injection Port **outlet** → rossinite fluid.
3. **Outputs back to ME.** Reactor outlets, the Reprocessor Output Port and the Fluidizer Output
   Port must end up in ME. Either pipe or import-bus them, or put them on the wired network and set
   `outlet` / `machines.<name>.output` so the plugin empties them.
4. **AE2 patterns** for the crafts you enable: cyanite ingot → liquid cyanite, and magentite
   ingot → liquid magentite.
5. **Nothing else may feed** the reprocessor or fluidizer injectors. The reprocessor's single
   fluid injector is shared by water, liquid cyanite, liquid magentite and rossinite, so water must
   come from ME too.
6. **ME stock**: uranium ingots (over the 200,000 floor for R6 + R8 to run), water, benitoite
   crystals (mined), netherite blocks.
7. **Power.** The four reactors no longer follow energy demand. They stop when the kit is full.
   If your base depends on one of them for power, set that reactor's `rodControl = "power"` (it
   then leaves the locked ratio).

## Configuration

Configuration is split in two, and no peripheral name appears in any Lua file:

| File | Holds |
| --- | --- |
| **`/insanite.conf`** (on the computer; template `insanite.conf` in the repo) | **Every device, explicitly**: ME Bridge, status monitor, each machine's ports and output, and each reactor with its fuel, waste, rod mode and outlet. Plus which of the two AE2 crafts are allowed. Optionally, any tuning override. |
| `src/plugins/insanite/config.lua` | Game data and tuning only: item/fluid ids, recipes, machine capacities, peripheral kinds, thresholds. |

### Device definitions (`/insanite.conf`)

The repo's `insanite.conf` is your current in-game setup:

| Key | Value | Meaning |
| --- | --- | --- |
| `bridge` | `"me_bridge_2"` | ME Bridge, by its **network** name (`bottom` is refused, with an explanation) |
| `monitor` | `"monitor_3"` | Status monitor (`false` = none) |
| `referenceReactor` | `"BigReactors-Reactor_5"` | A `ratio` reactor the `dev` column compares against (optional) |
| `machines.reprocessor.ports` | `solid` = `…reprocessorwasteinjector_0`, `fluid` = `…reprocessorfluidinjector_0` | The two injectors |
| `machines.fluidizer.ports` | `a` = `…fluidizersolidinjector_0`, `b` = `…_1` | `a` gets uranium, `b` blutonium |
| `machines.<name>.output` | `false` | Output port for the plugin to empty into ME (`false` = piped/bused) |
| `reactors[id]` | 5 blutonium→magentite (`ratio`), 6 and 8 uranium→cyanite (`stock`), 7 verderium→rossinite (`ratio`, liquid in and out); all `outlet = false` | Every factory reactor (no `inlet`: your ME importer feeds them) |
| `stockCaps` | `cyanite = 4096` | How much of each stock pool's waste to keep in ME (ingots, or mB for fluids) |
| `stockFuelFloor` | `cyanite = 200000` | Each stock pool stops while ME holds less of its fuel than this (here uranium ingots) |
| `stockMaxBurn` | not set | Optional burn ceiling per stock pool, mB/t for all its reactors |
| `autocraft` | `cyanite_fluid`, `magentite_fluid` both `true` | Which of the two AE2 crafts may be requested |

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
| Typo'd key | `reactors["BigReactors-Reactor_5"].outlett is not a reactor setting (expected: fuel, waste, rodControl, outlet). Did you mean outlet?` |
| Fuel/waste mismatch | `….waste = "cyanite" doesn't match fuel = "blutonium". blutonium burns into "magentite" (ingots, from a Solid Access Port in outlet mode) or "magentite_fluid" (fluid, …).` |
| Same peripheral twice | `"…fluidizersolidinjector_0" is used for both machines.fluidizer.ports.a and reactors["…_6"].outlet.` |
| A craft that isn't allowed (including a leftover `yellorium = …` line) | `autocraft.yellorium: the plugin may only ask AE2 to craft cyanite_fluid, magentite_fluid. Remove that line; …` |
| A liquid from two sources | `"cyanite_fluid" would come from both reactors["…_8"] (waste = "cyanite_fluid") and autocraft.cyanite_fluid. Pick one: …` |
| Leftover `inlet` line | Warning only: `….inlet is no longer used (fuel is fed by your own ME importer, not the plugin). You can delete that line.` |
| Stock pool without a cap | `stockCaps is missing: … stockCaps = { cyanite = 4096,   -- R6+R8 burn until ME holds this },` |
| Stock pool without a fuel floor | `stockFuelFloor is missing: … stockFuelFloor = { cyanite = 200000,   -- R6+R8 stop while ME holds less uranium than this (ingots) },` |
| Half a pool in stock mode | `Reactors making "cyanite" disagree: R6 is "stock" but R8 is "ratio". … give them all the same rodControl.` |
| Side instead of network name | `bridge = "bottom" is a side of the computer, not a network name … use … bridge = "me_bridge_2",` |
| Syntax error | `/insanite.conf has a syntax error: /insanite.conf:16: '}' expected … Usually a missing comma after an entry …` |
| Whole section missing | A ready-to-paste `machines = { … }` / `reactors = { … }` block filled with the names on your network |

Warnings don't stop the plugin and show in yellow on the status screen. Examples: a defined device
that's offline (the message lists what *is* on the network), nothing producing something a recipe
needs (`Nothing here produces "magentite_fluid" … set autocraft.magentite_fluid = true, or …`), a
tuning key that isn't a setting (`Did you mean stockBlocks?`).

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
| `crafts.<name>` | see file | What one AE2 craft consumes (`inputs`) and makes (`outQty`); match your pattern |
| `maxCraftItems` / `maxCraftFluid` | 64 / 16000 | Most ingots / mB per AE2 request |
| `stockTaperPct` | 10 | A stock pool restarts once ME is this far below its cap |
| `stockFuelResumePct` | 5 | After stopping at `stockFuelFloor`, a stock pool resumes once its fuel is this % above the floor |
| `ejectWasteAbovePct` | 0 | >0 calls `doEjectWaste()` above this waste % |
| `pauseFile` | `/insanite/paused` | Which stop buttons are on (exists while any is) |
| `machines[name]` | see file | Capacities: `limits`, `opsPerTick` (ports come from `/insanite.conf`) |

## Status screen

A 4×4 Advanced Monitor fits it (about 45 lines, 79 characters wide). It shows:

- **Stop buttons:** the top row (see "Stop buttons").
- **Alert banner** (only when there are alerts): red, full width, right under the buttons.
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
- **A file from before AE2 autocraft** (it has reactor `inlet` lines and no `autocraft` section):
  it asks whether to replace it with the repo copy, keeping the old one as `/insanite.conf.old`.
- **A current file that defines devices:** it keeps it.

It then checks the config against the network and prints any problems.

The core `install.lua` updates only its own files, so the plugin survives core updates.

## Limits worth knowing

- **Rod loop tuning is untested in-game.** If a reactor's burn hunts, raise `rodTau` (slower,
  smoother). If it's sluggish, lower it.
- **Fuel load affects max burn.** In Extreme Reactors, a reactor with little fuel can't reach high
  burn rates. If a reactor is constantly the limit, have your ME importer keep its tank fuller.
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
- a weak blutonium reactor slowing R7 to match while the stock pool keeps filling cyanite
- stall repair after a reboot
- nothing being fueled when the kit is already full
- ratio deviation maths and reference fallback
- no benitoite: the plant slows, the alert names "insanite needs benitoite", it reaches the core
  alarm list, and it all clears once benitoite arrives
- the max-burn alert for a weak reactor
- a starved reactor (fluidizer port missing) giving "out of fuel" and machine alerts, and not
  being mistaken for a max-burn limit
- a healthy plant raising no alerts at all
- an ME importer refuelling the reactors (the plugin never feeds fuel)
- the stock pool: filling to its cap and no further, the restart gap, stopping under the 200k
  uranium floor and resuming at 210k,
  `stockMaxBurn`, not tripping the overflow guard, being left out of `dev`, burning more than the
  lock would allow, filling regardless of a weak R5, and R5:R7 staying at 16:24
- ratio mode for R6 + R8 (still supported): the 216:16:24 lock end to end, an even split, and a
  weak R8 covered by R6 without slowing anything
- batch loads: an input taken between reading ME and loading leaves the machine empty (no lone
  uranium in the fluidizer), and the scarcest input is loaded first
- blutonium first: one or two cyanite ingots are held from the liquid-cyanite craft while the
  reprocessor is free or running blutonium; the craft gets only what's beyond a full load, or
  everything once blutonium is at target or the reprocessor is busy on another recipe
- stop buttons: two separate blocks on the top row (taps on the gap, other rows or other
  monitors do nothing, a double-fired tap is ignored). The reactor button alone: R5 + R7 at
  exactly 100% rods burning nothing, R6 + R8 still burning, machines still loaded, no alerts. The
  machine button: nothing loaded and no AE2 crafts, recipes say why. Both survive a
  reboot; R5 + R7 stay in with the ME Bridge gone and targets stale for 3 min; each undoes on its
  own; the real wait loop reacts to a tap at once; a reconnected reactor gets the hold on the
  same event
- AE2 crafts: only the two allowed are ever requested, with typed item/fluid filters, sized to
  the shortfall, never repeated while running, never when `autocraft` is false, and a missing
  pattern is shown and named as the blocker
- the config checker against the in-game peripheral list: the repo `insanite.conf` passes clean,
  and each common mistake gives its precise message (missing device or section, swapped ports,
  typos, fuel/waste mismatch, duplicate peripherals, side names, wrong value types, offline
  devices, missing file, syntax error with line number); the plugin refuses to start and writes
  `/insanite/config-problems.txt`
