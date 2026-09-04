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

  -- Build a hash map for fast item lookup by label
  local itemMap = {}
  for _, item in ipairs(storedItems) do
    if item.label then
      itemMap[item.label] = item.size
    end
  end

  -- Collect current stock status and calculate stock ratio (percentage)
  local statusList = {}
  for _, spec in ipairs(maintainList) do
    local currentAmount = itemMap[spec.label] or 0
    local ratio = currentAmount / spec.target
    table.insert(statusList, {
      spec = spec,
      current = currentAmount,
      ratio = ratio
    })
  end

  -- Sort list by available stock percentage ascending (lowest % first)
  table.sort(statusList, function(a, b)
    if a.ratio == b.ratio then
      return a.spec.label < b.spec.label
    end
    return a.ratio < b.ratio
  end)

  print("================ [Stock Check (Priority Order)] ================")

  local targetToCraft = nil

  for _, item in ipairs(statusList) do
    local spec = item.spec
    local pct = math.floor(item.ratio * 100)
    
    -- Print current stock levels and percentages
    print(string.format("%-32s | %4d/%-4d (%3d%%)", spec.label, item.current, spec.target, pct))

    -- Pick the item with the lowest stock percentage that is under target
    if item.current < spec.target and not targetToCraft then
      targetToCraft = item
    end
  end

  -- Dispatch craft order for the highest-priority item
  if targetToCraft then
    local spec = targetToCraft.spec
    local missing = spec.target - targetToCraft.current
    local amountToOrder = math.min(missing, spec.batch)

    print("\n------------------------------------------------")
    print(string.format("  ==> Requesting %dx '%s' (Stock: %d%%)...", 
          amountToOrder, spec.label, math.floor(targetToCraft.ratio * 100)))

    local craftables = me.getCraftables({label = spec.label})
    if craftables and #craftables > 0 then
      local status = craftables[1].request(amountToOrder)
      if status then
        print("  ==> Order successfully submitted to AE2 CPU.")
      else
        print("  [!] Request failed (missing ingredients or CPU allocation failure).")
      end
    else
      print(string.format("  [!] NO PATTERN FOUND in ME system for '%s'", spec.label))
    end
  end
end

-- Main loop with tick delay
while true do
  checkAndRestock()
  os.sleep(5)
end