local component = require("component")
local os = require("os")
local term = require("term")

while true do
    term.clear()
    
    -- Added spacing and tostring() for safety
    print("getEUInputAverage: " .. tostring(component.gt_machine.getEUInputAverage()))
    print("getEUOutputAverage: " .. tostring(component.gt_machine.getEUOutputAverage()))
    print("getInputVoltage: " .. tostring(component.gt_machine.getInputVoltage()))
    print("getOutputVoltage: " .. tostring(component.gt_machine.getOutputVoltage()))
    print("getAverageElectricOutput: " .. tostring(component.gt_machine.getAverageElectricOutput()))
    print("getAverageElectricInput: " .. tostring(component.gt_machine.getAverageElectricInput()))
    
    print("\n--- Sensor Information ---")
    
    -- Fetch the sensor info table
    local sensorInfo = component.gt_machine.getSensorInformation()
    
    -- Verify it's a table to prevent script crashes, then iterate and print
    if type(sensorInfo) == "table" then
        for index, line in ipairs(sensorInfo) do
            print(line)
        end
    else
        print("No sensor data available.")
    end
    
    os.sleep(1)
end