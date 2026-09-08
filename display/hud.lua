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
}

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
    value = math.floor(value)
    if value >= 1000000 then
        return string.format("%.1fM", value / 1000000)
    elseif value >= 1000 then
        return string.format("%.1fK", value / 1000)
    end
    return tostring(value)
end

local function updateTextLabel(label, text, baseX, baseY, scale, alignRight)
    label.setText(text)
    if alignRight then
        label.setPosition(baseX - textOffset(text, scale), baseY)
    else
        label.setPosition(baseX, baseY)
    end
end

local function layout()
    local l = config.length
    local h = config.height
    local b1 = config.borderBottom
    local b2 = config.borderTop
    local y = config.resolution[2] / config.GUIscale

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
        percentRightX = barLeftX - 2,
        currTextX = barLeftX + 2,
        maxTextX = barRightX - 2,
        statusY = panelBottomY - 3 * config.fontSize,
    }
end

local function setupGlass(glasses)
    glasses.removeAll()

    local pos = layout()

    local borderColor = 0x181828  -- dark panel
    local emptyColor = 0x5A5A68   -- gray unfilled capacity
    local fillColor = 0x00A6FF    -- cyan fill / percent
    local textColor = 0x000000    -- black
    local warningColor = 0xFF0000 -- red

    -- background panel
    newQuad(glasses,
        { 0, pos.panelTopY },
        { pos.barLeftX + pos.l + pos.b2 + 1, pos.panelTopY },
        { pos.topRightX + 1, pos.panelBottomY },
        { 0, pos.panelBottomY },
        borderColor)

    -- bottom bar
    newQuad(glasses,
        { 0, pos.y },
        { pos.barLeftX + pos.l + pos.b2 + 1, pos.y },
        { pos.barLeftX + pos.l + pos.b2 + 1, pos.y - pos.b1 },
        { 0, pos.y - pos.b1 },
        borderColor)

    local ui = {}

    -- gray empty capacity track (full width)
    ui.emptyBar = newQuad(glasses,
        { pos.barLeftX, pos.panelTopY },
        { pos.barRightX, pos.panelTopY },
        { pos.topRightX, pos.panelTopY - pos.h },
        { pos.topLeftX, pos.panelTopY - pos.h },
        emptyColor)

    -- cyan fill, updated each tick
    ui.energyBar = newQuad(glasses,
        { pos.barLeftX, pos.panelTopY },
        { pos.barRightX, pos.panelTopY },
        { pos.topRightX, pos.panelTopY - pos.h },
        { pos.topLeftX, pos.panelTopY - pos.h },
        fillColor)

    ui.textPercent = newText(glasses, "0.0%", pos.percentRightX, pos.textY, config.fontSize, fillColor)
    ui.textCurr = newText(glasses, "", pos.currTextX, pos.textY, config.fontSize / 1.3, textColor)
    ui.textMax = newText(glasses, "", pos.maxTextX, pos.textY, config.fontSize / 1.3, textColor)
    ui.textStatus = newText(glasses, "", pos.b2, pos.statusY, config.fontSize, warningColor)
    return ui
end

local function updateBar(quad, yBase, height, percent)
    local leftBottomX = 3.5 * config.height
    local leftTopX = 2.5 * config.height
    local rightBottomX = leftBottomX + config.length * percent
    local rightTopX = leftTopX + config.length * percent

    quad.setVertex(1, leftBottomX, yBase)
    quad.setVertex(2, rightBottomX, yBase)
    quad.setVertex(3, rightTopX, yBase - height)
    quad.setVertex(4, leftTopX, yBase - height)
end

local function main()
    local glassesList = {}
    for address in component.list("glasses") do
        local glasses = component.proxy(address)
        if glasses then
            table.insert(glassesList, {
                address = address,
                device = glasses,
                ui = setupGlass(glasses),
            })
        end
    end

    while true do
        local machine = component.gt_machine
        if machine then
            local maxCapacity = tonumber(machine.getEUCapacity()) or 0
            local currentEnergy = tonumber(machine.getEUStored()) or 0
            local avgEnergyInput = tonumber(machine.getEUInputAverage()) or 0
            local avgEnergyOutput = tonumber(machine.getEUOutputAverage()) or 0
            local percentage = math.min(currentEnergy / math.max(maxCapacity, 1), 1)

            for _, entry in ipairs(glassesList) do
                local ui = entry.ui
                local pos = layout()
                local currTextScale = config.fontSize / 1.3

                updateBar(ui.energyBar, pos.y - config.borderBottom, config.height, percentage)

                -- Percentage sits in the left panel, flush against the bar
                updateTextLabel(ui.textPercent, string.format("%.1f%%", percentage * 100),
                    pos.percentRightX, pos.textY, config.fontSize, true)

                updateTextLabel(ui.textCurr, formatNumber(currentEnergy) .. " EU",
                    pos.currTextX, pos.textY, currTextScale, false)

                updateTextLabel(ui.textMax, formatNumber(maxCapacity) .. " EU",
                    pos.maxTextX, pos.textY, currTextScale, true)
                -- ui.textStatus.setText(string.format("IN %s EU/t  OUT %s EU/t", formatNumber(avgEnergyInput), formatNumber(avgEnergyOutput)))
            end
        end

        os.sleep(1)
    end
end

main()
