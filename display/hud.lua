local component = require("component")
local os = require("os")
local sides = require("sides")

local COLOR_WHITE = 0xFFFFFF
local COLOR_GRAY = 0xAAAAAA
local COLOR_CYAN = 0x00A6FF
local COLOR_GREEN = 0x33FF33
local COLOR_RED = 0xFF3333
local COLOR_ORANGE = 0xFFAA00

-- Redstone side used to enable charging (OC sides: 0 bottom, 1 top, 2 back, 3 front, 4 right, 5 left).
local redstoneSide = sides.left

local config = {
    -- scale / resolution settings
    resolution = { 2560, 1440 }, -- screen resolution
    GUIscale = 3,                -- match the one from minecraft settings

    -- energy flow settings
    expectedMaxChargeRate = 320000, -- should match expected charge rate when all power sources are running at full efficientcy
    fastChargeThreshold = 0.8,      -- will show second chevron when charge speed exceeds this fraction
    fastDischargeThreshold = 0.5,   -- will show second chevron when discharge speed exceeds this fraction
    showEmptyIn = "warning",        -- | "always" | "warning" | "never". Warning shows it only if discharge speed is faster than configured expectedMaxChargeRate.

    -- display customization
    height = 12,                        -- height of the energy bar in pixels
    length = 168,                       -- length of the energy bar in pixels
    borderBottom = 2,                   -- bottom border of the panel in pixels
    borderTop = 2,                      -- top border of the panel in pixels
    fontSize = 1,                       -- font size
    colors = {
        border = 0x181828,              -- dark panel
        empty = 0x5A5A68,               -- gray unfilled capacity
        fill = 0x00A6FF,                -- cyan fill / percent
        text = 0x000000,                -- black
        warning = 0xFF0000,             -- red
        itemCountText = 0xFFFFFF,       -- white text for item counts
        itemCountBackground = 0x000000, -- white background for item counts
    },
    itemCountBackgroundAlpha = 0.42,
}

-- Keys are Minecraft usernames bound to terminal glasses.
-- Only list fields that differ from `config`.
local playerConfig = {
    ["monolither"] = {
        GUIscale = 4,
        length = 150
    },
    ["PrankishWharf"] = {
        resolution = { 3840, 2160 },
        GUIscale = 4,
        length = 150
    },
}

local function copyTable(src)
    local dst = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = copyTable(v)
        else
            dst[k] = v
        end
    end
    return dst
end

local function mergeConfig(playerName)
    local cfg = copyTable(config)
    local overrides = playerName and playerConfig[playerName]
    if overrides then
        for k, v in pairs(overrides) do
            if type(v) == "table" and type(cfg[k]) == "table" then
                for k2, v2 in pairs(v) do
                    cfg[k][k2] = v2
                end
            else
                cfg[k] = v
            end
        end
    end
    return cfg
end

local function RGB(hex)
    local r = ((hex >> 16) & 0xFF) / 255.0
    local g = ((hex >> 8) & 0xFF) / 255.0
    local b = ((hex) & 0xFF) / 255.0
    return r, g, b
end

local function newQuad(glasses, p1, p2, p3, p4, color)
    local quad = glasses.addQuad()
    quad.setVertex(1, p1[1], p1[2])
    quad.setVertex(2, p2[1], p2[2])
    quad.setVertex(3, p3[1], p3[2])
    quad.setVertex(4, p4[1], p4[2])
    quad.setColor(RGB(color))
    quad.setAlpha(0.9)

    return quad
end

local function textOffset(text, scale)
    local chars = string.len(text or "")
    return (chars * 5.5) * (scale or 1)
end

local function newText(glasses, text, x, y, scale, color)
    local label = glasses.addTextLabel()
    local fontScale = scale or 1

    label.setText(text)
    label.setPosition(x, y)
    label.setScale(fontScale)

    if label.setColor then
        local r, g, b = RGB(color)
        label.setColor(r, g, b)
    end

    return label
end

local function formatNumber(value)
    value = tonumber(value) or 0
    if value == 0 then
        return "0"
    end
    return (string.format("%.2e", value):gsub("%+", ""))
end

local function formatCompactNumber(value)
    local number = tonumber(value) or 0
    if number < 1000 then
        return tostring(math.floor(number))
    elseif number < 1000000 then
        return string.format("%.0fk", number / 1000)
    elseif number < 1000000000 then
        return string.format("%.0fM", number / 1000000)
    end
    return string.format("%.1fB", number / 1000000000)
