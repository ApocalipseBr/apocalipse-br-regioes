-- ============================================================================
-- File: media/lua/server/RegionManager_ZombieServer.lua
-- Server-side core flow: handles zombie state management and client commands.
-- Heavy lifting (chance aggregation, rolling, payload building) lives in
-- RegionManager_ZombieServerHelper.lua.
-- ============================================================================
--
-- Region-Based Sprinter System:
-- - Zombies are converted to sprinters based on region configuration
-- - Each region can specify "sprinterChance" (1-100) in customProperties
-- - If no region or no sprinterChance property, uses baseline (default: 0)
-- - Conversion is deterministic based on zombie ID for client-server sync
--
-- Usage in RegionManager_Config.lua:
--   customProperties = {
--       sprinterChance = 80  -- 80% of zombies become sprinters in this zone
--   }
if not isServer() then
    return
end

-- Helper handles all RegionManager.Shared / RegionManager_Config dependencies
local ZombieHelper = require "RegionManager_ZombieServerHelper"
local sandboxOptions = getSandboxOptions()

local function isDebugModeEnabled()
    return SandboxVars and SandboxVars.RegionManager and SandboxVars.RegionManager.DebugMode == true
end

local function debugPrint(...)
    if isDebugModeEnabled() then
        print(...)
    end
end

local function getToughHitSyncRadius()
    return 80
end

-- Fast lookup cache for zombies already loaded on the server.
-- Key: reliable persistentID, Value: IsoZombie reference.
local ZombieRefByPID = {}

local function cacheZombieRefByPID(zombie, persistentID)
    if not zombie or zombie:isDead() then
        return nil
    end

    local pid = persistentID or ZombieHelper.GetReliablePID(zombie)
    if pid then
        ZombieRefByPID[pid] = zombie
    end
    return pid
end

local function getCachedZombieRefByPID(persistentID)
    if not persistentID then
        return nil
    end

    local zombie = ZombieRefByPID[persistentID]
    if not zombie or zombie:isDead() then
        ZombieRefByPID[persistentID] = nil
        return nil
    end

    local currentPID = ZombieHelper.GetReliablePID(zombie)
    if currentPID ~= persistentID then
        ZombieRefByPID[persistentID] = nil
        return nil
    end

    return zombie
end

local function clearCachedZombieRefByPID(persistentID)
    if persistentID then
        ZombieRefByPID[persistentID] = nil
    end
end

-- ========================================================================
-- ModData storage
-- ========================================================================

local function Apocalipse_TSY_GetGlobalModData()
    local modData = ModData.getOrCreate("Apocalipse_TSY_ZombieStates")
    if not modData.zombies then
        modData.zombies = {}
    end
    return modData
end

local function Apocalipse_TSY_ClearAllZombieStates()
    local globalData = Apocalipse_TSY_GetGlobalModData()
    local count = 0
    if globalData.zombies then
        for _ in pairs(globalData.zombies) do
            count = count + 1
        end
        globalData.zombies = {}
    end
    -- print("Apocalipse_TSY Server: Cleared " .. count .. " zombie states from ModData")
    return count
end

-- ========================================================================
-- Zombie decision making
-- ========================================================================

--- Resolve (or retrieve cached) zombie decisions for a given persistentID.
---@param persistentID string
---@param x number
---@param y number
---@return table|nil decisions
local function RegionManagerZombie_OnZombieCreate(persistentID, x, y)
    if not persistentID then
        return nil
    end

    local globalData = Apocalipse_TSY_GetGlobalModData()

    -- Find overlapping regions
    local regions = ZombieHelper.FindRegionsAt(x, y)
    local hasRegions = false
    for _ in pairs(regions) do
        hasRegions = true;
        break
    end
    if not hasRegions then
        return nil
    end

    -- Aggregate max chances across overlapping zones then roll
    local chances = ZombieHelper.AggregateChances(regions)
    if not chances then
        return nil
    end

    local decisions = ZombieHelper.RollDecisions(chances, x, y)

    -- print("Apocalipse_TSY Server: Creating zombie " .. persistentID ..
    --       " at (" .. x .. ", " .. y .. ")")

    -- Persist
    globalData.zombies[persistentID] = decisions
    return decisions
end

-- ========================================================================
-- Periodic cleanup of stale entries
-- ========================================================================

