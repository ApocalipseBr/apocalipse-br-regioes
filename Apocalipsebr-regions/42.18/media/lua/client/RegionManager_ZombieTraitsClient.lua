if isServer() then return end
require "RegionManager_ZombieTraits"

local Traits = RegionManager.ZombieTraits
RegionManager.ZombieTraitsClient = RegionManager.ZombieTraitsClient or {}
local Client = RegionManager.ZombieTraitsClient
local queue, head, tail = {}, 1, 0
local tracked = setmetatable({}, { __mode = "k" })
local options, defaults
local revision = 0
local rulesKey, rulesDirty = nil, true
local profiles, profileOrder, profileHead, profileTail = {}, {}, 1, 0
local MAX_PROFILES = 4096

local function isLoaded(zombie)
    if not zombie or zombie:isDead() then return false end
    local square = zombie:getCurrentSquare()
    if not square or zombie:getMovingObjectIndex() < 0 then return false end
    -- A removed chunk can leave a square reference on a queued Java object.
    -- Validate against the live cell, not just the saved object pointer.
    local cell = getCell()
    return cell ~= nil and cell:getGridSquare(square:getX(), square:getY(), square:getZ()) == square
end

local function remember(identity, record)
    if not profiles[identity] then
        profileTail = profileTail + 1
        profileOrder[profileTail] = identity
    end
    profiles[identity] = record
    if profileTail - profileHead + 1 > MAX_PROFILES then
        profiles[profileOrder[profileHead]] = nil
        profileOrder[profileHead], profileHead = nil, profileHead + 1
    end
end

local function initialize()
    if options then return true end
    local sandbox = getSandboxOptions()
    if not sandbox then return false end
    local found = {}
    for key, name in pairs({ cognition = "Cognition", doorOpening = "DoorOpeningPercentage",
        sight = "Sight", hearing = "Hearing" }) do
        local option = sandbox:getOptionByName("ZombieLore." .. name)
        if not option then return false end
        found[key] = option:asConfigOption()
    end
    local baseline = {}
    for key, option in pairs(found) do baseline[key] = option:getValue() end
    options, defaults = found, baseline
    return true
end

local function append(job)
    tail = tail + 1
    queue[tail] = job
end

local function enqueue(zombie, recreate)
    if not zombie then return end
    if recreate then tracked[zombie] = nil end
    local job = tracked[zombie]
    if job and job.queued then return end
    if not job then
        job = { zombie = zombie }
        tracked[zombie] = job
    end
    job.zombie = zombie
    job.stage, job.queued, job.waits = 1, true, 0
    append(job)
end

local function apply(zombie, profile)
    if not isLoaded(zombie) then return false end
    if not initialize() then return false end
    local saved = {}
    for key, option in pairs(options) do saved[key] = option:getValue() end
    -- A Lua-only DoZombieStats call also touches locomotion. Restore exposed
    -- movement values and vehicle-crawling; internal animation effects remain
    -- a prototype limitation. Never use the makeInactive cycle here.
    local walkType = zombie:getWalkType()
    local speedMod = zombie:getSpeedMod()
    local underVehicle = zombie:isCanCrawlUnderVehicle()
    local ok, err = pcall(function()
        options.cognition:setValue(4)
        options.doorOpening:setValue(profile.doors and 100 or 0)
        options.sight:setValue(profile.sight)
        options.hearing:setValue(profile.hearing)
        zombie:DoZombieStats()
    end)
    -- Restore every sandbox option even if initialization throws. All writes
    -- and the stats call occur within this tick, never across queued stages.
    local restored = true
    for key, option in pairs(options) do
        local success = pcall(function() option:setValue(saved[key]) end)
        restored = restored and success
    end
    local movementRestored = pcall(function()
        zombie:setWalkType(walkType)
        zombie:setSpeedTypeFromWalkType()
        zombie:setSpeedMod(speedMod)
        zombie:setCanCrawlUnderVehicle(underVehicle)
    end)
    if not ok or not restored or not movementRestored then
        RegionManager.Log("ZombieTraits", "Property application failed: " .. tostring(err))
        return false
    end
    return true
end

local function finish(job)
    job.queued = false
    job.profile, job.chances = nil, nil
    job.zombie = nil -- Avoid a weak-key/value reference cycle in Kahlua (Lua 5.1).
end

local function discard(zombie, job)
    if zombie and tracked[zombie] == job then tracked[zombie] = nil end
    finish(job)
end