end

local function normalizeNbt(nbt)
    if nbt == nil or nbt == "" then
        return "{}"
    end
    if type(nbt) == "string" then
        return nbt
    end
    if type(nbt) == "table" then
        local ok, serialization = pcall(require, "serialization")
        if ok and serialization and type(serialization.serialize) == "function" then
            return serialization.serialize(nbt)
        end
    end
    return "{}"
end

local function readStackCount(stack)
    if type(stack) ~= "table" then
        return 0
    end

    local me = component.me_interface
    if not me then
        return 0
    end

    local name = stack.name or stack.id or stack.unlocalizedName or stack.displayName or ""
    local damage = tonumber(stack.damage) or tonumber(stack.meta) or 0
    local nbt = normalizeNbt(stack.nbt)

    local queries = {}

    if name ~= "" then
        table.insert(queries, function()
            return me.getItemInNetwork(name, damage, nbt)
        end)
    end

    if damage ~= 0 or name:find("FluidDisplay", 1, true) or name:find("fluid", 1, true) then
        table.insert(queries, function()
            return me.getFluidInNetwork({ id = damage })
        end)
    end

    for _, query in ipairs(queries) do
        local ok, result = pcall(query)
        if ok and result ~= nil then
            if type(result) == "table" then
                if result.amount ~= nil then
                    return tonumber(result.amount) or 0
                end
                if result.size ~= nil then
                    return tonumber(result.size) or 0
                end
                if result.count ~= nil then
                    return tonumber(result.count) or 0
                end
                if result[1] and type(result[1]) == "table" then
                    local amount = result[1].amount or result[1].size or result[1].count
                    if amount ~= nil then
                        return tonumber(amount) or 0
                    end
                end
            elseif type(result) == "number" then
                return result
            end
        end
    end

    return 0
end

local function scanDatabaseEntries()
    local db = component.database
    if not db then
        return {}
    end

    local items = {}
    local index = 1
    while true do
        local stack = db.get(index)
        if not stack then
            break
        end

        table.insert(items, {
            slot = index,
            name = stack.name or stack.id or stack.unlocalizedName or stack.displayName,
            damage = tonumber(stack.damage) or tonumber(stack.meta) or 0,
            nbt = stack.nbt,
            stack = stack,
        })
        index = index + 1
    end
    return items
end

local SENSOR_AVG_IN = "lapotronic_super_capacitor.avg_eu_in.min5"
local SENSOR_AVG_OUT = "lapotronic_super_capacitor.avg_eu_out.min5"
local SENSOR_TIME_EMPTY = "lapotronic_super_capacitor.time_to.empty"

