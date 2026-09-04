local component = require("component")
local os = require("os")
local gpu = component.gpu
local me = component.me_interface

-- Fluid Configuration Array
local FLUIDS = {
  { target = "nitrobenzene", label = "Nitrobenzene", max = 2000000000, color = 0x744700 }, -- Brown
--  { target = "sulfuric acid", label = "Sulfuric Acid", max = 1000000000, color = 0xFF9933 }, -- Orange
--  { target = "lubricant", label = "Lubricant", max = 500000000, color = 0xFFFF66 }, -- Yellow
--  { target = "cetane-boosted diesel", label = "Cetane Diesel", max = 1000000000, color = 0x33FF99 }, -- Mint
}

-- Color Definitions for thresholds (Hex format for OpenComputers Tier 2/3 GPU)
local COLOR_WHITE  = 0xFFFFFF
local COLOR_RED    = 0xFF3333 -- <= 10%
local COLOR_ORANGE = 0xFFAA00 -- <= 30%
local COLOR_GREEN  = 0x33FF33 -- > 30%

-- set resolution to make text large assuming big screen is used
gpu.setResolution(80, 25)

local function formatNumber(n)
  return tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function getStatusColor(percentage)
  if percentage <= 10 then
    return COLOR_RED
  elseif percentage <= 30 then
    return COLOR_ORANGE
  else
    return COLOR_GREEN
  end
end

-- Clear the whole screen once at startup
local initW, initH = gpu.maxResolution()
gpu.fill(1, 1, initW, initH, " ")

while true do
  local w, h = gpu.getResolution()
  local BAR_WIDTH = math.max(10, w - 10)

  -- Fetch network fluids once per loop
  local fluidAmounts = {}
  local success, networkFluids = pcall(function() return me.getFluidsInNetwork() end)
  
  if success and type(networkFluids) == "table" then
    for _, fluid in pairs(networkFluids) do
      local name = string.lower(fluid.label or fluid.name or "")
      for i, cfg in ipairs(FLUIDS) do
        if string.find(name, string.lower(cfg.target)) then
          fluidAmounts[i] = (fluidAmounts[i] or 0) + (fluid.amount or 0)
        end
      end
    end
  end

  -- Dynamic UI layout calculation (4 lines per fluid block including the empty line)
  local linesPerFluid = 4
  local totalUiHeight = 3 + (#FLUIDS * linesPerFluid) + 1
  local startY = math.max(1, math.floor((h - totalUiHeight) / 2))

  local function drawCentered(yPos, text, color)
    gpu.setForeground(color or COLOR_WHITE)
    local x = math.floor((w - string.len(text)) / 2) + 1
    gpu.fill(1, yPos, w, 1, " ")
    gpu.set(x, yPos, text)
  end

  -- Render Header
  gpu.setForeground(COLOR_WHITE)
  gpu.fill(1, startY, w, 1, " ")
  gpu.set(1, startY, string.rep("=", w))
  
  drawCentered(startY + 1, "BASE MONITOR", COLOR_WHITE)
  
  gpu.fill(1, startY + 2, w, 1, " ")
  gpu.set(1, startY + 2, string.rep("=", w))
  gpu.fill(1, startY + 3, w, 1, " ")

  -- Render Fluid Array
  local currentY = startY + 4
  for i, cfg in ipairs(FLUIDS) do
    local currentAmount = fluidAmounts[i] or 0
    local ratio = math.min(currentAmount / cfg.max, 1.0)
    local percentage = ratio * 100
    local filledChars = math.floor(ratio * BAR_WIDTH)
    local emptyChars = BAR_WIDTH - filledChars

    local bar = "[" .. string.rep("=", filledChars) .. string.rep(".", emptyChars) .. "]"
    local statusColor = getStatusColor(percentage)

    -- Line 1: Name (Custom Color) and Percentage (Status Color)
    local pctStr = string.format("%.2f%%", percentage)
    local separatorStr = " : "
    local totalLen = string.len(cfg.label) + string.len(separatorStr) + string.len(pctStr)
    local startX = math.floor((w - totalLen) / 2) + 1

    gpu.fill(1, currentY, w, 1, " ") -- Clear the line first
    
    -- Draw Label
    gpu.setForeground(cfg.color or COLOR_WHITE)
    gpu.set(startX, currentY, cfg.label)
    
    -- Draw Separator
    gpu.setForeground(COLOR_WHITE)
    gpu.set(startX + string.len(cfg.label), currentY, separatorStr)
    
    -- Draw Percentage
    gpu.setForeground(statusColor)
    gpu.set(startX + string.len(cfg.label) + string.len(separatorStr), currentY, pctStr)

    -- Line 2: Progress Bar
    drawCentered(currentY + 1, bar, statusColor)

    -- Line 3: Stored / Max Amounts
    drawCentered(
      currentY + 2, 
      string.format("Stored: %s / %s mB", formatNumber(currentAmount), formatNumber(cfg.max)), 
      statusColor
    )

    -- Line 4: Blank line separator
    gpu.fill(1, currentY + 3, w, 1, " ")

    currentY = currentY + linesPerFluid
  end

  gpu.setForeground(COLOR_WHITE)

  os.sleep(2)
end