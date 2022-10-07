----------------------------------------------------------------------------------
-- Wi-Fi P1 Water meter
-- Version 1.0 (October 2022)
-- Copyright (c)2022 Joep Verhaeg <info@joepverhaeg.nl>

-- More information about my Quick Apps you can find at:
-- https://docs.joepverhaeg.nl
----------------------------------------------------------------------------------
-- DESCRIPTION:
-- This Quick App reads the HomeWizard Wi-Fi Water meter local API. It shows the 
-- water meter readings and calculates a daily water use value.

-- QUICK SETUP:
-- 1. Enable the LOCAL API in the HomeWizard Energy App under Settings -> Meters
-- 2. Set the IPv4 QUICK APP VARIABLE to the IP address of the Wi-Fi Water meter
--    you want to read.
----------------------------------------------------------------------------------

class 'DayWater'(QuickAppChild)
function DayWater:__init(device)
    -- You should not insert code before QuickAppChild.__init.
    QuickAppChild.__init(self, device) 
end

function DayWater:updateValue(data)
    self:updateProperty("value", data.day_liter_m3) -- write in m3!
    self:updateProperty("unit", "m3")
    self:updateProperty("log", data.update_timestamp)
end

class 'TotalWater'(QuickAppChild)
function TotalWater:__init(device)
    -- You should not insert code before QuickAppChild.__init.
    QuickAppChild.__init(self, device) 
end

function TotalWater:updateValue(data)
    self:updateProperty("value", data.total_liter_m3) -- write in m3!
    self:updateProperty("unit", "m3")
    self:updateProperty("log", data.update_timestamp)
end

class 'ActiveWater'(QuickAppChild)
function ActiveWater:__init(device)
    -- You should not insert code before QuickAppChild.__init.
    QuickAppChild.__init(self, device) 
end

function ActiveWater:updateValue(data)
    self:updateProperty("value", data.active_liter_lpm) -- write in lpm!
    self:updateProperty("unit", "lpm")
    self:updateProperty("log", data.update_timestamp)
end

local function getChildVariable(child, varName)
    for _,v in ipairs(child.properties.quickAppVariables or {}) do
        if (v.name == varName) then 
            return v.value
        end
    end
    return ""
end

function QuickApp:getDeviceInfo()
    self.http:request('http://' .. self.ipaddr .. '/api', {
            options = {
                headers = { Accept = "application/json" },
                method = 'GET'
            },
            success = function(response)
                --self:debug(response.status)
                --self:debug(response.data)
                local deviceinfo = json.decode(response.data)
                self:updateView("productLabel", "text", deviceinfo['product_type'])
                self:updateView("modelLabel", "text", deviceinfo['product_name'])
                self:updateView("serialLabel", "text", "ID: " .. deviceinfo['serial'])
                self:updateView("firmwareLabel", "text", "Software: " .. deviceinfo['firmware_version'])
            end
            ,
            error = function(message)
                self:debug("error:", message)
            end         
        })
end

function QuickApp:updateMeterData()
    self.http:request('http://' .. self.ipaddr .. '/api/v1/data', {
            options = {
                headers = { Accept = "application/json" },
                method = 'GET'
            },
            success = function(response)
                --self:debug(response.status)
                --self:debug(response.data)
                local meterdata = json.decode(response.data,{others = {null=false}})
                local logtime   = os.date('%d-%m %H:%M:%S')
 
                -- Write meter values to the QA variables at midnight to reset day values to zero.
                if os.date("%H:%M") == "00:00" then
                    self:setVariable("daystart_liter_m3", meterdata['total_liter_m3'])
                    self:debug("It's midnight, reset day values to zero.")
                end

                -- Update information in main device.
                self:updateView("wifiLabel", "text", "Wi-Fi: " .. meterdata['wifi_ssid'] .. " (" .. meterdata['wifi_strength'] .. " %)")
                -- Update the child devices.
                local day_liter_m3 = tonumber(self:getVariable("daystart_liter_m3"))
                devicedata.day_liter_m3 = tonumber(meterdata['total_liter_m3']) - day_liter_m3
                devicedata.total_liter_m3 = tonumber(meterdata['total_liter_m3'])
                devicedata.active_liter_lpm = tonumber(meterdata['active_liter_lpm'])
                devicedata.update_timestamp = logtime

                for id,child in pairs(self.childDevices) do 
                    child:updateValue(devicedata) 
                end
            end
            ,
            error = function(message)
                self:debug("Error:", message)
            end         
    })

    local timeout = 60000 - (os.date("%S") * 1000)
    fibaro.setTimeout(timeout, function() -- wait 1 minute
            self:updateMeterData()
        end)

