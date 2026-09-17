-- relies on geolyzer to detect the sky

local component = require("component")
local os = require("os")
local sides = require("sides")

local redstoneSide = sides.right


local redstone = component.redstone
local geolyzer = component.geolyzer

while true do
    if geolyzer.canSeeSky() then
        redstone.setOutput(redstoneSide, 100)
    else
        redstone.setOutput(redstoneSide, 0)
    end

    os.sleep(3)
end