local function Apocalipse_TSY_PeriodicCleanup()
    local globalData = Apocalipse_TSY_GetGlobalModData()
    local cell = getCell()
    if not cell then
        return
    end

    local activeZombies = {}
    local zombies = cell:getZombieList()
    if zombies then
        for i = 0, zombies:size() - 1 do
            local zombie = zombies:get(i)
            if zombie and not zombie:isDead() then
                local pid = ZombieHelper.GetReliablePID(zombie)
                if pid then
                    activeZombies[pid] = true
                end
            end
        end
    end

    local removed = 0
    for pid in pairs(globalData.zombies) do
        if not activeZombies[pid] then
            globalData.zombies[pid] = nil
            removed = removed + 1
        end
    end

    if removed > 0 then
        debugPrint("Apocalipse_TSY Server: Periodic cleanup removed " .. removed .. " stale zombie entries")
    end
end

-- ========================================================================
-- Client command handler
-- ========================================================================
local function isDoorLike(obj)
    return obj and (instanceof(obj, "IsoDoor") or (instanceof(obj, "IsoThumpable") and obj:isDoor()))
end

local function isWindowLike(obj)
    return obj and instanceof(obj, "IsoWindow")
end

-- applyForcedThumpDamage:
-- 1. Check if this door has a barricade facing the zombie. If so, apply Damage()
--    so vanilla sync/removal logic runs. Thump() is pcall-guarded for sounds only.
-- 2. For IsoThumpable (furniture/walls): use Damage(). Thump() is pcall-guarded.
-- 3. For IsoDoor: use setHealth() / Damage() and NEVER call Thump(zombie) directly.
--    IsoDoor.Thump with cognition==1 zombies calls ToggleDoor->ToggleDoorActual
--    which NPEs on player.isLocalPlayer() when thumper is not an IsoPlayer.
--    Instead we manually call destroy() when health reaches zero.
local FORCE_DAMAGE = 210

-- Attempt to destroy a door if its health is at or below zero.
local function destroyIfDead(doorObj)
    local okHp, curHp = pcall(function()
        return doorObj:getHealth()
    end)
    if okHp and tonumber(curHp) and tonumber(curHp) <= 0 then
        debugPrint("[ForceDoorThump] health<=0, calling destroy()")
        pcall(function()
            doorObj:destroy()
        end)
    end
end

