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
        statusY = panelBottomY - 3 * cfg.fontSize,
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
            local avgEnergyInput = tonumber(machine.getEUInputAverage()) or 0
            local avgEnergyOutput = tonumber(machine.getEUOutputAverage()) or 0
            local percentage = math.min(currentEnergy / math.max(maxCapacity, 1), 1)

            for _, entry in ipairs(glassesList) do
                local ui = entry.ui
                local cfg = entry.cfg
                local pos = layout(cfg)
                local currTextScale = cfg.fontSize / 1.3

                updateBar(ui.energyBar, pos.y - cfg.borderBottom, cfg.height, percentage, cfg)

                updateTextLabel(ui.textPercent, string.format("%.1f%%", percentage * 100),
                    pos.percentX, pos.percentY, cfg.fontSize, false)

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
