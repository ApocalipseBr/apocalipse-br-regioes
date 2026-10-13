-- Client-side PvP enforcement. Native NonPvpZone protection remains server-owned.
if isServer() then return end

require "RegionManager_Config"
require "RegionManager_ClientTick"

RegionManager.PVP = RegionManager.PVP or {}

local function onTick(player, currentZones)
    if not player then return end
    local options = SandboxVars and SandboxVars.RegionManager
    -- Missing settings retain the existing enforcement default.
    if options and options.EnforcePVP == false then return end

    -- Derive the requirement from all current zones every tick. This releases
    -- enforcement on exit and avoids depending on unordered entry/exit events.
    local inPvpZone = false
    for _, zone in pairs(currentZones or {}) do
        if zone.pvpEnabled == false then
            -- Explicit safe zones take precedence over overlapping PvP zones.
            return
        elseif zone.pvpEnabled == true then
            inPvpZone = true
        end
    end
    if not inPvpZone then return end

    local safety = player:getSafety()
    if safety:isEnabled() and safety:getToggle() == 0 then
        safety:setCooldown(0)
        safety:toggleSafety()
    end
end

local function initPvpModule()
    RegionManager.ClientTick.registerModule({ name = "PVP", onTick = onTick })
    RegionManager.Log("PVP", "PVP module registered with ClientTick dispatcher")
end

Events.OnGameStart.Add(initPvpModule)
return RegionManager.PVP
