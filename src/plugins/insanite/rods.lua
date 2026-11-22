-- Insanite factory plugin: control-rod law for the locked plant rate.
--
-- The core controller steers every reactor's rods for ENERGY demand (reactor:updateRods(),
-- called each control pass while AUTO is running). For reactors this plugin manages, the
-- instance's updateRods field is replaced (it shadows the class method, so no core file is
-- edited) with one of these laws, chosen per reactor by `rodControl` in the plugin config:
--
--   "ratio"  Rods track a target fuel burn rate (mB/t) from InsanitePlanner.rateTargets: one
--            common plant rate x this reactor's fuel per Insanite Block. Energy is a by-product.
--   "stock"  Same rod law, but the target comes from the reactor's stock pool (fill ME with its
--            waste up to a cap, flat out or at stockMaxBurn), outside the locked ratio.
--   "power"  The core's energy law, sharing only the grid drain that "ratio"/"stock" reactors
--            don't already cover with their by-product energy. Also used for reactors the
--            plugin doesn't manage.
--
-- Max-burn learning: when a "ratio" reactor's rods are fully withdrawn for capacitySeconds and
-- it still burns below target, its measured burn is recorded as its capacity. The planner then
-- lowers the common rate so every other reactor matches it. While it keeps up, the capacity is
-- raised 2% per factory cycle so the plant probes back up; it's forgotten once the rods are
-- well inserted again (the reactor clearly isn't the limit).
--
-- Reactor stop button (status monitor): the stopped reactors are "held": rods written fully in on
-- every pass, regardless of targets, staleness or plugin errors, until the button is tapped again.
--
-- Burn targets come from InsaniteFactory every cycle. If they stop arriving for rodStaleSeconds
-- (plugin stopped/erroring), every reactor falls back to the unmodified core law. An error inside
-- the substituted law also falls back to the core law for that pass, so the plugin can never trip
-- the core's "control loop exception" SCRAM. SCRAM/OFF still work exactly as before: they write
-- rods directly, and the core only calls updateRods while RUNNING.

local Rods = {}

local settings = { ki = 5, tau = 5, kSmoothing = 2, deadband = 0.02, staleSeconds = 60,
    capacitySeconds = 30, minWrite = 0.1 }
local enabled = false
local modes = {}     -- reactorId -> "ratio" | "stock" | "power"
local targets = {}   -- reactorId -> required burn, mB/t
local scales = {}    -- reactorId -> its burn at full plant pace, mB/t (fallback step size)
local noFuel = {}    -- reactorId -> true while the reactor has (almost) no fuel to burn
local state = {}     -- reactorId -> { level, at, measured, k, capacity, satSince, mode, lastError }
local held = {}      -- reactorId -> true while the reactor stop is on: rods fully in, no matter what
local stampedAt = nil

local function now() return os.clock() end

local function clamp(value, lo, hi)
    if value < lo then return lo end
    if value > hi then return hi end
    return value
end

local function coreLaw(reactor)
    local meta = getmetatable(reactor)
    local class = meta and meta.__index
    return type(class) == "table" and class.updateRods or nil
end

local function fresh()
    return stampedAt ~= nil and now() - stampedAt <= settings.staleSeconds
end

local function modeOf(id)
    if held[id] then return "held" end -- stopped: never falls back to the energy law
    if not fresh() then return "power" end
    return modes[id] or "power"
end

-- Grid drain per energy-following passive reactor, minus what "ratio"/"stock" reactors make.
local function powerShare()
    local s = _G.overallStats or {}
    local covered, followers = 0, 0
    for id, r in pairs(_G.reactors or {}) do
        if not r.activelyCooled then
            if modeOf(id) ~= "power" then
                covered = covered + (r.averageLastRFT or 0)
            else
                followers = followers + 1
            end
        end
    end
    return math.max(0, (s.rfLost or 0) - covered) / math.max(1, followers)
end

-- Run the core energy law with the corrected share.
local function runCore(reactor)
    local law = coreLaw(reactor)
    if not law then return end
    local s = _G.overallStats
    local savedShare = s and s.rfLostPerReactor
    if s and not reactor.activelyCooled then s.rfLostPerReactor = powerShare() end
    local ok, err = pcall(law, reactor)
    if s then s.rfLostPerReactor = savedShare end
    if not ok then error(err, 0) end
end

-- Skip writes that barely move the rods (server load), but always land exactly on the edges:
-- "almost fully in" still burns, and "almost fully out" hides a reactor's real maximum.
local function writeRods(reactor, level)
    if level >= 99.9 then level = 100 elseif level <= 0.1 then level = 0 end
    local threshold = math.max((CONTROL_CONFIG and CONTROL_CONFIG.rodWriteThreshold) or 0, settings.minWrite)
    local current = reactor.rodLevel
    if current ~= nil then
        local atEdge = (level == 100 or level == 0)
        if atEdge and math.abs(level - current) < 1e-6 then return end
        if not atEdge and math.abs(level - current) < threshold then return end
    end
    reactor.setRodLevels(level)
    reactor.lastWrittenRodLevel = level
end

-- Rod law. Burn rate falls roughly in proportion to rod insertion, so each pass estimates
-- k = burn (mB/t) per % of withdrawal at the reactor's CURRENT operating point (smoothed),
-- computes the rod level that would give the target (100 - target/k), and moves toward it with
-- time constant rodTau. Because k is re-measured where the reactor actually is, the loop behaves
-- the same for a 1 mB/t and a 100 mB/t reactor, at high and low targets, and still settles
-- exactly on target although the real curve isn't perfectly linear. Until k is known (nothing
-- burning yet), an integral step scaled by the reactor's full-pace burn is used instead.
-- Holds still while the reactor has no fuel (nothing to regulate).
local function ratioLaw(reactor, st, target)
    local t = now()
    local dt = clamp(t - (st.at or t), 0, 1)
    st.at = t
    st.measured = (reactor.averageFuelUsage or 0) * 1000 -- B/t -> mB/t
    if st.level == nil then st.level = reactor.rodLevel or 100 end
    local hold = noFuel[reactor.id] == true

    -- Same averaging window as the burn reading, so the two line up in time.
    local open = 100 - (reactor.averageRodLevel or reactor.rodLevel or st.level)
    if not hold and st.measured > 0 and open >= 1 then
        local k = st.measured / open
        st.k = st.k and (st.k + (k - st.k) * clamp(dt / settings.kSmoothing, 0, 1)) or k
    end

    if target <= 0 then
        st.level = 100
    elseif not hold then
        local err = (target - st.measured) / target
        if math.abs(err) > settings.deadband then
            if st.k and st.k > 0 then
                local want = clamp(100 - target / st.k, 0, 100)
                st.level = st.level + (want - st.level) * clamp(dt / settings.tau, 0, 1)
            else
                local scale = math.max(scales[reactor.id] or target, target)
                st.level = clamp(st.level - settings.ki * clamp((target - st.measured) / scale, -1, 1) * dt, 0, 100)
            end
        end
    end

    -- Max-burn learning: fully withdrawn, fueled, and still short of target.
    if target > 0 and not hold and st.level <= 1 and st.measured < 0.95 * target then
        st.satSince = st.satSince or t
        if t - st.satSince >= settings.capacitySeconds then
            st.capacity = st.capacity and (0.8 * st.capacity + 0.2 * st.measured) or st.measured
        end
    else
        st.satSince = nil
    end
    return st.level
