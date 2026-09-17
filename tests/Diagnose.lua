-- Diagnostic: dump everything the gt_machine component exposes.
-- Run this once, then copy/paste (or screenshot) the output so we
-- can see the EXACT sensor wording and available methods for your
-- GTNH version.

local component = require("component")
local term = require("term")

if not component.isAvailable("gt_machine") then
    print("No gt_machine component found on this computer.")
    return
end

local machine = component.gt_machine

print("=== gt_machine documentation / method list ===")
local doc_ok, doc = pcall(function() return component.doc("gt_machine") end)
if doc_ok and doc then
    print(doc)
else
    -- Fallback: list methods directly
    local methods = component.methods(component.list("gt_machine")())
    for name, _ in pairs(methods or {}) do
        print(" - " .. name)
    end
end

print("")
print("=== getSensorInformation() ===")
local ok, sensor = pcall(machine.getSensorInformation)
if ok and sensor then
    for i, line in ipairs(sensor) do
        print(i .. ": " .. tostring(line))
    end
else
    print("Not available or errored: " .. tostring(sensor))
end

print("")
print("=== other common getters ===")
local tries = {
    "isMachineActive", "hasProblems", "getName", "getWorkProgress",
    "getWorkMaxProgress", "getEUVar", "getOutputBusFillPercentage",
    "getTankFillPercentage", "isWorkAllowed", "isActive",
}
for _, name in ipairs(tries) do
    if machine[name] then
        local ok2, val = pcall(machine[name])
        print(name .. "() = " .. tostring(val) .. (ok2 and "" or " (errored)"))
    else
        print(name .. "() -- not present on this component")
    end
end