local function applyForcedThumpDamage(doorObj, thumper)
    -- getThumpableFor redirects to a barricade if one is blocking this zombie.
    local ok, thumpable = pcall(function()
        return doorObj:getThumpableFor(thumper)
    end)

    if ok and thumpable and instanceof(thumpable, "IsoBarricade") then
        local before = tonumber(thumpable:getHealth()) or 0
        local maxHp = tonumber(thumpable:getMaxHealth()) or 0

        -- Damage() handles sync + sprite update internally on the server.
        local okDamage = pcall(function()
            thumpable:Damage(FORCE_DAMAGE)
        end)
        if not okDamage then
            local after = before - FORCE_DAMAGE
            pcall(function()
                thumpable:setHealth(math.max(after, 0))
            end)
            pcall(function()
                thumpable:sync()
            end)
        end

        debugPrint(
            "[ForceDoorThump] barricade damage " .. tostring(FORCE_DAMAGE) .. " hp " .. tostring(before) .. "/" ..
                tostring(maxHp) .. " -> " .. tostring(thumpable:getHealth()) .. "/" .. tostring(maxHp))

        -- Thump for sounds/render effects only; pcall-guard since we already did damage.
        pcall(function()
            thumpable:Thump(thumper)
        end)
        return
    end

    -- No barricade: in 42.18, door-like objects can be IsoDoor or IsoThumpable.

    if instanceof(doorObj, "IsoThumpable") then
        local okBefore, beforeRaw = pcall(function()
            return doorObj:getHealth()
        end)
        local before = okBefore and tonumber(beforeRaw) or nil
        local okMax, maxRaw = pcall(function()
            return doorObj:getMaxHealth()
        end)
        local maxHp = okMax and tonumber(maxRaw) or nil

        -- Damage() on IsoThumpable handles health + sync + destruction internally.
        local okDamage = pcall(function()
            doorObj:Damage(FORCE_DAMAGE)
        end)
        if not okDamage then
            debugPrint("[ForceDoorThump] IsoThumpable Damage() unavailable; skipping")
            return
        end

        local okAfter, afterRaw = pcall(function()
            return doorObj:getHealth()
        end)
        local after = okAfter and tonumber(afterRaw) or nil
        debugPrint(
            "[ForceDoorThump] thumpable damage " .. tostring(FORCE_DAMAGE) .. " hp " .. tostring(before or "n/a") .. "/" ..
                tostring(maxHp or "n/a") .. " -> " .. tostring(after or "n/a") .. "/" .. tostring(maxHp or "n/a"))

        -- Thump for sounds/render; pcall-guard since damage is already applied.
        pcall(function()
            doorObj:Thump(thumper)
        end)
        return
    end

    if not instanceof(doorObj, "IsoDoor") then
        -- Unknown type: pcall-guard Thump to avoid unhandled crashes.
        debugPrint("[ForceDoorThump] unsupported object type; attempting pcall Thump")
        local okThump = pcall(function()
            doorObj:Thump(thumper)
        end)
        if not okThump then
            debugPrint("[ForceDoorThump] pcall Thump failed; giving up")
        end
        return
    end

    -- IsoDoor path. DO NOT call Thump(zombie) here: IsoDoor.Thump with a
    -- cognition==1 zombie calls ToggleDoorActual which NPEs on player.isLocalPlayer().
    local okBefore, beforeRaw = pcall(function()
        return doorObj:getHealth()
    end)
    local before = okBefore and tonumber(beforeRaw) or nil
    if not before then
        debugPrint("[ForceDoorThump] IsoDoor has no getHealth; skipping")
        return
    end

    local okMax, maxRaw = pcall(function()
        return doorObj:getMaxHealth()
    end)
    local maxHp = okMax and tonumber(maxRaw) or nil

    local after = before - FORCE_DAMAGE
    local okSet = pcall(function()
        doorObj:setHealth(after)
    end)
    if not okSet then
        okSet = pcall(function()
            doorObj:Damage(FORCE_DAMAGE)
        end)
    end
    if not okSet then
        debugPrint("[ForceDoorThump] IsoDoor: no setHealth or Damage available; skipping")
        return
    end

    pcall(function()
        doorObj:sync()
    end)

    debugPrint("[ForceDoorThump] door damage " .. tostring(FORCE_DAMAGE) .. " hp " .. tostring(before) .. "/" ..
                   tostring(maxHp or "n/a") .. " -> " .. tostring(after) .. "/" .. tostring(maxHp or "n/a"))

    -- Destruction check: no Thump() on IsoDoor with zombie; call destroy() manually.
    destroyIfDead(doorObj)
end

