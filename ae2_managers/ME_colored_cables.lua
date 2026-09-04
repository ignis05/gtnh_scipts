local component = require("component")
local term = require("term")
local me = component.me_interface

-- All 16 standard Minecraft dye colors used in GTNH AE2 cable names
local COLORS = {
  "White", "Orange", "Magenta", "Light Blue", "Yellow", "Lime",
  "Pink", "Gray", "Light Gray", "Cyan", "Purple", "Blue",
  "Brown", "Green", "Red", "Black"
}

local maintainList = {}

-- Generate maintain targets matching GTNH exact labels ("ME Covered Cable - <Color>")
for _, color in ipairs(COLORS) do
  table.insert(maintainList, {
    label = "ME Covered Cable - " .. color,
    target = 264,
    batch = 24
  })
  table.insert(maintainList, {
    label = "ME Dense Covered Cable - " .. color,
    target = 32,
    batch = 8
  })
end

-- Checks if all available crafting CPUs are currently busy
function areAllCpusBusy()
  local cpus = me.getCpus()
  if not cpus or #cpus == 0 then return true end
  
  for _, cpu in ipairs(cpus) do
    if not cpu.busy then
      return false
    end
  end
  return true
end

function checkAndRestock()
  -- Clear terminal screen and reset cursor position to top-left
  term.clear()

  if areAllCpusBusy() then
    print("[AE2 Monitor] All CPUs busy or unavailable. Waiting...")
    return
  end

  local storedItems = me.getItemsInNetwork()
  if not storedItems then return end

  print("================ [Stock Check] ================")
  local requestMade = false

  for _, spec in ipairs(maintainList) do
    local currentAmount = 0
    
    -- Find total quantity currently in network by display name
    for _, item in ipairs(storedItems) do
      if item.label == spec.label then
        currentAmount = item.size
        break
      end
    end

    -- Print current stock levels
    print(string.format("%-32s | %d/%d", spec.label, currentAmount, spec.target))

    -- Request crafting order if below target (limit 1 request per loop pass)
    if currentAmount < spec.target and not requestMade then
      -- Pass filter directly to OpenComputers AE2 driver
      local craftables = me.getCraftables({label = spec.label})
      
      if craftables and #craftables > 0 then
        local missing = spec.target - currentAmount
        local amountToOrder = math.min(missing, spec.batch)
        
        print(string.format("  ==> Requesting %dx '%s'...", amountToOrder, spec.label))
        
        local status = craftables[1].request(amountToOrder)
        if status then
          print("  ==> Order successfully submitted to AE2 CPU.")
          requestMade = true
        else
          print("  [!] Request failed (missing ingredients or CPU allocation failure).")
        end
      else
        print(string.format("  [!] NO PATTERN FOUND in ME system for '%s'", spec.label))
      end
    end
  end
end

-- Main loop with tick delay
while true do
  checkAndRestock()
  os.sleep(5)
end