end

local function managedUpdateRods(self)
    if not self.active then return end
    local mode = modeOf(self.id)
    local ok, err = pcall(function()
        if mode == "power" then
            runCore(self)
            return
        end
        local st = state[self.id] or {}
        state[self.id] = st
        st.mode = mode
        if mode == "held" then
            st.measured = (self.averageFuelUsage or 0) * 1000
            st.level, st.at, st.satSince = 100, now(), nil
            writeRods(self, 100)
            st.lastError = nil
            return
        end
        writeRods(self, ratioLaw(self, st, targets[self.id] or 0))
        st.lastError = nil
    end)
    if not ok then
        local st = state[self.id] or {}
        state[self.id] = st
        st.lastError = tostring(err)
        if held[self.id] then
            pcall(self.setRodLevels, 100) -- stopped stays stopped, even on an error
        else
            local law = coreLaw(self)
            if law then law(self) end
        end
    end
end

-- Called once at plugin init.
function Rods.configure(cfg)
    settings.ki = cfg.rodKi or settings.ki
    settings.tau = cfg.rodTau or settings.tau
    settings.deadband = cfg.rodDeadband or settings.deadband
    settings.staleSeconds = cfg.rodStaleSeconds or settings.staleSeconds
    settings.capacitySeconds = cfg.capacitySeconds or settings.capacitySeconds
    modes, state, targets, scales, noFuel, stampedAt, held = {}, {}, {}, {}, {}, nil, {}
    enabled = false
    for id, r in pairs(cfg.reactors or {}) do
        if r then
            modes[id] = r.rodControl or "ratio"
            if modes[id] ~= "power" then enabled = true end
        end
    end
    return enabled
end

-- Measured max burn (mB/t) per reactor that has hit its limit; read by the planner.
function Rods.capacities()
    local out = {}
    for id, st in pairs(state) do
        if st.capacity then out[id] = st.capacity end
    end
    return out
end

-- Called every factory cycle with fresh burn targets (mB/t), reactor fuel readings, and each
-- reactor's burn at full plant pace (mB/t, used to size steps before k is known).
function Rods.update(newTargets, reactorInfo, fullPace)
    targets = newTargets or {}
    scales = fullPace or scales
    noFuel = {}
    for id, info in pairs(reactorInfo or {}) do
        noFuel[id] = (not info.present) or (info.fuelAmount or 0) < 1000
    end
    -- Capacity bookkeeping: probe upward while the reactor keeps up; forget it once the rods
    -- are well inserted (it is clearly not the bottleneck any more).
    for _, st in pairs(state) do
        if st.capacity and not st.satSince then
            if (st.level or 100) > 20 then
                st.capacity = nil
            else
                st.capacity = st.capacity * 1.02
            end
        end
    end
    stampedAt = now()
end

-- Put the managed law on every reactor the core knows about (idempotent; the core rebuilds
-- reactor objects on reconnect, so this runs every cycle). Reactors not in the plugin config
-- get the "power" law, which only differs from the core by the corrected share.
function Rods.install()
    if not enabled then return end
    for _, reactor in pairs(_G.reactors or {}) do
        if rawget(reactor, "updateRods") ~= managedUpdateRods and coreLaw(reactor) then
            reactor.updateRods = managedUpdateRods
        end
    end
end

-- Reactors to hold fully inserted while the reactor stop is on ({ [id] = true }; {} = none).
function Rods.setHeld(set) held = set or {} end

function Rods.enabled() return enabled end
function Rods.state(id) return state[id] end
function Rods.target(id) return targets[id] end
function Rods.modeOf(id) return modeOf(id) end

-- Exposed for tests.
Rods._managedUpdateRods = managedUpdateRods
Rods._powerShare = powerShare

_G.InsaniteRods = Rods