local function Apocalipse_TSY_OnClientCommand(module, command, player, args)
    if module ~= "Apocalipse_TSY" then
        return
    end

    -- ---- Server-authoritative door thump fallback ----
    if command == "ForceDoorThump" and player and args and args.zombieID and args.x and args.y and args.z then
        local zombieID = tonumber(args.zombieID)
        local x = tonumber(args.x)
        local y = tonumber(args.y)
        local z = tonumber(args.z)
        debugPrint("[ForceDoorThump] recv user=" .. tostring(player and player:getUsername()) .. " zombieID=" ..
                       tostring(args.zombieID) .. " pid=" .. tostring(args.pid) .. " xyz=" .. tostring(args.x) .. "," ..
                       tostring(args.y) .. "," .. tostring(args.z))
        if not zombieID or not x or not y or not z then
            debugPrint("[ForceDoorThump] reject invalid numeric args")
            return
        end

        local zombie = ZombieHelper.FindZombieByOnlineID(zombieID)
        if zombie then
            debugPrint("[ForceDoorThump] zombie resolved by onlineID=" .. tostring(zombieID))
        end
        if not zombie and args.pid then
            local pid = tostring(args.pid)
            local cell = getCell()
            if cell then
                local zombies = cell:getZombieList()
                if zombies then
                    for i = 0, zombies:size() - 1 do
                        local cand = zombies:get(i)
                        if cand and not cand:isDead() and ZombieHelper.GetReliablePID(cand) == pid then
                            zombie = cand
                            debugPrint("[ForceDoorThump] zombie resolved by pid=" .. tostring(pid) .. " onlineID=" ..
                                           tostring(cand:getOnlineID()))
                            break
                        end
                    end
                end
            end
        end
        if not zombie or zombie:isDead() then
            debugPrint("[ForceDoorThump] reject zombie not found/dead")
            return
        end

        -- Preferred target: whatever the server zombie is currently thumping.
        local okTarget, thumpTarget = pcall(function()
            return zombie:getThumpTarget()
        end)
        if okTarget and isDoorLike(thumpTarget) then
            local tsq = thumpTarget:getSquare()
            debugPrint("[ForceDoorThump] using zombie thumpTarget at " .. tostring(tsq and tsq:getX()) .. "," ..
                           tostring(tsq and tsq:getY()) .. "," .. tostring(tsq and tsq:getZ()))
            applyForcedThumpDamage(thumpTarget, zombie)
            debugPrint("[ForceDoorThump] thump applied via thumpTarget")
            return
        end
        if not okTarget then
            debugPrint("[ForceDoorThump] zombie:getThumpTarget() failed")
        else
            debugPrint("[ForceDoorThump] thumpTarget missing/not door-like, using square fallback")
        end

        local sq = getCell():getGridSquare(x, y, z)
        if not sq then
            debugPrint("[ForceDoorThump] reject square not found at " .. tostring(x) .. "," .. tostring(y) .. "," ..
                           tostring(z))
            return
        end

        local objects = sq:getObjects()
        if not objects then
            debugPrint("[ForceDoorThump] reject square has no objects")
            return
        end

        for i = 0, objects:size() - 1 do
            local obj = objects:get(i)
            if isDoorLike(obj) then
                debugPrint("[ForceDoorThump] thump applied via square object index=" .. tostring(i))
                applyForcedThumpDamage(obj, zombie)
                return
            end
        end
        debugPrint("[ForceDoorThump] no door-like object found on fallback square")
        return
    end

    -- ---- Server-authoritative window thump fallback ----
    if command == "ForceWindowThump" and player and args and args.zombieID and args.x and args.y and args.z then
        local zombieID = tonumber(args.zombieID)
        local x = tonumber(args.x)
        local y = tonumber(args.y)
        local z = tonumber(args.z)
        debugPrint("[ForceWindowThump] recv user=" .. tostring(player and player:getUsername()) .. " zombieID=" ..
                       tostring(args.zombieID) .. " pid=" .. tostring(args.pid) .. " xyz=" .. tostring(args.x) .. "," ..
                       tostring(args.y) .. "," .. tostring(args.z))
        if not zombieID or not x or not y or not z then
            debugPrint("[ForceWindowThump] reject invalid numeric args")
            return
        end

        local zombie = ZombieHelper.FindZombieByOnlineID(zombieID)
        if zombie then
            debugPrint("[ForceWindowThump] zombie resolved by onlineID=" .. tostring(zombieID))
        end
        if not zombie and args.pid then
            local pid = tostring(args.pid)
            local cell = getCell()
            if cell then
                local zombies = cell:getZombieList()
                if zombies then
                    for i = 0, zombies:size() - 1 do
                        local cand = zombies:get(i)
                        if cand and not cand:isDead() and ZombieHelper.GetReliablePID(cand) == pid then
                            zombie = cand
                            debugPrint("[ForceWindowThump] zombie resolved by pid=" .. tostring(pid) .. " onlineID=" ..
                                           tostring(cand:getOnlineID()))
                            break
                        end
                    end
                end
            end
        end
        if not zombie or zombie:isDead() then
            debugPrint("[ForceWindowThump] reject zombie not found/dead")
            return
        end

        -- Preferred target: whatever the server zombie is currently thumping.
        local okTarget, thumpTarget = pcall(function()
            return zombie:getThumpTarget()
        end)
        if okTarget and isWindowLike(thumpTarget) then
            local tsq = thumpTarget:getSquare()
            debugPrint("[ForceWindowThump] using zombie thumpTarget at " .. tostring(tsq and tsq:getX()) .. "," ..
                           tostring(tsq and tsq:getY()) .. "," .. tostring(tsq and tsq:getZ()))
            thumpTarget:Thump(zombie)
            debugPrint("[ForceWindowThump] thump applied via thumpTarget")
            return
        end
        if not okTarget then
            debugPrint("[ForceWindowThump] zombie:getThumpTarget() failed")
        else
            debugPrint("[ForceWindowThump] thumpTarget missing/not window-like, using square fallback")
        end

        local sq = getCell():getGridSquare(x, y, z)
        if not sq then
            debugPrint("[ForceWindowThump] reject square not found at " .. tostring(x) .. "," .. tostring(y) .. "," ..
                           tostring(z))
            return
        end

        local objects = sq:getObjects()
        if not objects then
            debugPrint("[ForceWindowThump] reject square has no objects")
            return
        end

        for i = 0, objects:size() - 1 do
            local obj = objects:get(i)
            if isWindowLike(obj) then
                debugPrint("[ForceWindowThump] thump applied via square object index=" .. tostring(i))
                applyForcedThumpDamage(obj, zombie)
                return
            end
        end
        debugPrint("[ForceWindowThump] no window-like object found on fallback square")
        return
    end

    -- ---- Admin: clear all zombie states ----
    if command == "ClearZombieStates" then
        if player and player:getAccessLevel() ~= "None" then
            local count = Apocalipse_TSY_ClearAllZombieStates()
            sendServerCommand(player, "Apocalipse_TSY", "ClearConfirm", {
                count = count
            })
            debugPrint(
                "Apocalipse_TSY Server: Admin " .. player:getUsername() .. " cleared zombie ModData (" .. count ..
                    " entries)")
        else
            debugPrint("Apocalipse_TSY Server: Non-admin " .. player:getUsername() ..
                           " attempted to clear zombie ModData")
        end
        return
    end

    if command == "ZombieHitTough" and player and args.zombieID then
        local zombieID = args.zombieID
        local x, y = args.x, args.y
        local globalData = Apocalipse_TSY_GetGlobalModData()

        -- Prefer the client-provided reliable PID and resolve through cache.
        -- This avoids scanning the whole server zombie list for every hit.
        local persistentID = args.persistentID
        local zombie = getCachedZombieRefByPID(persistentID)

        -- Fallback for first-seen zombies or stale cache entries.
        if not zombie then
            zombie = ZombieHelper.FindZombieByOnlineID(zombieID)
            if zombie then
                persistentID = cacheZombieRefByPID(zombie, persistentID)
            end
        end

        -- Final fallback: use client PID even if we cannot resolve a live ref.
        if not persistentID then
            persistentID = args.persistentID
        end

        local stored = persistentID and globalData.zombies[persistentID]

        if stored and stored.isTough then
            if not stored.toughnessHitCounter then
                stored.toughnessHitCounter = 0
            end
            local maxHits = stored.maxHits or RegionManager.Shared.DEFAULT_MAX_HITS

            stored.toughnessHitCounter = math.min(stored.toughnessHitCounter + 1, maxHits)
            local isExhausted = stored.toughnessHitCounter >= maxHits
            if isExhausted then
                debugPrint("Apocalipse_TSY Server: Tough zombie pid=" .. tostring(persistentID) ..
                               " exhausted all lives")
            else
                debugPrint("Apocalipse_TSY Server: Tough zombie pid=" .. tostring(persistentID) .. " hit (" ..
                               stored.toughnessHitCounter .. "/" .. maxHits .. ")")
            end

            if zombie and not zombie:isDead() then
                local modData = zombie:getModData()
                modData.Apocalipse_TSY_IsToughZombie = true
                modData.Apocalipse_TSY_ToughnessType = isExhausted and "exhausted" or "tough"
                modData.Apocalipse_TSY_ToughnessHitCounter = stored.toughnessHitCounter
                modData.Apocalipse_TSY_ToughnessMaxHits = maxHits
            end

            local syncX = zombie and zombie:getX() or x
            local syncY = zombie and zombie:getY() or y
            local payload = {
                zombieID = zombieID,
                persistentID = persistentID,
                hitCounter = stored.toughnessHitCounter,
                maxHits = maxHits,
                x = syncX,
                y = syncY,
                isExhausted = isExhausted
            }
            local sentCount = ZombieHelper.SendToPlayersNear("Apocalipse_TSY", "ToughZombieHit", payload, syncX, syncY,
                getToughHitSyncRadius())
            if isExhausted then
                debugPrint("Apocalipse_TSY Server: Sent ToughZombieHit exhausted pid=" .. tostring(persistentID) ..
                               " onlineID=" .. tostring(zombieID) .. " (" .. tostring(stored.toughnessHitCounter) .. "/" ..
                               tostring(maxHits) .. "), recipients=" .. tostring(sentCount))
            end
        else
            -- No stored data - broadcast exhausted so client stops mitigating
            debugPrint("Apocalipse_TSY Server: ZombieHitTough no match for pid=" .. tostring(persistentID) ..
                           " (onlineID=" .. tostring(zombieID) .. ", clientPID=" .. tostring(args.persistentID) .. ")")
            local payload = {
                zombieID = zombieID,
                persistentID = persistentID,
                hitCounter = RegionManager.Shared.DEFAULT_MAX_HITS,
                maxHits = RegionManager.Shared.DEFAULT_MAX_HITS,
                x = x,
                y = y,
                isExhausted = true
            }
            ZombieHelper.SendToPlayersNear("Apocalipse_TSY", "ToughZombieHit", payload, x, y, getToughHitSyncRadius())
        end
        return
    end