-- Exactly one queue stage per OnTick, round-robin across pending zombies.
local function tick()
    if head > tail then queue, head, tail = {}, 1, 0; return end
    local job = queue[head]
    queue[head], head = nil, head + 1
    local zombie = job.zombie
    if not zombie or tracked[zombie] ~= job or not isLoaded(zombie)
        or (job.onlineId ~= nil and zombie:getOnlineID() ~= job.onlineId) then
        discard(zombie, job)
        return
    end
    if job.onlineId == nil then
        local onlineId = zombie:getOnlineID()
        if onlineId ~= -1 then job.onlineId = onlineId end
    end
    -- Don't consume a partially computed profile after a region reload.
    if job.stage > 1 and job.revision ~= revision then job.stage = 1 end
    if job.stage == 1 then
        local identity = Traits.identity(zombie)
        if not identity or not RegionManager.Client or not RegionManager.Client.zoneData or not initialize() then
            job.waits = job.waits + 1
            if job.waits >= 600 then finish(job); return end
            append(job)
            return
        end
        job.identity, job.revision = identity, revision
        local onlineId = zombie:getOnlineID()
        if onlineId ~= -1 then job.onlineId = onlineId end
        if rulesDirty then
            local current = Traits.rulesKey(RegionManager.Client.zoneData)
            if current ~= rulesKey then
                profiles, profileOrder, profileHead, profileTail = {}, {}, 1, 0
            end
            rulesKey, rulesDirty = current, false
        end
        job.x, job.y = zombie:getX(), zombie:getY()
    elseif job.stage == 2 then
        local cached = profiles[job.identity] or zombie:getModData().Apocalipse_TSY_ClientTraits
        if cached and cached.identity == job.identity and cached.rulesKey == rulesKey
            and cached.version == Traits.VERSION then
            job.profile, job.cached = cached, true
        else
            job.cached = false
            local zones = RegionManager.Client.getZonesAt and RegionManager.Client.getZonesAt(job.x, job.y)
                or RegionManager.Client.zoneData
            local controlled
            job.chances, controlled = Traits.aggregate(zones, job.x, job.y)
            if not controlled then finish(job); job.appliedRevision = revision; return end
            job.profile = {}
        end
    elseif job.stage == 3 then
        if not job.cached then job.profile.doors = Traits.cognition(job.identity, job.chances, defaults) end
    elseif job.stage == 4 then
        if not job.cached then job.profile.sight = Traits.sense(job.identity, "sight", job.chances, defaults) end
    elseif job.stage == 5 then
        if not job.cached then job.profile.hearing = Traits.sense(job.identity, "hearing", job.chances, defaults) end
    elseif job.stage == 6 then
        if job.identity ~= Traits.identity(zombie) then job.stage = 1; append(job); return end
        local p = job.profile
        local signature = job.identity .. ":" .. tostring(p.doors) .. ":" .. p.sight .. ":" .. p.hearing
        if signature ~= job.signature or job.repair then
            if not apply(zombie, p) then finish(job); return end
            job.signature = signature
        end
        zombie:getModData().Apocalipse_TSY_ClientTraits = {
            identity = job.identity, doors = p.doors, sight = p.sight, hearing = p.hearing,
            version = Traits.VERSION, rulesKey = rulesKey
        }
    elseif job.stage == 7 then
        local record = zombie:getModData().Apocalipse_TSY_ClientTraits
        if record then remember(job.identity, record) end
        job.appliedRevision, job.repair = revision, false
        finish(job)
        return
    end
    job.stage = job.stage + 1
    append(job)
end

local function update(zombie)
    local job = tracked[zombie]
    if not isLoaded(zombie) then
        if job then discard(zombie, job) end
        return
    end
    if job and job.onlineId ~= nil and zombie:getOnlineID() ~= job.onlineId then
        discard(zombie, job)
        job = nil
    end
    if not job then enqueue(zombie); return end
    local remote = zombie:isRemoteZombie()
    if job.remote ~= nil and job.remote ~= remote and not remote then job.repair = true end
    job.remote = remote
    -- Cheap lifecycle/configuration checks only; property work stays in queue.
    if not job.queued and (job.repair or job.appliedRevision ~= revision) then enqueue(zombie) end
end

local function onServerCommand(module, command)
    if module == "RegionManager" and command == "AllZoneBoundaries" then
        revision, rulesDirty = revision + 1, true
    end
end

Client.enqueue = enqueue
Client.tick = tick
Client.update = update
Client.apply = apply
Client.onServerCommand = onServerCommand
Events.OnGameStart.Add(function()
    queue, head, tail = {}, 1, 0
    tracked = setmetatable({}, { __mode = "k" })
    profiles, profileOrder, profileHead, profileTail = {}, {}, 1, 0
    options, defaults, rulesKey = nil, nil, nil
    rulesDirty, revision = true, 0
end)
Events.OnZombieCreate.Add(function(zombie) enqueue(zombie, true) end)
Events.OnZombieUpdate.Add(update)
Events.OnTick.Add(tick)
Events.OnServerCommand.Add(onServerCommand)