local function sensorField(line, key)
    local start = line:find(key, 1, true)
    if not start then
        return nil
    end
    local rest = line:sub(start + #key):gsub("^\\+", "")
    local field = rest:match("^([^\\]*)") or rest
    field = field:gsub("§.", ""):match("^%s*(.-)%s*$") or ""
    if field == "" then
        return nil
    end
    return field
end

local function parseCommaNumber(str)
    if not str then
        return 0
    end
    return tonumber((str:gsub(",", ""))) or 0
end

local function parseSensorInfo(info)
    local avgIn, avgOut, timeToEmpty = 0, 0, "0"
    if type(info) ~= "table" then
        return avgIn, avgOut, timeToEmpty
    end
    for _, line in ipairs(info) do
        if type(line) == "string" then
            local inField = sensorField(line, SENSOR_AVG_IN)
            if inField then
                avgIn = parseCommaNumber(inField)
            end
            local outField = sensorField(line, SENSOR_AVG_OUT)
            if outField then
                avgOut = parseCommaNumber(outField)
            end
            local emptyField = sensorField(line, SENSOR_TIME_EMPTY)
            if emptyField then
                timeToEmpty = emptyField
            end
        end
    end
    return avgIn, avgOut, timeToEmpty
end

local function flowArrows(avgIn, avgOut, maxRate, cfg)
    local chargeThreshold = (cfg and cfg.fashChargeThreshold) or 0.8
    local dischargeThreshold = (cfg and cfg.fashDischargeThreshold) or 0.5

    local chargeSuffix = ""
    if avgIn > 0 then
        chargeSuffix = ">"
        if avgIn > maxRate * chargeThreshold then
            chargeSuffix = ">>"
        end
    end
    local dischargePrefix = ""
    if avgOut > 0 then
        dischargePrefix = "<"
        if avgOut > maxRate * dischargeThreshold then
            dischargePrefix = "<<"
        end
        if avgOut > maxRate then
            dischargePrefix = "<<<"
        end
    end
    return chargeSuffix, dischargePrefix
end

local function updateTextLabel(label, text, baseX, baseY, scale, alignRight)
    label.setText(text)
    if alignRight then
        label.setPosition(baseX - textOffset(text, scale), baseY)
    else
        label.setPosition(baseX, baseY)
    end
end

local function layout(cfg)
    local l = cfg.length
    local h = cfg.height
    local b1 = cfg.borderBottom
    local b2 = cfg.borderTop
    local y = cfg.resolution[2] / cfg.GUIscale

    local barLeftX = 3.5 * h
    local barRightX = barLeftX + l
    local topLeftX = 2.5 * h
    local topRightX = topLeftX + l
    local panelTopY = y - b1
    local panelBottomY = panelTopY - h - b2
    local textY = panelTopY - h * 0.5

    return {
        l = l,
        h = h,
        b1 = b1,
        b2 = b2,
        y = y,
        barLeftX = barLeftX,
        barRightX = barRightX,
        topLeftX = topLeftX,
        topRightX = topRightX,
        panelTopY = panelTopY,
        panelBottomY = panelBottomY,
        textY = textY,
        percentX = 5,
        percentY = textY - 2,
        currTextX = barLeftX + 2,
        maxTextX = barRightX - 6,
        warningX = cfg.borderTop + 70,
        statusY = panelBottomY - 8 * cfg.fontSize - 2,
    }
end

local function setupGlass(glasses, cfg, databaseItems)
    glasses.removeAll()

    local pos = layout(cfg)
    local colors = cfg.colors

    -- background panel
    newQuad(glasses,
        { 0, pos.panelTopY },
        { pos.barLeftX + pos.l + pos.b2 + 1, pos.panelTopY },
        { pos.topRightX + 1, pos.panelBottomY },
        { 0, pos.panelBottomY },
        colors.border)

    -- bottom bar
    newQuad(glasses,
        { 0, pos.y },
        { pos.barLeftX + pos.l + pos.b2 + 1, pos.y },
        { pos.barLeftX + pos.l + pos.b2 + 1, pos.y - pos.b1 },
        { 0, pos.y - pos.b1 },
        colors.border)

    local ui = {}

    -- gray empty capacity track (full width)
    ui.emptyBar = newQuad(glasses,
        { pos.barLeftX, pos.panelTopY },
        { pos.barRightX, pos.panelTopY },
        { pos.topRightX, pos.panelTopY - pos.h },
        { pos.topLeftX, pos.panelTopY - pos.h },
        colors.empty)

    -- cyan fill, updated each tick
    ui.energyBar = newQuad(glasses,
        { pos.barLeftX, pos.panelTopY },
        { pos.barRightX, pos.panelTopY },
        { pos.topRightX, pos.panelTopY - pos.h },
        { pos.topLeftX, pos.panelTopY - pos.h },
        colors.fill)

    ui.textPercent = newText(glasses, "0.0%", pos.percentX, pos.percentY, cfg.fontSize, colors.fill)
    ui.textCurr = newText(glasses, "", pos.currTextX, pos.textY, cfg.fontSize / 1.3, colors.text)
    ui.textMax = newText(glasses, "", pos.maxTextX, pos.textY, cfg.fontSize / 1.3, colors.text)
    ui.textStatus = newText(glasses, "", pos.warningX, pos.statusY, cfg.fontSize, colors.warning)

    local itemX = 4
    local itemY = pos.panelTopY - 26
    local itemStep = 18
    local itemTopPadding = 9
    ui.inventory = {}
    for i, itemEntry in ipairs(databaseItems or {}) do
        local y = itemY - (i - 1) * itemStep - itemTopPadding
        local iconWidget = glasses.addItem()
        iconWidget.setItem(component.database.address, itemEntry.slot)
        iconWidget.setPosition(itemX, y)

        local labelX = itemX + 18
        local labelY = y + 5
        local labelScale = cfg.fontSize / 1.2
        local background = glasses.addRect()
        background.setPosition(labelX - 2, labelY - 2)
        background.setSize(10, 18)
        background.setColor(RGB(cfg.colors.itemCountBackground))
        background.setAlpha(cfg.itemCountBackgroundAlpha)

        local label = newText(glasses, "0", labelX, labelY, labelScale, cfg.colors.itemCountText)

        table.insert(ui.inventory, {
            icon = iconWidget,
            background = background,
            text = label,
            slot = itemEntry.slot,
            entry = itemEntry,
        })
    end

    return ui
end

local function setChargingMode(enabled)
    local rs = component.redstone
    if not rs then
        return
    end
    rs.setOutput(redstoneSide, enabled and 100 or 0)
end

local function setupStatusGpu()
    if not component.isAvailable("gpu") then
        return nil
    end

    local gpu = component.gpu
    local maxW, maxH = gpu.maxResolution()
    gpu.setResolution(math.min(maxW, 40), math.min(maxH, 12))

    local w, h = gpu.getResolution()
    gpu.setBackground(0x000000)
    gpu.setForeground(COLOR_WHITE)
    gpu.fill(1, 1, w, h, " ")
    return gpu
end

local function drawStatusLine(gpu, y, w, label, value, valueColor)
    gpu.fill(1, y, w, 1, " ")
    gpu.setForeground(COLOR_GRAY)
    gpu.set(1, y, label)

    local valueText = tostring(value)
    gpu.setForeground(valueColor or COLOR_WHITE)
    gpu.set(math.max(1, w - #valueText + 1), y, valueText)
end

local function renderStatusScreen(gpu, readings)
    if not gpu then
        return
    end

    local w = gpu.getResolution()
    gpu.setForeground(COLOR_WHITE)
    gpu.fill(1, 1, w, 1, " ")
    gpu.set(1, 1, string.rep("=", w))

    local title = "ENERGY HUD"
    gpu.set(math.floor((w - #title) / 2) + 1, 2, title)

    gpu.fill(1, 3, w, 1, " ")
    gpu.set(1, 3, string.rep("=", w))

    local chargingOn = readings.charging
    local chargingColor = chargingOn and COLOR_GREEN or COLOR_RED
    local percentColor = readings.percentage < 0.5 and COLOR_RED
        or (readings.percentage < 0.8 and COLOR_ORANGE or COLOR_CYAN)

    drawStatusLine(gpu, 4, w, "Charge",
        string.format("%.1f%%", readings.percentage * 100), percentColor)
    drawStatusLine(gpu, 5, w, "Stored",
        formatNumber(readings.currentEnergy) .. " EU", COLOR_CYAN)
    drawStatusLine(gpu, 6, w, "Capacity",
        formatNumber(readings.maxCapacity) .. " EU", COLOR_WHITE)
    drawStatusLine(gpu, 7, w, "In",
        formatNumber(readings.avgEnergyInput) .. " EU/t", COLOR_GREEN)
    drawStatusLine(gpu, 8, w, "Out",
        formatNumber(readings.avgEnergyOutput) .. " EU/t", COLOR_ORANGE)
    drawStatusLine(gpu, 9, w, "Max rate",
        formatNumber(readings.maxRate) .. " EU/t", COLOR_WHITE)
    drawStatusLine(gpu, 10, w, "Empty in",
        tostring(readings.timeToEmpty), COLOR_WHITE)
    drawStatusLine(gpu, 11, w, "Charging",
        chargingOn and "ON" or "OFF", chargingColor)

    gpu.setForeground(COLOR_WHITE)
end

local function shouldStartCharging(percentage, avgEnergyOutput, maxRate)
    if percentage < 0.5 then
        return true
    end
    return avgEnergyOutput > maxRate and percentage < 0.8
end

local function shouldStopCharging(percentage)
    return percentage > 0.95
end

local function updateBar(quad, yBase, height, percent, cfg)
    local leftBottomX = 3.5 * cfg.height
    local leftTopX = 2.5 * cfg.height
    local rightBottomX = leftBottomX + cfg.length * percent
    local rightTopX = leftTopX + cfg.length * percent

    quad.setVertex(1, leftBottomX, yBase)
    quad.setVertex(2, rightBottomX, yBase)
    quad.setVertex(3, rightTopX, yBase - height)
    quad.setVertex(4, leftTopX, yBase - height)
end

local function main()
    local databaseItems = scanDatabaseEntries()
    local glassesList = {}
    for address in pairs(component.list("glasses")) do
        local glasses = component.proxy(address)
        if glasses then
            local players = { glasses.getBindPlayers() }
            local playerName = players[1]

            if playerName then
                local cfg = mergeConfig(playerName)
                local entry = {
                    address = address,
                    player = playerName,
                    cfg = cfg,
                    device = glasses,
                }
                entry.ui = setupGlass(glasses, cfg, databaseItems)
                table.insert(glassesList, entry)
            end
        end
    end

    local charging = false
    setChargingMode(false)
    local statusGpu = setupStatusGpu()

    while true do
        local machine = component.gt_machine
        if machine then
            local maxCapacity = tonumber(machine.getEUCapacity()) or 0
            local currentEnergy = tonumber(machine.getEUStored()) or 0
            local avgEnergyInput, avgEnergyOutput, timeToEmpty =
                parseSensorInfo(machine.getSensorInformation())
            local percentage = math.min(currentEnergy / math.max(maxCapacity, 1), 1)
            local maxRate = config.expectedMaxChargeRate or 0

            if charging then
                if shouldStopCharging(percentage) then
                    charging = false
                    setChargingMode(false)
                end
            elseif shouldStartCharging(percentage, avgEnergyOutput, maxRate) then
                charging = true
                setChargingMode(true)
            end

            renderStatusScreen(statusGpu, {
                maxCapacity = maxCapacity,
                currentEnergy = currentEnergy,
                avgEnergyInput = avgEnergyInput,
                avgEnergyOutput = avgEnergyOutput,
                timeToEmpty = timeToEmpty,
                percentage = percentage,
                maxRate = maxRate,
                charging = charging,
            })

            for _, entry in ipairs(glassesList) do
                local cfg = entry.cfg
                local pos = layout(cfg)
                local ui = entry.ui

                local currTextScale = cfg.fontSize / 1.3
                local maxRate = cfg.expectedMaxChargeRate or 0
                local chargeSuffix, dischargePrefix = flowArrows(avgEnergyInput, avgEnergyOutput, maxRate, cfg)

                local currText = formatNumber(currentEnergy) .. " EU"
                if dischargePrefix ~= "" then
                    currText = dischargePrefix .. " " .. currText
                end
                if chargeSuffix ~= "" then
                    currText = currText .. " " .. chargeSuffix
                end

                updateBar(ui.energyBar, pos.y - cfg.borderBottom, cfg.height, percentage, cfg)

                updateTextLabel(ui.textPercent, string.format("%.1f%%", percentage * 100),
                    pos.percentX, pos.percentY, cfg.fontSize, false)

                updateTextLabel(ui.textCurr, currText,
                    pos.currTextX, pos.textY, currTextScale, false)

                updateTextLabel(ui.textMax, formatNumber(maxCapacity) .. " EU",
                    pos.maxTextX, pos.textY, currTextScale, true)

                local emptyText = ""
                local emptyTextColor = cfg.colors.text
                local showEmptyInMode = tostring(cfg.showEmptyIn or "warning"):lower()

                if showEmptyInMode == "always" then
                    emptyText = "Empty in: " .. timeToEmpty
                    if dischargePrefix == "<<<" then
                        emptyTextColor = cfg.colors.warning
                    end
                elseif showEmptyInMode == "warning" then
                    if dischargePrefix == "<<<" then
                        emptyText = "Empty in: " .. timeToEmpty
                        emptyTextColor = cfg.colors.warning
                    end
                end

                updateTextLabel(ui.textStatus, emptyText, pos.warningX, pos.statusY, cfg.fontSize, false)
                if ui.textStatus.setColor then
                    local r, g, b = RGB(emptyTextColor)
                    ui.textStatus.setColor(r, g, b)
                end

                for _, item in ipairs(ui.inventory or {}) do
                    local count = readStackCount(item.entry)
                    local countText = formatCompactNumber(count)
                    local textScale = cfg.fontSize / 1.2
                    local textX, textY = item.text.getPosition()
                    local boxWidth = math.max(18, textOffset(countText, textScale) + 8)

                    if item.background then
                        item.background.setPosition(textX - 2, textY - 2)
                        item.background.setSize(math.max(10, textScale * 8), boxWidth)
                        item.background.setColor(RGB(cfg.colors.itemCountBackground))
                        item.background.setAlpha(cfg.itemCountBackgroundAlpha)
                    end

                    updateTextLabel(item.text, countText, textX, textY, textScale, false)
                    if item.text.setColor then
                        local r, g, b = RGB(cfg.colors.itemCountText)
                        item.text.setColor(r, g, b)
                    end
                end
            end
        end

        os.sleep(5)
    end
end

main()
