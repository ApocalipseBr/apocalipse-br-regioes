-- ============================================================================
-- File: media/lua/client/RegionManager_ClientTick.lua
-- Central client-side tick dispatcher for region-based state management.
-- Handles zone enter/exit detection and notifies registered modules.
-- ============================================================================

if isServer() then return end

require "RegionManager_Config"

RegionManager.ClientTick = RegionManager.ClientTick or {}

local TickCounter = 0
local TickInterval = 80 -- 2 seconds at 60 FPS

-- Exponential backoff for RequestAllBoundaries while zone data is still
-- missing. Without this, every ClientTick interval (and every pending-zombie
-- tick) would fire another sendClientCommand, flooding the server when the
-- world is slow to respond.
local _boundariesLastSentMs = 0
local _boundariesBackoffMs = 1000  -- start at 1s, doubles up to 60s
local _BOUNDARIES_MIN_MS = 1000
local _BOUNDARIES_MAX_MS = 60000

local function requestBoundariesThrottled()
    local nowMs = (getTimestampMs and getTimestampMs()) or (getTimeInMillis and getTimeInMillis()) or 0
    if nowMs > 0 and (nowMs - _boundariesLastSentMs) < _boundariesBackoffMs then
        return false
    end
    _boundariesLastSentMs = nowMs
    _boundariesBackoffMs = math.min(_boundariesBackoffMs * 2, _BOUNDARIES_MAX_MS)
    sendClientCommand("RegionManager", "RequestAllBoundaries", {})
    return true
end

-- Expose so other client files can share the same throttle state if needed.
RegionManager.ClientTick.requestBoundariesThrottled = requestBoundariesThrottled

-- Reset backoff as soon as we receive the response, so the next outage
-- (e.g. reconnect) starts fast again.
local function _onBoundariesReceived()
    _boundariesBackoffMs = _BOUNDARIES_MIN_MS
end
Events.OnServerCommand.Add(function(module, command, args)
    if module == "RegionManager" and command == "AllZoneBoundaries" then
        _onBoundariesReceived()
    end
end)

---@type table<string, ClientZoneData>
local PreviousZones = {} -- Track zones the player was in last check

---@type TickModuleDef[]
local RegisteredModules = {} -- Modules that want zone enter/exit callbacks

local function log(msg)
    RegionManager.Log("ClientTick", msg)
end

-- ============================================================================
-- Module registration API
-- Modules can register callbacks for zone events and periodic ticks.
--
-- RegionManager.ClientTick.registerModule({
--     name = "MyModule",
--     onZoneEntered = function(player, zoneId, zoneData) end,  -- optional
--     onZoneExited  = function(player, zoneId, zoneData) end,  -- optional
--     onTick        = function(player, currentZones) end,      -- optional (called every tick interval)
-- })
-- ============================================================================
---@param moduleDef TickModuleDef
function RegionManager.ClientTick.registerModule(moduleDef)
    if not moduleDef or not moduleDef.name then
        log("ERROR: registerModule requires a 'name' field")
        return
    end
    table.insert(RegisteredModules, moduleDef)
    log("Registered module: " .. moduleDef.name)
end

-- Notify all registered modules of a zone entry
---@param player IsoPlayer
---@param zoneId string
---@param zoneData ClientZoneData
local function notifyZoneEntered(player, zoneId, zoneData)
    for _, mod in ipairs(RegisteredModules) do
        if mod.onZoneEntered then
            local ok, err = pcall(mod.onZoneEntered, player, zoneId, zoneData)
            if not ok then
                log("ERROR in module '" .. mod.name .. "' onZoneEntered: " .. tostring(err))
            end
        end
    end
end

-- Notify all registered modules of a zone exit
---@param player IsoPlayer
---@param zoneId string
---@param zoneData ClientZoneData
local function notifyZoneExited(player, zoneId, zoneData)
    for _, mod in ipairs(RegisteredModules) do
        if mod.onZoneExited then
            local ok, err = pcall(mod.onZoneExited, player, zoneId, zoneData)
            if not ok then
                log("ERROR in module '" .. mod.name .. "' onZoneExited: " .. tostring(err))
            end
        end
    end
end

