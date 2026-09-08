local component = require("component")
local os = require("os")

local gpu = component.gpu
if not gpu then
    error("This script requires a GPU component.")
end

local function main()
    while true do
        local maxCapacity = component.gt_machine.getEUCapacity()
        gpu.set(1, 1, "EU Capacity: " .. maxCapacity)

        local currentEnergy = component.gt_machine.getEUStored()
        gpu.set(1, 2, "Current Energy: " .. currentEnergy)

        local avgEnergyInput = component.gt_machine.getEUInputAverage()
        gpu.set(1, 3, "Average Energy Input: " .. avgEnergyInput)

        local avgEnergyOutput = component.gt_machine.getEUOutputAverage()
        gpu.set(1, 4, "Average Energy Output: " .. avgEnergyOutput)

        local gpuRow = 5
        for address in pairs(component.list("glasses")) do
            local glasses = component.proxy(address)
            local players = { glasses.getBindPlayers() }

            local playername = players[1]

            if #players == 0 then
                
            else
                gpu.set(1, gpuRow, "Glasses " .. playername .. "@ " .. address)
                gpuRow = gpuRow + 1
            end
        end

        os.sleep(1)
    end
end

main()
