-- Insanite factory plugin: control-rod law based on required waste production speed.
--
-- The core controller steers every reactor's rods for ENERGY demand (reactor:updateRods(),
-- called each control pass while AUTO is running). For reactors this plugin manages, the
-- instance's updateRods field is replaced (it shadows the class method, so no core file is
-- edited) with one of these laws, chosen per reactor by `rodControl` in the plugin config:
--
--   "waste"        Rods track a target fuel burn rate (mB/t): the waste production speed the
--                  factory needs from this reactor. Energy is a by-product.
--   "waste+power"  Same, but never burn slower than the core's energy law asks for. The more
--                  withdrawn of the two rod levels wins, so the required waste is produced and
--                  the grid is never starved.
--   "power"        The core's energy law, sharing only the grid drain that "waste" reactors
--                  don't already cover with their by-product energy.
--
-- Burn targets come from InsaniteFactory every cycle (see factory.lua: rate targets). If they
-- stop arriving for rodStaleSeconds (plugin stopped/erroring), every reactor falls back to the
-- unmodified core law. An error inside a substituted law also falls back to the core law for
-- that pass, so the plugin can never trip the core's "control loop exception" SCRAM.
-- SCRAM/OFF still work exactly as before: they write rods directly, and the core only calls
-- updateRods while RUNNING.

local Rods = {}

local settings = { ki = 5, deadband = 0.02, staleSeconds = 60, minWrite = 0.5 }
local enabled = false
local modes = {}     -- reactorId -> "waste" | "waste+power" | "power"
local targets = {}   -- reactorId -> required burn, mB/t
local noFuel = {}    -- reactorId -> true while the reactor has (almost) no fuel to burn
local state = {}     -- reactorId -> { level, at, measured, powerLevel, powerWins, mode, lastError }
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
    if not fresh() then return "power" end
    return modes[id] or "power"
end

-- Grid drain per energy-following passive reactor, minus what "waste" reactors already make.
local function powerShare()
    local s = _G.overallStats or {}
    local covered, followers = 0, 0
    for id, r in pairs(_G.reactors or {}) do
        if not r.activelyCooled then
            if modeOf(id) == "waste" then
                covered = covered + (r.averageLastRFT or 0)
            else
                followers = followers + 1
            end
        end
    end
    return math.max(0, (s.rfLost or 0) - covered) / math.max(1, followers)
end

-- Run the core energy law with the corrected share. capture=true returns the rod level the
-- core wanted instead of writing it (its own PID state still advances, which is clamped).
local function runCore(reactor, capture)
    local law = coreLaw(reactor)
    if not law then return nil end
    local s = _G.overallStats
    local savedShare = s and s.rfLostPerReactor
    if s and not reactor.activelyCooled then s.rfLostPerReactor = powerShare() end
    local captured, realSet
    if capture then
        realSet = reactor.setRodLevels
        reactor.setRodLevels = function(level) captured = level end
    end
    local ok, err = pcall(law, reactor)
    if capture then reactor.setRodLevels = realSet end
    if s then s.rfLostPerReactor = savedShare end
    if not ok then error(err, 0) end
    return captured
end

-- Integral law: move rods toward the burn rate target. Positive error (burning too slowly)
-- withdraws rods. `hold` freezes the integrator (no fuel, or the energy law is in charge).
local function wasteLevel(reactor, st, target, hold)
    local t = now()
    local dt = clamp(t - (st.at or t), 0, 1)
    st.at = t
    st.measured = (reactor.averageFuelUsage or 0) * 1000 -- B/t -> mB/t
    if st.level == nil then st.level = reactor.rodLevel or 100 end
    if target <= 0 then
        st.level = 100
    elseif not hold then
        local err = clamp((target - st.measured) / target, -1, 1)
        if math.abs(err) > settings.deadband then
            st.level = clamp(st.level - settings.ki * err * dt, 0, 100)
        end
    end
    return st.level
end

local function writeRods(reactor, level)
    local threshold = math.max((CONTROL_CONFIG and CONTROL_CONFIG.rodWriteThreshold) or 0, settings.minWrite)
    local current = reactor.rodLevel
    if current ~= nil and math.abs(level - current) < threshold then return end
    reactor.setRodLevels(level)
    reactor.lastWrittenRodLevel = level
end

local function managedUpdateRods(self)
    if not self.active then return end
    local mode = modeOf(self.id)
    local ok, err = pcall(function()
        if mode == "power" then
            runCore(self, false)
            return
        end
        local st = state[self.id] or {}
        state[self.id] = st
        st.mode = mode
        local target = targets[self.id] or 0

        local hold = noFuel[self.id] == true
        if mode == "waste+power" then
            local p = runCore(self, true)
            if p ~= nil then st.powerLevel = p end
            st.powerWins = st.powerLevel ~= nil and st.level ~= nil and st.powerLevel < st.level
            hold = hold or st.powerWins
        else
            st.powerLevel, st.powerWins = nil, false
        end

        local level = wasteLevel(self, st, target, hold)
        if mode == "waste+power" and st.powerLevel ~= nil then
            level = math.min(level, st.powerLevel)
        end
        writeRods(self, level)
        st.lastError = nil
    end)
    if not ok then
        local st = state[self.id] or {}
        state[self.id] = st
        st.lastError = tostring(err)
        local law = coreLaw(self)
        if law then law(self) end
    end
end

-- Called once at plugin init.
function Rods.configure(cfg)
    settings.ki = cfg.rodKi or settings.ki
    settings.deadband = cfg.rodDeadband or settings.deadband
    settings.staleSeconds = cfg.rodStaleSeconds or settings.staleSeconds
    modes, state, targets, noFuel, stampedAt = {}, {}, {}, {}, nil
    enabled = false
    for id, r in pairs(cfg.reactors or {}) do
        if r then
            modes[id] = r.rodControl or "power"
            if modes[id] ~= "power" then enabled = true end
        end
    end
    return enabled
end

-- Called every factory cycle with fresh burn targets (mB/t) and reactor fuel readings.
function Rods.update(newTargets, reactorInfo)
    targets = newTargets or {}
    noFuel = {}
    for id, info in pairs(reactorInfo or {}) do
        noFuel[id] = (not info.present) or (info.fuelAmount or 0) < 1000
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

function Rods.enabled() return enabled end
function Rods.state(id) return state[id] end
function Rods.target(id) return targets[id] end
function Rods.modeOf(id) return modeOf(id) end

-- Exposed for tests.
Rods._managedUpdateRods = managedUpdateRods
Rods._powerShare = powerShare

_G.InsaniteRods = Rods