end

-- ========================================================================
-- Initialisation
-- ========================================================================

Events.OnInitWorld.Add(function()
    -- Completely re persisted ModData so nothing survives a restart
    if ModData.exists("Apocalipse_TSY_ZombieStates") then
        ModData.remove("Apocalipse_TSY_ZombieStates")
    end
    -- Recreate a fresh, empty table
    local freshData = ModData.getOrCreate("Apocalipse_TSY_ZombieStates")
    freshData.zombies = {}
    debugPrint("Apocalipse_TSY Server: Server startup - ModData fully wiped and recreated")

    -- Events.EveryTenMinutes.Add(Apocalipse_TSY_PeriodicCleanup)
    -- print("Apocalipse_TSY Server: Periodic cleanup scheduled (every 10 minutes)")
end)

-- ========================================================================
-- Cleanup on zombie death
-- ========================================================================

local function RegionManagerZombie_OnZombieDead(zombie)
    if not zombie then
        return
    end
    local persistentID = ZombieHelper.GetReliablePID(zombie)
    if not persistentID then
        return
    end
    clearCachedZombieRefByPID(persistentID)
    local globalData = Apocalipse_TSY_GetGlobalModData()
    if globalData.zombies[persistentID] then
        globalData.zombies[persistentID] = nil
    end
