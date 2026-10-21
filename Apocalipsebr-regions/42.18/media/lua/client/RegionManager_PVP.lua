-- Client-side PvP enforcement. Native NonPvpZone protection remains server-owned.
if isServer() then return end

require "RegionManager_Config"
require "RegionManager_ClientTick"

RegionManager.PVP = RegionManager.PVP or {}
local lastPolicy = setmetatable({}, {__mode="k"})
local toggleLogged = setmetatable({}, {__mode="k"})

local function onTick(player, currentZones)
    if not player then return end
    -- Derive the requirement from all current zones every tick. This releases
    -- enforcement on exit and avoids depending on unordered entry/exit events.
    local inPvpZone, inSafeZone, inOptionalZone = false, false, false
    for _, zone in pairs(currentZones or {}) do
        if zone.pvpEnabled == false then
            -- Explicit safe zones take precedence over overlapping PvP zones.
            inSafeZone = true
        elseif zone.pvpEnabled == true and zone.forcedPvP ~= false then
            inPvpZone = true
        elseif zone.pvpEnabled == true then
            inOptionalZone = true
        end
    end
    local policy = inSafeZone and "safe zone" or (inPvpZone and "forced PvP (nil/true overrides sandbox)"
        or (inOptionalZone and "optional PvP (false)" or "outside PvP regions"))
    if lastPolicy[player] ~= policy then
        RegionManager.Log("PVP", "Policy changed to " .. policy)
        lastPolicy[player] = policy
        toggleLogged[player] = nil
    end
    -- Per-region policy supersedes the legacy global EnforcePVP option.
    -- Optional regions do not cancel an overlapping forced region.
    if inSafeZone or not inPvpZone then return end

    local safety = player:getSafety()
    if safety:isEnabled() and safety:getToggle() == 0 then
        if not toggleLogged[player] then
            RegionManager.Log("PVP", "Requesting safety off; per-region forced policy overrides sandbox settings")
            toggleLogged[player] = true
        end
        safety:setCooldown(0)
        safety:toggleSafety()
    else
        toggleLogged[player] = nil
    end
end

local function initPvpModule()
    RegionManager.ClientTick.registerModule({ name = "PVP", onTick = onTick })
    RegionManager.Log("PVP", "PVP module registered with ClientTick dispatcher")
end

Events.OnGameStart.Add(initPvpModule)
return RegionManager.PVP