end

function QuickApp:onInit()
    self:debug("QuickApp: Wi-Fi Water meter initialisation")
    self.childsInitialized = true
    
    self.ipaddr = self:getVariable("IPv4")
    self.http   = net.HTTPClient({ timeout = 5000 })
    
    if not api.get("/devices/" .. self.id).enabled then
        self:warning("The Wi-Fi Water meter devices is disabled!")
        return
    end
    
    if (self.ipaddr == "none") then
        self:warning("Please set the IPv4 Quick App variable to the IP address of the Wi-Fi Water meter!")
        return
    end

    self.http:request('http://' .. self.ipaddr .. '/api/v1/data', {
            options = {
                headers = { Accept = "application/json" },
                method = 'GET'
            },
            success = function(response)
                --self:debug(response.status)
                --self:debug(response.data)
                local meterdata = json.decode(response.data,{others = {null=false}})
                
                local cdevs = api.get("/devices?parentId="..self.id) or {}
                if #cdevs == 0 then
                    -- Child devices are not created yet, create them...
                    initChildData = {
                        {name="Verbruik vandaag", className="DayWater", type="com.fibaro.multilevelSensor"},
                        {name="Verbruik totaal", className="TotalWater", type="com.fibaro.multilevelSensor"},
                        {name="Actief liter p/m", className="ActiveWater", type="com.fibaro.multilevelSensor"}
                    }

                    for _,c in ipairs(initChildData) do
                        local child = self:createChildDevice(
                            {
                                name = c.name,
                                type=c.type,
                                initialProperties = {},
                                initialInterfaces = {},
                            },
                            _G[c.className] -- Fetch class constructor from class name
                        )
                        child:setVariable("className", c.className)  -- Save class name so we know when we load it next time.
                        child:updateProperty("manufacturer", "HomeWizard")
                        child:updateProperty("deviceRole", "WaterMeter")
                        child.parent = self
                        self:debug("Child device " .. child.name .. " created with id: ", child.id)
                    end

                    -- When the child devices are created, create the QA variables to calculate the day values.
                    self:setVariable("daystart_liter_m3", meterdata['total_liter_m3'])
                else
                    -- Ok, we already have children, instantiate them with the correct class
                    -- This is more or less what self:initChildDevices does but this can handle 
                    -- mapping different classes to the same type...
                    for _,child in ipairs(cdevs) do
                        local className = getChildVariable(child,"className") -- Fetch child class name
                        local childObject = _G[className](child) -- Create child object from the constructor name
                        self.childDevices[child.id]=childObject
                        childObject.parent = self -- Setup parent link to device controller
                    end
                end

                -- Create a devicedata array
                devicedata = {}
                devicedata.day_liter_m3 = tonumber(self:getVariable("daystart_liter_m3"))
                devicedata.total_liter_m3 = tonumber(meterdata['total_liter_m3'])
                devicedata.active_liter_lpm = tonumber(meterdata['active_liter_lpm'])
                devicedata.update_timestamp = ""

                self:getDeviceInfo()
                self:updateMeterData()
            end
            ,
            error = function(message)
                self:debug("Error:", message)
            end 
        })
end