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
-- Operation-cycle detection uses the controller directly via
-- isMachineActive(). The input re-arms only after we've evidenced
-- BOTH a genuine start (active goes true) AND a genuine finish
-- (active goes false again afterward) -- so a fill can never be
-- started twice within one operation, and completion is never
-- assumed just because the machine reads idle/inactive.
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
    redstone_side    = sides.west,
    redstone_on      = 15,
    redstone_off     = 0,

    -- Pump throughput: 200,000 L every 10 ticks while redstone is high.
    liters_per_batch = 200000,
    ticks_per_batch  = 10,

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
--              cycle to genuinely run to completion before re-arming.
--              Has two sub-phases (cooldown_phase below):
--                "waiting_for_start"  -- machine hasn't begun yet
--                "waiting_for_finish" -- machine confirmed active,
--                                        now waiting for it to finish
local state = "idle"
local run_start_time = nil
local liters_delivered = 0
local last_redstone = nil
local halted_reason = nil
-- Set true once the operator explicitly stops the loop. Checked
-- before every auto re-arm so a stop request actually sticks instead
-- of the next completed cycle silently starting a new run anyway.
local stop_requested = false

-- Sub-phase within "cooldown". We MUST observe the machine actually
-- go active before we can trust it going inactive as "finished" --
-- otherwise a machine that reads inactive/0 progress at idle (as
-- confirmed on this build) would look "already finished" the instant
-- cooldown begins, before it ever really ran. See cooldown_phase.
local cooldown_phase = nil -- "waiting_for_start" | "waiting_for_finish"
local cooldown_start_time = nil
local highest_progress_seen = 0

-- How long to wait for the machine to start picking up the delivered
-- liquid before we give up waiting and just re-check periodically.
-- (Guards against a stuck/never-true active flag hanging forever.)
local START_TIMEOUT_SECONDS = 30

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

local function set_redstone(level)
    if last_redstone == level then return end
    redstone.setOutput(CONFIG.redstone_side, level)
    last_redstone = level
end

local function start_run(skip_active_guard)
    -- Hard guard: never begin a fill while the machine is mid-operation,
    -- UNLESS we're re-arming immediately after confirming the previous
    -- cycle just finished (skip_active_guard) -- on this build, active
    -- can read true continuously across the boundary where one cycle
    -- ends and the next begins on the same tick, so insisting on
    -- active==false at that exact moment would refuse forever.
    if not skip_active_guard and machine_active() then
        halted_reason = "refused to start -- machine is already active"
        return false
    end
    stop_requested = false
    state = "pumping"
    run_start_time = computer.uptime()
    liters_delivered = 0
    halted_reason = nil
    set_redstone(CONFIG.redstone_on)
    return true
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
        cooldown_phase = "waiting_for_start"
        cooldown_start_time = computer.uptime()
        highest_progress_seen = 0
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
        -- We must observe the machine genuinely START before we can
        -- detect "finished". On this build:
        --   - isMachineActive() reads false/0-progress even at genuine
        --     idle, so seeing "active" alone isn't enough to prove a
        --     cycle ran -- we also need to see progress move.
        --   - isMachineActive() can stay true continuously across the
        --     boundary between one cycle ending and the next starting
        --     (same-tick handoff), so "active goes false" is NOT a safe
        --     finish signal on this build -- it may never happen.
        -- The one signal that reliably survives a same-tick handoff is
        -- getWorkProgress() resetting back down after having climbed --
        -- that drop can only happen because one cycle ended, regardless
        -- of what "active" does at that instant.
        local active = machine_active()
        local progress = safe_call(machine.getWorkProgress)
        if progress and progress > highest_progress_seen then
            highest_progress_seen = progress
        end

        if cooldown_phase == "waiting_for_start" then
            -- Require BOTH active AND real nonzero progress, so a build
            -- quirk where active flickers true without real work can't
            -- fool us into thinking a cycle began.
            if active and progress and progress > 0 then
                cooldown_phase = "waiting_for_finish"
                halted_reason = "machine started operation -- waiting for it to finish"
            elseif computer.uptime() - cooldown_start_time > START_TIMEOUT_SECONDS then
                -- Never saw it start within the timeout. Don't assume
                -- anything finished -- just keep re-checking at a sane pace
                -- instead of firing a new fill blind.
                cooldown_start_time = computer.uptime()
                halted_reason = string.format(
                    "still waiting for machine to start (%ds, re-checking)",
                    START_TIMEOUT_SECONDS)
            end
            -- else: still waiting, nothing to do this tick.
        elseif cooldown_phase == "waiting_for_finish" then
            -- Completion signal: progress has dropped back down from the
            -- highest value we've seen this cycle. This is the ONE signal
            -- that still fires even when active stays true the whole way
            -- through a same-tick finish-then-restart handoff.
            local progress_reset = progress and progress < highest_progress_seen

            if progress_reset then
                if stop_requested then
                    state = "idle"
                    halted_reason = "operation cycle complete -- stopped by operator"
                else
                    -- Confirmed finish (progress reset) -- skip the active
                    -- guard, since active may already read true for the new
                    -- cycle that just began on this same tick.
                    if start_run(true) then
                        halted_reason = "operation cycle complete -- starting next fill"
                    end
                end
            elseif not active and not (progress and progress > 0) then
                -- Fallback: if progress reporting is unavailable/unreliable
                -- (nil, or stuck at 0) but active did drop to false, honor
                -- that as completion too -- better than waiting forever.
                if stop_requested then
                    state = "idle"
                    halted_reason = "operation cycle complete -- stopped by operator"
                else
                    if start_run() then
                        halted_reason = "operation cycle complete -- starting next fill"
                    end
                end
            end
            -- else: still running, nothing to do this tick.
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
        print(("Cooldown phase : %s"):format(cooldown_phase))
        print(("Machine active : %s"):format(active and "yes" or "no"))
        print(("Highest progress seen : %s"):format(tostring(highest_progress_seen)))
        if progress then
            print(("Work progress  : %s"):format(tostring(progress)))
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
        print("Press X to stop the loop, Q to quit.")
    else -- cooldown
        if stop_requested then
            print("Stopping after the current operation finishes. Press Q to quit.")
        elseif cooldown_phase == "waiting_for_start" then
            print("Waiting for machine to start its operation cycle.")
            print("Press X to stop the loop, Q to quit.")
        else
            print("Machine is running -- next fill auto-starts when it finishes.")
            print("Press X to stop the loop, Q to quit.")
        end
    end
end

--------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------

local function main()
    local running = true

    -- Sequence starts automatically the moment the script launches --
    -- no need to press S.
    start_run()

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
            elseif ch == "x" and (state == "pumping" or state == "cooldown") then
                -- Stop the loop. If mid-fill, cut the pump immediately. If
                -- mid-cooldown (waiting on the machine's own cycle), just
                -- flag that we should NOT auto-start the next fill once the
                -- cycle finishes -- we can't interrupt the machine's cycle
                -- itself, only decline to feed it again.
                stop_requested = true
                if state == "pumping" then
                    stop_pump("aborted by operator", false)
                else
                    halted_reason = "stop requested -- will halt after this cycle"
                end
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
