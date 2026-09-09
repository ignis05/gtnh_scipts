local component = require("component")
local os = require("os")

local config = {
    resolution = { 2560, 1440 },
    GUIscale = 3,
    height = 12,
    length = 168,
    borderBottom = 2,
    borderTop = 2,
    fontSize = 1,
    expectedMaxChargeRate = 128000,
    colors = {
        border = 0x181828,  -- dark panel
        empty = 0x5A5A68,   -- gray unfilled capacity
        fill = 0x00A6FF,    -- cyan fill / percent
        text = 0x000000,    -- black
        warning = 0xFF0000, -- red
    },
}

-- Keys are Minecraft usernames bound to terminal glasses.
-- Only list fields that differ from `config`.
local playerConfig = {
    ["monolither"] = { resolution = { 2560, 1440 }, GUIscale = 4 },
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

local function flowArrows(avgIn, avgOut, maxRate)
    local chargeSuffix = ""
    if avgIn > 0 then
        chargeSuffix = ">"
        if avgIn > maxRate * 0.8 then
            chargeSuffix = ">>"
        end
    end
    local dischargePrefix = ""
    if avgOut > 0 then
        dischargePrefix = "<"
        if avgOut > maxRate * 0.8 then
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
        maxTextX = barRightX - 2,
        statusY = panelBottomY - 8 * cfg.fontSize - 2,
    }
end

local function setupGlass(glasses, cfg)
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
    ui.textStatus = newText(glasses, "", pos.b2, pos.statusY, cfg.fontSize, colors.warning)
    return ui
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
    local glassesList = {}
    for address in pairs(component.list("glasses")) do
        local glasses = component.proxy(address)
        if glasses then
            local players = { glasses.getBindPlayers() }
            local playerName = players[1]

            if playerName then
                local cfg = mergeConfig(playerName)
                table.insert(glassesList, {
                    address = address,
                    player = playerName,
                    cfg = cfg,
                    device = glasses,
                    ui = setupGlass(glasses, cfg),
                })
            end
        end
    end

    while true do
        local machine = component.gt_machine
        if machine then
            local maxCapacity = tonumber(machine.getEUCapacity()) or 0
            local currentEnergy = tonumber(machine.getEUStored()) or 0
            local avgEnergyInput, avgEnergyOutput, timeToEmpty =
                parseSensorInfo(machine.getSensorInformation())
            local percentage = math.min(currentEnergy / math.max(maxCapacity, 1), 1)

            for _, entry in ipairs(glassesList) do
                local ui = entry.ui
                local cfg = entry.cfg
                local pos = layout(cfg)
                local currTextScale = cfg.fontSize / 1.3
                local maxRate = cfg.expectedMaxChargeRate or 0
                local chargeSuffix, dischargePrefix = flowArrows(avgEnergyInput, avgEnergyOutput, maxRate)

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
                if dischargePrefix == "<<<" then
                    emptyText = "Empty in: " .. timeToEmpty
                end
                updateTextLabel(ui.textStatus, emptyText, pos.b2, pos.statusY, cfg.fontSize, false)
            end
        end

        os.sleep(1)
    end
end

main()