end

-- Apply server-side zombie properties from the rolled decision table.
-- Use the shared ServerSideProperties path (makeInactive + sandbox mapping)
-- because raw Java field assignment is not writable from Lua bridge.
---@param zombie IsoZombie
---@param data table
local function applyDecisionsToZombie(zombie, data)
    if not zombie or not data then
        return
    end

    local modData = zombie:getModData()
    local expectedSpeedType = nil

    if data.isSprinter then
        zombie:doSprinter()
        expectedSpeedType = 1
    elseif data.isShambler then
        zombie:doShambler()
        expectedSpeedType = 3
    else
        zombie:doFastShambler()
        modData.Apocalipse_TSY_ExpectedSpeedType = nil
    end

    -- Persist speed expectation for server-side speed revalidation.
    modData.Apocalipse_TSY_HasZombieOverrides = true
    modData.Apocalipse_TSY_ExpectedSpeedType = expectedSpeedType

    -- Stamp toughness-related modData when this zombie is rolled as tough.
    -- Keep these values aligned with applyServerToughnessHit semantics.
    if data.isTough then
        local maxHits = data.maxHits or RegionManager.Shared.DEFAULT_MAX_HITS
        data.maxHits = maxHits
        data.toughnessHitCounter = data.toughnessHitCounter or 0
        modData.Apocalipse_TSY_IsToughZombie = true
        modData.Apocalipse_TSY_ToughnessType = "tough"
        modData.Apocalipse_TSY_ToughnessHitCounter = data.toughnessHitCounter
        modData.Apocalipse_TSY_ToughnessMaxHits = maxHits
    else
        modData.Apocalipse_TSY_IsToughZombie = nil
        if modData.Apocalipse_TSY_ToughnessType == "tough" then
            modData.Apocalipse_TSY_ToughnessType = nil
        end
        modData.Apocalipse_TSY_ToughnessHitCounter = nil
        modData.Apocalipse_TSY_ToughnessMaxHits = nil
    end

end

local function onZombieCreate(zombie)
    if not zombie then
        return
    end
    local zx, zy = zombie:getX(), zombie:getY()
    local persistentID = ZombieHelper.GetReliablePID(zombie) or ZombieHelper.GetPersistentID(zombie)
    if not persistentID then
        debugPrint("Apocalipse_TSY Server: Failed to compute persistentID for zombie onlineID=" ..
                       tostring(zombie:getOnlineID()))
        return
    end
    local decisions = RegionManagerZombie_OnZombieCreate(persistentID, zx, zy)
    if decisions then
        applyDecisionsToZombie(zombie, decisions)
        cacheZombieRefByPID(zombie, persistentID)
    end
end
Events.OnZombieCreate.Add(onZombieCreate)
Events.OnZombieDead.Add(RegionManagerZombie_OnZombieDead)
Events.OnClientCommand.Add(Apocalipse_TSY_OnClientCommand)