-- Notify all registered modules on each tick interval
---@param player IsoPlayer
---@param currentZones table<string, ClientZoneData>
local function notifyTick(player, currentZones)
    for _, mod in ipairs(RegisteredModules) do
        if mod.onTick then
            local ok, err = pcall(mod.onTick, player, currentZones)
            if not ok then
                log("ERROR in module '" .. mod.name .. "' onTick: " .. tostring(err))
            end
        end
    end
end

-- ============================================================================
-- Core zone detection (moved from HYPOTHETIC_TSY_Main)
-- Each client checks its own player and sends state to the server for broadcast.
-- ============================================================================
---@param player IsoPlayer
local function checkPlayerZone(player)
    if not player then return end

    -- Wait until zone data is available
    if not RegionManager or not RegionManager.Client or not RegionManager.Client.zoneData then
        if requestBoundariesThrottled() then
            log("Waiting for zone data, RequestAllBoundaries sent")
        end
        return
    end

    local playerX = player:getX()
    local playerY = player:getY()

    -- Build current zones list. Use the bucketed spatial grid when available
    -- (built by RegionManager_Client when AllZoneBoundaries arrives) so we
    -- only test zones whose bucket contains the player, not every registered
    -- zone every tick.
    local currentZones = {}
    local bucket = RegionManager.Client.getZonesAt and RegionManager.Client.getZonesAt(playerX, playerY) or nil
    local scanList = bucket or RegionManager.Client.zoneData
    if scanList then
        for _, zone in ipairs(scanList) do
            local bounds = zone.bounds
            if bounds and
               playerX >= bounds.minX and playerX <= bounds.maxX and
               playerY >= bounds.minY and playerY <= bounds.maxY then
                currentZones[zone.id] = zone
            end
        end
    end

    -- ---- Zone entries (in current but not in previous) ----
    for zoneId, zoneData in pairs(currentZones) do
        if not PreviousZones[zoneId] then
            log("Player ENTERED zone: " .. zoneData.name)

            -- The message itself controls entry notifications, including old
            -- regions saved with the former announcement flags disabled.
            local message = zoneData.message
            if type(message) == "string" and message:match("%S") then
                local color = zoneData.color or {r=255, g=255, b=255}
                player:Say(message, color.r, color.g, color.b, UIFont.Medium, 3, "radio")
            end

            -- Notify registered modules (e.g., PVP module)
            notifyZoneEntered(player, zoneId, zoneData)
        end
    end

    -- ---- Zone exits (in previous but not in current) ----
    for zoneId, zoneData in pairs(PreviousZones) do
        if not currentZones[zoneId] then
            log("Player EXITED zone: " .. zoneData.name)

            -- Notify registered modules (e.g., PVP module)
            notifyZoneExited(player, zoneId, zoneData)
        end
    end

    -- Update previous zones
    PreviousZones = currentZones

    -- Notify modules with periodic tick (pass current zones for convenience)
    notifyTick(player, currentZones)
end

-- ============================================================================
-- Tick handler – single OnTick for all region-based client logic
-- ============================================================================
local function OnTick()
    TickCounter = TickCounter + 1
    if TickCounter >= TickInterval then
        TickCounter = 0
        local player = getPlayer()
        if player then
            checkPlayerZone(player)
        end
    end
end

-- ============================================================================
-- Player spawn – reset zone state & request boundaries
-- ============================================================================
local function OnPlayerSpawn()
    local player = getPlayer()
    if player then
        PreviousZones = {}
        log("Player spawned – cleared zone state and requested boundaries")
    end
end

-- ============================================================================
-- Public helpers
-- ============================================================================

-- Get the table of zones the player is currently inside
---@return table<string, ClientZoneData>
function RegionManager.ClientTick.getCurrentZones()
    return PreviousZones
end

-- Allow external adjustment of tick interval
---@param ticks number Number of game ticks between checks
function RegionManager.ClientTick.setTickInterval(ticks)
    TickInterval = ticks
end

-- Reset zone state so entry/exit events re-fire after zone data refresh
function RegionManager.ClientTick.resetZoneState()
    PreviousZones = {}
    log("Zone state reset – entry/exit events will re-fire on next tick")
end

-- ============================================================================
-- Event registration
-- ============================================================================
Events.OnTick.Add(OnTick)
Events.OnCreatePlayer.Add(OnPlayerSpawn)

log("RegionManager ClientTick dispatcher loaded")

return RegionManager.ClientTick
