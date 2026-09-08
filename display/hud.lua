local component = require("component")
local os = require("os")

local config = {
    resolution = {2560, 1440},
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

local function newText(glasses, text, x, y, scale, color)
    local label = glasses.addTextLabel()
    label.setText(text)
    label.setPosition(x, y)
    label.setScale(scale or 1)

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

local function setupGlass(glasses)
    glasses.removeAll()

    local l = config.length
    local h = config.height
    local b1 = config.borderBottom
    local b2 = config.borderTop
    local y = config.resolution[2] / config.GUIscale

    local borderColor = 0x181828 -- dark gray
    local panelColor = 0x00A6FF -- light blue
    local accentColor = 0x303850 -- dark blue
    local textColor = 0x000000 -- black
    local warningColor = 0xFF0000 -- red


    -- background panel
    newQuad(glasses, {0, y - b1}, {3.5 * h + l + b2 + 1, y - b1}, {2.5 * h + l + 1, y - b1 - h - b2}, {0, y - b1 - h - b2}, borderColor)
    -- bottom bar
    newQuad(glasses, {0, y}, {3.5 * h + l + b2 + 1, y}, {3.5 * h + l + b2 + 1, y - b1}, {0, y - b1}, borderColor)
    local ui = {}
    ui.energyBar = newQuad(glasses,
        {3.5 * h, y - b1},
        {3.5 * h + l, y - b1},
        {2.5 * h + l, y - b1 - h},
        {2.5 * h, y - b1 - h},
        panelColor)
    ui.textPercent = newText(glasses, "0.0%", b2 + 2.1 * h, y - b1 - h / 1.8 - config.fontSize, config.fontSize, accentColor)
    ui.textCurr = newText(glasses, "", b2 + 3.25 * h + 1, y - b1 - h / 2 - config.fontSize, config.fontSize / 1.3, textColor)
    ui.textMax = newText(glasses, "", 2.25 * h + l - 1.5 * config.fontSize, y - b1 - h / 2 - config.fontSize, config.fontSize / 1.3, textColor)
    ui.textStatus = newText(glasses, "", b2, y - b1 - b2 - h - 3 * config.fontSize, config.fontSize, warningColor)
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
                local y = config.resolution[2] / config.GUIscale

                updateBar(ui.energyBar, y - config.borderBottom, config.height, percentage)

                ui.textPercent.setText(string.format("%.1f%%", percentage * 100))
                ui.textCurr.setText(formatNumber(currentEnergy) .. " EU")
                ui.textMax.setText(formatNumber(maxCapacity) .. " EU")
                -- ui.textStatus.setText(string.format("IN %s EU/t  OUT %s EU/t", formatNumber(avgEnergyInput), formatNumber(avgEnergyOutput)))
            end
        end

        os.sleep(1)
    end
end

main()
