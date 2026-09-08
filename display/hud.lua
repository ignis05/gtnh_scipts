local component = require("component")
local os = require("os")

local gpu = component.gpu
if not gpu then
  error("This script requires a GPU component.")
end

-- Default HUD config. It can be partially overridden per player below.
local DEFAULT_CONFIG = {
  refresh = 1,
  barWidth = 34,
  title = "LSC",
  showCurrent = true,
  showPercent = true,
  showMax = true,
  showRate = true,
  rateWindow = 10,
  colors = {
    background = 0x000000,
    border = 0x3F3F3F,
    text = 0xFFFFFF,
    low = 0xFF3333,
    mid = 0xFFAA00,
    high = 0x44CC66,
    accent = 0x7FC8FF,
    warm = 0xFFDD66,
  },
  thresholds = {
    low = 0.10,
    mid = 0.45,
  },
  storage = {
    warnBelow = 0.10,
    preferredDisplay = "short", -- short|full
  },
}

-- Partial overrides keyed by player name.
-- Example:
--   ["SomePlayer"] = {
--     title = "My Battery",
--     colors = { high = 0x00FF00 },
--     thresholds = { low = 0.20 },
--   }
local PLAYER_OVERRIDES = {
  ["ExamplePlayer"] = {
    title = "Arena Bank",
    colors = {
      high = 0x66FF66,
      accent = 0x66CCFF,
    },
  },
}

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end

  local result = {}
  for k, v in pairs(value) do
    result[k] = deepCopy(v)
  end
  return result
end

local function mergeConfig(base, override)
  if type(override) ~= "table" then
    return deepCopy(base)
  end

  local result = deepCopy(base)
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = mergeConfig(result[k], v)
    else
      result[k] = deepCopy(v)
    end
  end
  return result
end

local function resolveConfig(playerName)
  local override = PLAYER_OVERRIDES[playerName]
  if override == nil then
    override = PLAYER_OVERRIDES[string.lower(playerName)]
  end
  if override == nil then
    override = PLAYER_OVERRIDES[playerName:lower()]
  end
  return mergeConfig(DEFAULT_CONFIG, override or {})
end

