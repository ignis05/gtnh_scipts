local component = require("component")
local os = require("os")
local gpu = component.gpu
local me = component.me_interface

-- Adding items/fluids:
-- 1. Use ctrl+X to copy item id from nei
-- 2. If id ends with slash and number (this will always be the case for fluids), set the part after slash as damage in the config array
-- ex: see below, nitrobenzene copied as "gregtech:gt.GregTech_FluidDisplay/1184"

-- Fluid Configuration Array 
local FLUIDS = {
  { name = "gregtech:gt.GregTech_FluidDisplay", damage = 1184, label = "Nitrobenzene", max = 2000000000, color = 0x744700 }, -- Brown
  { name = "gregtech:gt.GregTech_FluidDisplay", damage = 87, label = "Blood", max = 32000000, color = 0xFF0000 }, -- Red
}

-- Item Configuration Array
local ITEMS = {
  { name = "IC2:blockITNT", damage = 0, label = "Industrial TNT", max = 10000, color = 0xFFFFFF },
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

  -- Query only the configured fluids to avoid creating a full network snapshot.
  local fluidAmounts = {}
  for i, cfg in ipairs(FLUIDS) do
    local success, fluid = pcall(function()
      if cfg.damage ~= nil then
        return me.getFluidInNetwork({ id = cfg.damage })
      end
      return me.getFluidInNetwork(cfg.target or cfg.name)
    end)
    if success and type(fluid) == "table" then
      fluidAmounts[i] = fluid.amount or 0
    end
  end

  -- Query only the configured items to avoid materializing every stored item.
  local itemAmounts = {}
  for i, cfg in ipairs(ITEMS) do
    local success, item = pcall(function()
      return me.getItemInNetwork(cfg.name, cfg.damage or 0, cfg.nbt or "{}")
    end)
    if success and type(item) == "table" then
      itemAmounts[i] = item.size or item.amount or 0
    end
  end

  -- Dynamic UI layout calculation (4 lines per block including the empty line)
  local linesPerFluid = 4
  local totalUiHeight = 3 + ((#FLUIDS + #ITEMS) * linesPerFluid) + 1
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

  -- Render Item Array
  for i, cfg in ipairs(ITEMS) do
    local currentAmount = itemAmounts[i] or 0
    local ratio = math.min(currentAmount / cfg.max, 1.0)
    local percentage = ratio * 100
    local filledChars = math.floor(ratio * BAR_WIDTH)
    local emptyChars = BAR_WIDTH - filledChars

    local bar = "[" .. string.rep("=", filledChars) .. string.rep(".", emptyChars) .. "]"
    local statusColor = getStatusColor(percentage)

    local pctStr = string.format("%.2f%%", percentage)
    local separatorStr = " : "
    local totalLen = string.len(cfg.label) + string.len(separatorStr) + string.len(pctStr)
    local startX = math.floor((w - totalLen) / 2) + 1

    gpu.fill(1, currentY, w, 1, " ")

    gpu.setForeground(cfg.color or COLOR_WHITE)
    gpu.set(startX, currentY, cfg.label)

    gpu.setForeground(COLOR_WHITE)
    gpu.set(startX + string.len(cfg.label), currentY, separatorStr)

    gpu.setForeground(statusColor)
    gpu.set(startX + string.len(cfg.label) + string.len(separatorStr), currentY, pctStr)

    drawCentered(currentY + 1, bar, statusColor)

    drawCentered(
      currentY + 2,
      string.format("Stored: %s / %s items", formatNumber(currentAmount), formatNumber(cfg.max)),
      statusColor
    )

    gpu.fill(1, currentY + 3, w, 1, " ")

    currentY = currentY + linesPerFluid
  end

  gpu.setForeground(COLOR_WHITE)

  os.sleep(2)
end