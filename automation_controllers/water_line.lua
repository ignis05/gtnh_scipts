--------------------------------------------------------------------
-- GTNH Flocculation Tank Controller
-- OpenComputers + Adapter touching the multiblock controller
--
-- Requires: Adapter block placed directly against the Flocculation
-- Tank controller (exposes the "gt_machine" component).
-- Requires: a Redstone I/O block/card wired to the pump that feeds
-- the tank. The pump moves 100,000 L per 5 ticks WHILE redstone is
-- held high, continuously, for as long as the signal stays on.
--
-- Operation-cycle detection uses the controller directly:
--   isMachineActive()  -- is the machine currently running a cycle
--   getWorkProgress()  -- ticks into the current cycle
-- The input re-arms only once the machine reports not-active OR we
-- observe progress reset back down (a completed cycle), so a fill
-- can never be started twice within one operation.
--------------------------------------------------------------------

local component      = require("component")
local sides          = require("sides")
local term           = require("term")
local event          = require("event")
local computer       = require("computer")

--------------------------------------------------------------------
-- CONFIGURATION -- edit these to match your setup
--------------------------------------------------------------------

local CONFIG         = {
    -- How often to refresh the status display (seconds). This is just
    -- a UI refresh rate -- it does NOT gate the pump timing.
    ui_refresh       = 0.25,

    -- Redstone side wired to the pump
    redstone_side    = sides.south,
    redstone_on      = 15,
    redstone_off     = 0,

    -- Pump throughput: 100,000 L every 5 ticks while redstone is high.
    liters_per_batch = 100000,
    ticks_per_batch  = 5,

    -- Total volume to insert per run before shutting the pump off.
    target_liters    = 1000000,

    -- Minecraft ticks per second (vanilla, assumes server isn't lagging).
    ticks_per_second = 20,

    -- Safety: also halt immediately if the flocculation tank reports a
    -- problem/maintenance flag, even mid-batch.
    halt_on_problem  = true,
}

-- Derived: exact real-time seconds of redstone-high needed to move
-- exactly target_liters, given the pump's continuous throughput.
local BATCH_SECONDS  = CONFIG.ticks_per_batch / CONFIG.ticks_per_second
local BATCHES_NEEDED = CONFIG.target_liters / CONFIG.liters_per_batch
local RUN_SECONDS    = BATCHES_NEEDED * BATCH_SECONDS -- 2.5s for the stated numbers

--------------------------------------------------------------------
-- COMPONENT SETUP
--------------------------------------------------------------------

if not component.isAvailable("gt_machine") then
    io.stderr:write("No gt_machine component found.\n")
    io.stderr:write("Make sure an Adapter is placed directly touching\n")
    io.stderr:write("the Flocculation Tank controller block.\n")
    os.exit(1)
end
local machine = component.gt_machine

if not component.isAvailable("redstone") then
    io.stderr:write("No redstone component found -- cannot control the pump.\n")
    os.exit(1)
end
local redstone = component.redstone

--------------------------------------------------------------------
-- STATE
--------------------------------------------------------------------

-- "idle"     : machine not active, not mid-cycle -- a run can be started
-- "pumping"  : pump on, timing the fill batch
-- "cooldown" : fill finished; waiting for the machine's operation
--              cycle (isMachineActive / getWorkProgress) to actually
--              finish before re-arming
local state = "idle"
local run_start_time = nil
local liters_delivered = 0
local last_redstone = nil
local halted_reason = nil
local last_seen_progress = nil -- tracks getWorkProgress() across ticks

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

local function safe_call(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result else return nil end
end

local function machine_has_problem()
    local hasProblems = safe_call(machine.hasProblems)
    if hasProblems ~= nil then return hasProblems end

    local sensor = safe_call(machine.getSensorInformation)
    if sensor then
        for _, line in ipairs(sensor) do
            local l = tostring(line):lower()
            if l:find("problem") or l:find("issue") or l:find("wrench")
                or l:find("screwdriver") or l:find("maintenance") then
                return true
            end
        end
    end
    return false
end

-- True while the controller is actively running an operation cycle.
local function machine_active()
    local active = safe_call(machine.isMachineActive)
    if active ~= nil then return active end
    return false -- unknown -- treat as not-active rather than block forever
end

-- True once the current cycle has genuinely finished. We can't trust
-- a single reading of "progress >= max" -- on a skipped/lagged tick,
-- the machine can jump straight from mid-cycle progress to 0 (the
-- next cycle already starting) without us ever polling it AT max.
-- So instead we watch for the actual reset: progress dropping back
-- down from where it was, which only happens when one cycle ends and
-- (at earliest) the next begins. Returns nil if unavailable.
local function machine_cycle_reset_detected()
    local progress = safe_call(machine.getWorkProgress)
    if progress == nil then
        last_seen_progress = nil
        return nil -- unknown
    end

    local reset = false
    if last_seen_progress ~= nil and progress < last_seen_progress then
        reset = true
    end
    last_seen_progress = progress
    return reset
end

local function set_redstone(level)
    if last_redstone == level then return end
    redstone.setOutput(CONFIG.redstone_side, level)
    last_redstone = level
end

local function start_run()
    state = "pumping"
    run_start_time = computer.uptime()
    liters_delivered = 0
    halted_reason = nil
    set_redstone(CONFIG.redstone_on)
end

local function stop_pump(reason, completed_fill)
    set_redstone(CONFIG.redstone_off)
    halted_reason = reason
    if completed_fill then
        -- Fill is done, but the machine's own operation cycle may still
        -- be running (it started when redstone went high). Wait for the
        -- controller itself to report the cycle as finished before this
        -- can be re-armed, so it's impossible to fill twice in one op.
        state = "cooldown"
        last_seen_progress = nil -- start tracking fresh from this point
    else
        state = "idle"
    end
end

--------------------------------------------------------------------
-- MAIN TICK LOGIC
--------------------------------------------------------------------

local function tick()
    if state == "pumping" then
        local elapsed = computer.uptime() - run_start_time

        if CONFIG.halt_on_problem and machine_has_problem() then
            -- Aborted mid-fill due to a fault: does NOT count as a
            -- completed operation, so no cooldown -- go straight to idle
            -- so it can be retried once the fault clears.
            stop_pump("machine problem/maintenance flag", false)
            return
        end

        -- Liters delivered so far, capped at the target for display purposes.
        liters_delivered = math.min(
            CONFIG.target_liters,
            (elapsed / BATCH_SECONDS) * CONFIG.liters_per_batch
        )

        if elapsed >= RUN_SECONDS then
            liters_delivered = CONFIG.target_liters
            stop_pump(string.format("target of %d L reached", CONFIG.target_liters), true)
        end
    elseif state == "cooldown" then
        -- Re-arm only once we've actually observed the cycle end: either
        -- the controller reports not-active, or we caught progress reset
        -- back down (the tell-tale sign of a completed cycle, even if we
        -- never happened to poll it sitting exactly at max).
        local active = machine_active()
        local reset_seen = machine_cycle_reset_detected()

        local ready
        if reset_seen ~= nil then
            ready = (not active) or reset_seen
        else
            -- getWorkProgress unavailable on this build -- fall back to
            -- "not active" alone.
            ready = not active
        end

        if ready then
            state = "idle"
            halted_reason = "operation cycle complete -- ready to re-arm"
        end
    end
end

--------------------------------------------------------------------
-- DISPLAY
--------------------------------------------------------------------

local function draw()
    term.clear()
    print("=== Flocculation Tank Feed Pump ===")
    print(("State        : %s"):format(state))
    if state == "pumping" then
        local elapsed = computer.uptime() - run_start_time
        local remaining = math.max(0, RUN_SECONDS - elapsed)
        print(("Elapsed      : %.2fs / %.2fs"):format(elapsed, RUN_SECONDS))
        print(("Remaining    : %.2fs"):format(remaining))
    elseif state == "cooldown" then
        local active = machine_active()
        local progress = safe_call(machine.getWorkProgress)
        print(("Machine active : %s"):format(active and "yes" or "no"))
        if progress then
            print(("Work progress  : %s (watching for reset)"):format(tostring(progress)))
        else
            print("Work progress  : unavailable on this build")
        end
    end
    print(("Delivered    : %d L / %d L"):format(
        math.floor(liters_delivered), CONFIG.target_liters))
    print(("Redstone out : %s"):format(
        last_redstone == CONFIG.redstone_on and "ON" or "off"))
    if halted_reason then
        print(("Last stop    : %s"):format(halted_reason))
    end
    print("")
    if state == "idle" then
        print("Press S to start a run, Q to quit.")
    elseif state == "pumping" then
        print("Press X to abort the run early, Q to quit.")
    else -- cooldown
        print("Machine operation in progress -- input locked. Press Q to quit.")
    end
end

--------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------

local function main()
    local running = true
    while running do
        tick()
        draw()

        local _, _, char, code = event.pull(CONFIG.ui_refresh, "key_down")
        if char then
            local ch = (char ~= 0) and string.char(char):lower() or nil
            if ch == "q" then
                running = false
            elseif ch == "s" and state == "idle" then
                start_run()
            elseif ch == "x" and state == "pumping" then
                stop_pump("aborted by operator", false)
            end
        end
    end

    -- Always leave the pump OFF on exit -- never leave it running
    -- unattended past the intended batch.
    set_redstone(CONFIG.redstone_off)
    term.clear()
    print("Flocculation feed controller stopped. Pump is OFF.")
end

main()