local function safeCall(fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then
    return result
  end
  return nil
end

local function asNumber(value, fallback)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    local parsed = tonumber(value)
    if parsed ~= nil then
      return parsed
    end
  end
  return fallback or 0
end

local function clamp(value, min, max)
  if value < min then return min end
  if value > max then return max end
  return value
end

local function shortNumber(value)
  local abs = math.abs(value)
  if abs >= 1000000000000 then
    return string.format("%.2fT", value / 1000000000000)
  elseif abs >= 1000000000 then
    return string.format("%.2fG", value / 1000000000)
  elseif abs >= 1000000 then
    return string.format("%.2fM", value / 1000000)
  elseif abs >= 1000 then
    return string.format("%.2fK", value / 1000)
  end
  return string.format("%.0f", value)
end

local function getColorForRatio(config, ratio)
  if ratio <= config.thresholds.low then
    return config.colors.low
  elseif ratio <= config.thresholds.mid then
    return config.colors.mid
  end
  return config.colors.high
end

local function drawCenteredText(x, y, text, color, fillWidth)
  if fillWidth ~= nil then
    gpu.fill(x, y, fillWidth, 1, " ")
  end
  gpu.setForeground(color or 0xFFFFFF)
  local textLen = string.len(text)
  if fillWidth ~= nil and fillWidth > textLen then
    local leftPad = math.floor((fillWidth - textLen) / 2)
    gpu.set(x + leftPad, y, text)
    return
  end
  gpu.set(x, y, text)
end

local function addMachineCandidate(candidates, device)
  if device == nil then
    return
  end

  local address = device.address or tostring(device)
  if candidates[address] then
    return
  end

  candidates[address] = device
end

local function getGTMachineCandidates()
  local candidates = {}

  local direct = component.gt_machine
  if type(direct) == "table" then
    if direct.address ~= nil then
      addMachineCandidate(candidates, direct)
    else
      for _, value in pairs(direct) do
        if type(value) == "table" and value.address ~= nil then
          addMachineCandidate(candidates, value)
        end
      end
    end
  end

  local ok, listResult = pcall(function()
    for address in component.list("gt_machine") do
      local proxy = component.proxy(address)
      if proxy ~= nil then
        addMachineCandidate(candidates, proxy)
      end
    end
  end)

  if not ok then
    return {}
  end

  local result = {}
  for _, device in pairs(candidates) do
    table.insert(result, device)
  end
  return result
end

local function readValueFromDevice(device, names)
  for _, name in ipairs(names) do
    if device[name] ~= nil and type(device[name]) == "function" then
      local ok, value = pcall(device[name])
      if ok and value ~= nil then
        return value
      end
    end
  end
  return nil
end

local function collectLSCs()
  local final = {}
  local seen = {}

  local function addDevice(device)
    if device == nil then
      return
    end

    local address = device.address or tostring(device)
    if seen[address] then
      return
    end

    seen[address] = true

    local stored = readValueFromDevice(device, {
      "getEUStored",
      "getStoredEU",
      "getEnergyStored",
      "getEU",
      "getCharge",
      "getPowerStored",
    })
    local max = readValueFromDevice(device, {
      "getEUCapacity",
      "getMaxEUStore",
      "getCapacity",
      "getMaxEU",
      "getMaxEnergyStored",
      "getMaxCharge",
      "getMaxPowerStored",
    })

    if stored ~= nil and max ~= nil then
      table.insert(final, {
        address = address,
        label = device.label or device.name or "LSC",
        stored = asNumber(stored, 0),
        max = math.max(asNumber(max, 1), 1),
      })
    end
  end

  for _, device in ipairs(getGTMachineCandidates()) do
    addDevice(device)
  end

  table.sort(final, function(a, b)
    return a.stored > b.stored
  end)
  return final
end

local function getBoundPlayerName(glasses)
  if glasses == nil then
    return "Unknown"
  end

  local playerName = safeCall(function()
    return glasses.getPlayer()
  end)
  if type(playerName) == "string" and playerName ~= "" then
    return playerName
  end

  playerName = safeCall(function()
    return glasses.getPlayerName()
  end)
  if type(playerName) == "string" and playerName ~= "" then
    return playerName
  end

  local players = safeCall(function()
    return glasses.getPlayers()
  end)
  if type(players) == "table" then
    for _, entry in ipairs(players) do
      if type(entry) == "string" and entry ~= "" then
        return entry
      end
    end
  end

  return "Unknown"
end

local function listGlassesTerminals()
  local terminals = {}
  local ok, listResult = pcall(function()
    local result = {}
    for address in component.list("glasses") do
      local proxy = component.proxy(address)
      if proxy then
        table.insert(result, proxy)
      end
    end
    return result
  end)

  if ok and type(listResult) == "table" then
    for _, proxy in ipairs(listResult) do
      table.insert(terminals, proxy)
    end
  end

  return terminals
end

local function drawHudForTerminal(glasses, config, storage)
  local oldScreen = nil
  if type(gpu.getScreen) == "function" then
    oldScreen = safeCall(function()
      return gpu.getScreen()
    end)
  end

  local ok = pcall(function()
    if glasses and glasses.address and type(gpu.bind) == "function" then
      gpu.bind(glasses.address)
    end
  end)

  if not ok then
    -- Keep going even if the glasses terminal cannot be bound directly.
  end

  local w, h = gpu.getResolution()
  local frameWidth = math.max(40, math.min(w - 2, config.barWidth + 12))
  local left = math.max(1, math.floor((w - frameWidth) / 2) + 1)
  local top = math.max(1, math.floor((h - 9) / 2) + 1)

  local barLength = frameWidth - 6
  local percent = clamp(storage.stored / math.max(storage.max, 1), 0, 1)
  local fill = math.floor(percent * barLength)
  local empty = barLength - fill
  local barColor = getColorForRatio(config, percent)

  gpu.fill(1, 1, w, h, " ")
  gpu.setForeground(config.colors.border)
  gpu.fill(left - 1, top - 1, frameWidth + 2, 8, " ")
  gpu.setForeground(config.colors.border)
  gpu.set(left - 1, top - 1, string.rep("-", frameWidth + 2))
  gpu.set(left - 1, top + 7, string.rep("-", frameWidth + 2))

  for y = top - 1, top + 6 do
    gpu.set(left - 1, y, "|")
    gpu.set(left + frameWidth, y, "|")
  end

  gpu.setForeground(config.colors.accent)
  local title = (config.title or "LSC"):upper()
  drawCenteredText(left, top, title, config.colors.accent, frameWidth)

  gpu.setForeground(config.colors.text)
  local currentText = string.format("%s / %s", shortNumber(storage.stored), shortNumber(storage.max))
  local percentText = string.format("%.0f%%", percent * 100)
  local lineText = currentText .. "  " .. percentText
  drawCenteredText(left, top + 1, lineText, config.colors.text, frameWidth)

  gpu.setForeground(config.colors.border)
  gpu.set(left, top + 3, "[")
  gpu.set(left + barLength + 1, top + 3, "]")
  local barX = left + 1
  if fill > 0 then
    gpu.setForeground(barColor)
    gpu.fill(barX, top + 3, fill, 1, "=")
  end
  if empty > 0 then
    gpu.setForeground(config.colors.background)
    gpu.fill(barX + fill, top + 3, empty, 1, "=")
  end

  gpu.setForeground(config.colors.text)
  local playerText = "Player: " .. (storage.playerName or "Unknown")
  drawCenteredText(left, top + 5, playerText, config.colors.text, frameWidth)

  if oldScreen ~= nil and type(gpu.bind) == "function" then
    pcall(gpu.bind, oldScreen)
  end
end

local function getPrimaryLSC()
  local candidates = collectLSCs()
  if #candidates == 0 then
    return {
      stored = 0,
      max = 1,
      label = "No LSC",
      playerName = "Unknown",
    }
  end

  local chosen = candidates[1]
  return chosen
end

local function main()
  while true do
    local terminals = listGlassesTerminals()

    if #terminals == 0 then
      gpu.fill(1, 1, gpu.getResolution(), 1, " ")
      gpu.set(1, 1, "No glasses terminal bound")
      os.sleep(1)
    else
      local storage = getPrimaryLSC()
      for _, glasses in ipairs(terminals) do
        local playerName = getBoundPlayerName(glasses)
        local config = resolveConfig(playerName)
        storage.playerName = playerName
        drawHudForTerminal(glasses, config, storage)
      end
      os.sleep(1)
    end
  end
end

main()
