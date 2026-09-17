--------------------------------------------------------------------
-- GTNH Flocculation Tank Controller
-- OpenComputers + Adapter touching the multiblock controller
--
-- Requires: Adapter block placed directly against the Flocculation
-- Tank controller (exposes the "gt_machine" component).
-- Requires: a Redstone I/O block/card wired to the pump that feeds
-- the tank. The pump moves 100,000 L per 5 ticks WHILE redstone is
-- held high, continuously, for as long as the signal stays on.
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
    ui_refresh            = 0.25,

    -- Redstone side wired to the pump
    redstone_side         = sides.west,
    redstone_on           = 15,
    redstone_off          = 0,

    -- Pump throughput: 100,000 L every 5 ticks while redstone is high.
    liters_per_batch      = 100000,
    ticks_per_batch       = 5,

    -- Total volume to insert per run before shutting the pump off.
    target_liters         = 1000000,

    -- Minecraft ticks per second (vanilla, assumes server isn't lagging).
    ticks_per_second      = 20,

    -- Safety: also halt immediately if the flocculation tank reports a
    -- problem/maintenance flag, even mid-batch.
    halt_on_problem       = true,

    -- How long a single Flocculation Tank operation takes, in seconds.
    -- The input must fill only ONCE per operation, so after a fill
    -- completes we refuse to re-arm until this much time has passed
    -- since that fill finished.
    machine_cycle_seconds = 120,
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

-- "idle"     : pump off, ready -- a run can be started
-- "pumping"  : pump on, timing the fill batch
-- "cooldown" : fill just completed, waiting out the machine's
--              operation cycle before it can be re-armed
local state = "idle"
local run_start_time = nil
local cooldown_start_time = nil
local liters_delivered = 0
local last_redstone = nil
local halted_reason = nil

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

local function safe_call(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result else return nil end
end

local function machine_has_problem()
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
    local hasProblems = safe_call(machine.hasProblems)
    if hasProblems ~= nil then return hasProblems end
    return false
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
        -- The machine's 120s operation began at run_start_time (redstone
        -- went high), not when the fill finished. The fill (2.5s) is a
        -- sub-window of that operation, so the cooldown must count from
        -- run_start_time, not from now -- otherwise the total cycle
        -- becomes 120s + 2.5s instead of the correct 120s.
        state = "cooldown"
        cooldown_start_time = run_start_time
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
        local elapsed = computer.uptime() - cooldown_start_time
        if elapsed >= CONFIG.machine_cycle_seconds then
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
        local elapsed = computer.uptime() - cooldown_start_time
        local remaining = math.max(0, CONFIG.machine_cycle_seconds - elapsed)
        print(("Op. cycle    : %.1fs / %ds"):format(elapsed, CONFIG.machine_cycle_seconds))
        print(("Re-arm in    : %.1fs"):format(remaining))
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

        local _, _, _, key = event.pull(CONFIG.ui_refresh, "key_down")
        if key then
            local ch = string.char(key ~= 0 and key or 0):lower()
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
