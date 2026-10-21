-- Server-authoritative, bounded population additions. No chunk loading requests.
if not isServer() then return end
require "RegionManager_Config"

RegionManager.Population = {}
local Population = RegionManager.Population
local C = RegionManager.Config.Population
local jobs, registry, discovery, discovering, cursor = {}, nil, nil, false, 0
local saved, lastSpawn = nil, -math.huge
local directions = {{1,0,0},{0,1,0},{-1,0,0},{0,-1,0},
    {0,-1,1},{-1,0,1},{0,1,-1},{1,0,-1}}

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function number(value, fallback, low, high)
    if not finite(value) then return fallback end
    return math.max(low, math.min(high, value))
end

local function contains(b, x, y)
    return x >= b.minX and x <= b.maxX and y >= b.minY and y <= b.maxY
end

local function near(b, x, y, radius)
    local dx = math.max(b.minX - x, 0, x - b.maxX)
    local dy = math.max(b.minY - y, 0, y - b.maxY)
    return dx * dx + dy * dy <= radius * radius
end

local function key(x, y, z) return x .. ":" .. y .. ":" .. z end
local function now() return getTimestampMs() end

-- Only permanent negative terrain observations are persisted. Eight row masks
-- per 8x8 chunk/floor; no retained squares, eviction, or world-sized sweeps.
local function waterSlot(x, y, z)
    return key(math.floor(x / 8), math.floor(y / 8), z), y % 8 + 1, 2 ^ (x % 8)
end

local function knownWater(x, y, z)
    local chunk, row, bit = waterSlot(x,y,z)
    local rows = saved.water[chunk]
    return rows and math.floor((rows[row] or 0) / bit) % 2 == 1
end

local function squareAt(cell, x, y, z)
    if knownWater(x,y,z) then return nil end
    local square = cell:getGridSquare(x,y,z)
    if square and square:isWaterSquare() then
        local chunk, row, bit = waterSlot(x,y,z)
        local rows = saved.water[chunk]
        if not rows then rows = {}; saved.water[chunk] = rows end
        rows[row] = (rows[row] or 0) + bit
        saved.waterCount = saved.waterCount + 1
        return nil
    end
    return square
end

-- PZ's Kahlua provides pairs(), but does not provide Lua's global next().
-- Retain the iterator triple so each call visits only one table entry.
local function tableCursor(values)
    local iterator, state, control = pairs(values)
    return function()
        local id, value = iterator(state, control)
        control = id
        return id, value
    end
end

local function policy(zone)
    local p, b = zone.properties, zone.bounds
    if not p or not b or p.noZombies or not finite(p.zombiePopulationTarget)
        or p.zombiePopulationTarget <= 0 then return nil end
    local z = zone.region and zone.region.z or 0
    if not finite(z) or z ~= math.floor(z) then return nil end
    for _, name in ipairs({"minX", "maxX", "minY", "maxY"}) do
        if not finite(b[name]) or b[name] < 0 or b[name] ~= math.floor(b[name]) then return nil end
    end
    if b.maxX < b.minX or b.maxY < b.minY then return nil end
    local area = (b.maxX - b.minX + 1) * (b.maxY - b.minY + 1)
    -- Density is an upper bound in zombies per 100 tiles, on this region's floor.
    local density = number(p.zombiePopulationMaxDensity, C.DefaultMaxDensity, 0, C.MaxDensity)
    local target = math.floor(math.min(p.zombiePopulationTarget, C.MaxTarget, area * density / 100))
    if target <= 0 then return nil end
    return {
        target = target, z = z, bounds = b,
        budget = math.floor(number(p.zombiePopulationBudget, target, 0, C.MaxLifetimeBudget)),
        respawn = p.zombieRespawn == true,
        interval = number(p.zombiePopulationInterval, C.IntervalSeconds, 1, 86400) * 1000
    }
end

local function suspend(job, time, reason)
    if job.lastLoggedReason ~= reason then
        RegionManager.Log("Population", job.id .. ": paused (" .. reason .. ")")
        job.lastLoggedReason = reason
    end
    job.phase, job.nextAt, job.reason = "idle", time + C.RetryMs, reason
    job.search, job.path, job.validated, job.candidate = nil, nil, nil, nil
    job.playerId, job.coverageAt, job.census = nil, nil, nil
end

local function playerFor(job)
    local p = job.playerId and getPlayerByOnlineID(job.playerId)
    if not p or p:isDead() or not p:getSquare() then return nil end
    if math.abs(math.floor(p:getZ()) - job.policy.z) > 2
        or not near(job.policy.bounds, p:getX(), p:getY(), C.ActivationDistance) then return nil end
    return p
end

local function startCoverage(job, phase, time)
    local b = job.policy.bounds
    job.cxMin, job.cxMax = math.floor(b.minX / 8), math.floor(b.maxX / 8)
    job.cyMin, job.cyMax = math.floor(b.minY / 8), math.floor(b.maxY / 8)
    job.cx, job.cy, job.coverageStart, job.phase = job.cxMin, job.cyMin, time, phase
end

local function coverage(job, cell, time)
    if time - job.coverageStart > C.CoverageMaxAgeMs then
        suspend(job, time, "coverage expired")
        return false
    end
    for _ = 1, C.ChunkProbesPerStep do
        if not cell:getChunkForGridSquare(job.cx * 8, job.cy * 8, job.policy.z) then
            suspend(job, time, "missing chunk")
            return false
        end
        job.cx = job.cx + 1
        if job.cx > job.cxMax then job.cx, job.cy = job.cxMin, job.cy + 1 end
        if job.cy > job.cyMax then
            -- The first probe's age determines the validity of the whole pass.
            job.coverageAt = job.coverageStart
            return true
        end
    end
    return false
end

local function walkable(square, occupied)
    return square and (square:TreatAsSolidFloor() or square:HasStairs())
        and square:isFree(occupied) and not square:isVehicleIntersecting()
end

local function spawnable(square)
    return walkable(square,true) and not square:HasStairs()
end

local function edge(a, b)
    if not walkable(a,false) or not walkable(b,false) then return false end
    local dx,dy,dz = b:getX()-a:getX(), b:getY()-a:getY(), b:getZ()-a:getZ()
    if dz ~= 0 then
        -- Only actual top-stair/landing connections change floors. No falling,
        -- arbitrary vertical neighbors or shortcuts through ceilings.
        local lower, upper = a, b
        if dz < 0 then lower, upper = b, a end
        if not ((lower:HasStairTopNorth() and upper:getX() == lower:getX() and upper:getY() == lower:getY()-1)
            or (lower:HasStairTopWest() and upper:getX() == lower:getX()-1 and upper:getY() == lower:getY())) then return false end
    end
    -- Unlike physical collision, the engine path matrix permits windows and
    -- canPath door/low-fence edges. Both endpoints remain live and loaded.
    return not a:testPathFindAdjacent(nil,dx,dy,dz)
        and not b:testPathFindAdjacent(nil,-dx,-dy,-dz)
end

-- Greedy best-first: any route is sufficient. Each coordinate is enqueued
-- once, with a bounded heap instead of flooding an expanding BFS diamond.
local function push(search, node)
    local heap = search.heap
    local i = #heap + 1
    while i > 1 do
        local parent = math.floor(i / 2)
        if heap[parent].score <= node.score then break end
        heap[i], i = heap[parent], parent
    end
    heap[i] = node
end

local function pop(search)
    local heap = search.heap
    if #heap == 0 then return nil end
    local first, last = heap[1], table.remove(heap)
    if #heap > 0 then
        local i = 1
        while i * 2 <= #heap do
            local child = i * 2
            if child < #heap and heap[child+1].score < heap[child].score then child = child+1 end
            if last.score <= heap[child].score then break end
            heap[i], i = heap[child], child
        end
        heap[i] = last
    end
    return first
end

local function excluded(zone, x, y, z, ownId)
    if not zone.bounds or not contains(zone.bounds, x, y) then return false end
    if (zone.region and zone.region.z or 0) ~= z then return false end
    if zone.properties and zone.properties.noZombies then return true end
    -- One deterministic owner of overlapping spawn locations.
    local other = policy(zone)
    return other ~= nil and zone.region and tostring(zone.region.id) < ownId
end

local function nextCandidate(job, time)
    job.search, job.path, job.validated = nil, nil, nil
    job.safetyStart, job.safetyCount = nil, nil
    job.attempts = (job.attempts or 0) + 1
    if job.attempts > C.PlacementAttempts then
        suspend(job, time, "no reachable placement")
        return
    end
    local b = job.policy.bounds
    job.candidate = {x = ZombRand(b.minX, b.maxX + 1), y = ZombRand(b.minY, b.maxY + 1)}
    if knownWater(job.candidate.x,job.candidate.y,job.policy.z) then
        -- One random sample per scheduled step, even for all-water regions.
        -- Skip exclusion scans as well as engine queries for known water.
        job.phase = "candidate"
        return
    end
    job.exclusionCursor, job.phase = tableCursor(registry), "exclusions"
end

local function startSearch(job, p, time)
    local c = job.candidate
    local node = {x=c.x,y=c.y,z=job.policy.z,score=0}
    job.search = {heap={node},seen={[key(node.x,node.y,node.z)]=true},size=1,started=time,
        tx=math.floor(p:getX()),ty=math.floor(p:getY()),tz=math.floor(p:getZ()),expanded=0}
    job.phase = "search"
end

local function search(job, cell, p, time)
    local s = job.search
    if time - s.started > C.SearchMaxAgeMs or math.floor(p:getX()) ~= s.tx
        or math.floor(p:getY()) ~= s.ty or math.floor(p:getZ()) ~= s.tz then
        nextCandidate(job, time)
        return
    end
    local probes = 0
    for _ = 1, C.PathNodesPerStep do
        local node = s.active or pop(s)
        if not node then nextCandidate(job,time); return end
        local square = squareAt(cell,node.x,node.y,node.z)
        if walkable(square, false) then
            if node.x == s.tx and node.y == s.ty and node.z == s.tz then
                job.path, job.validated, job.phase = node, {}, "finalCoverage"
                startCoverage(job, "finalCoverage", time)
                return
            end
            s.active = node
            while (s.direction or 1) <= #directions do
                if probes >= C.PathProbesPerStep then return end
                local index = s.direction or 1
                local d = directions[index]
                s.direction = index + 1
                local x,y,z = node.x+d[1],node.y+d[2],node.z+d[3]
                local k = key(x,y,z)
                local b = job.policy.bounds
                if not s.seen[k] and x >= b.minX - C.ActivationDistance and x <= b.maxX + C.ActivationDistance
                    and y >= b.minY - C.ActivationDistance and y <= b.maxY + C.ActivationDistance
                    and math.abs(z-job.policy.z) <= 2
                    and (index ~= 5 or square:HasStairTopNorth())
                    and (index ~= 6 or square:HasStairTopWest()) then
                    probes = probes + 1
                    local adjacent = squareAt(cell,x,y,z)
                    if edge(square, adjacent) then
                        if s.size >= C.MaxPathNodes then nextCandidate(job, time); return end
                        local added = {x=x,y=y,z=z,parent=node,
                            score=math.abs(x-s.tx)+math.abs(y-s.ty)+4*math.abs(z-s.tz)}
                        s.size = s.size + 1
                        s.seen[k] = true
                        push(s,added)
                    end
                end
            end
        end
        s.active, s.direction = nil, nil
        s.expanded = s.expanded + 1
    end
end

local function validatePath(job, cell, time)
    for _ = 1, C.PathNodesPerStep do
        local node = job.path
        local square = squareAt(cell,node.x,node.y,node.z)
        if not walkable(square, false) then nextCandidate(job,time); return end
        if node.parent and not edge(square, squareAt(cell,node.parent.x,node.parent.y,node.parent.z)) then
            nextCandidate(job,time); return
        end
        job.validated[key(node.x,node.y,node.z)] = true
        job.path = node.parent
        if not job.path then
            job.search = nil
            job.safetyIndex, job.phase = 0, "playerSafety"
            return
        end
    end
end

local function startCensus(job, cell)
    job.census, job.scan, job.count = cell:getZombieList():size(), 0, 0
    job.phase = "census"
end

local function census(job, cell, time)
    local list, b = cell:getZombieList(), job.policy.bounds
    if list:size() ~= job.census then suspend(job,time,"zombie list changed"); return end
    for _ = 1, C.ZombiesPerStep do
        if job.scan >= job.census then
            if job.count >= job.policy.target then
                if not job.policy.respawn then saved.regions[job.id].completed = true end
                suspend(job,time,"target met"); return
            end
            if job.finalCensus then
                job.safetyIndex, job.phase = 0, "playerSafety"
                job.safetyStart, job.safetyCount = nil, nil
                return
            end
            job.attempts = 0
            nextCandidate(job,time)
            return
        end
        local zombie = list:get(job.scan)
        job.scan = job.scan + 1
        if zombie and not zombie:isDead() and math.floor(zombie:getZ()) == job.policy.z
            and contains(b,zombie:getX(),zombie:getY()) then job.count = job.count + 1 end
    end
end

local function spawn(job, cell, p, time)
    if time - job.coverageAt > C.CoverageMaxAgeMs
        or not job.validated[key(math.floor(p:getX()),math.floor(p:getY()),math.floor(p:getZ()))] then
        suspend(job,time,"coverage or walking anchor expired"); return
    end
    local c, z = job.candidate, job.policy.z
    local dx,dy = p:getX()-c.x,p:getY()-c.y
    if dx*dx+dy*dy < C.MinPlayerDistance*C.MinPlayerDistance then nextCandidate(job,time); return end
    local square = squareAt(cell,c.x,c.y,z)
    if not cell:getChunkForGridSquare(c.x,c.y,z) or not spawnable(square)
        or SafeHouse.isSafeHouse(square,nil,false) then nextCandidate(job,time); return end
    local data = saved.regions[job.id]
    if data.issued >= job.policy.budget or (not job.policy.respawn and data.completed) then
        suspend(job,time,"budget exhausted"); return
    end
    if time - lastSpawn < C.SpawnSpacingMs then
        job.safetyStart, job.safetyIndex = nil, 0
        return
    end
    local result = addZombiesInOutfit(c.x,c.y,z,1,nil,nil)
    local added = result and result:size() or 0
    data.issued = data.issued + added
    lastSpawn = time
    if added > 0 then
        data.completed = data.issued >= job.policy.target
        data.nextAt = time + job.policy.interval
        RegionManager.Log("Population", job.id .. ": added " .. added .. ", observed " .. job.count
            .. "/" .. job.policy.target .. ", issued " .. data.issued .. "/" .. job.policy.budget)
    end
    suspend(job,time,added > 0 and "added" or "spawn rejected")
    job.nextAt = time + job.policy.interval
end

local function step(job, cell, time)
    if time < job.nextAt then return end
    if job.phase == "idle" then
        local data = saved.regions[job.id]
        if data.issued >= job.policy.budget or (not job.policy.respawn and data.completed)
            or (data.nextAt or 0) > time then return end
        job.phase, job.playerIndex, job.playerId, job.started = "players", 0, nil, time
    end
    if job.phase == "players" then
        local players = getOnlinePlayers()
        for _ = 1, C.PlayersPerStep do
            if job.playerIndex >= players:size() then
                if job.playerId then startCoverage(job,"coverage",time)
                else suspend(job,time,"no relevant player") end
                return
            end
            local p = players:get(job.playerIndex)
            job.playerIndex = job.playerIndex + 1
            if p and not p:isDead() and p:getSquare() and math.abs(math.floor(p:getZ())-job.policy.z) <= 2
                and near(job.policy.bounds,p:getX(),p:getY(),C.ActivationDistance) then
                job.playerId = p:getOnlineID()
            end
        end
        return
    end
    local p = playerFor(job)
    if not p then suspend(job,time,"player left"); return end
    if time - job.started > C.CycleMaxAgeMs then suspend(job,time,"cycle expired during " .. job.phase); return end
    if job.phase == "coverage" then
        if coverage(job,cell,time) then job.phase, job.settleUntil = "settling", time + C.SettleMs end
    elseif job.phase == "settling" then
        if time >= job.settleUntil then startCoverage(job,"confirmedCoverage",time) end
    elseif job.phase == "confirmedCoverage" then
        if coverage(job,cell,time) then
            RegionManager.Log("Population", job.id .. ": full coverage confirmed; starting census, target=" .. job.policy.target)
            job.finalCensus = false; startCensus(job,cell)
        end
    elseif job.phase == "census" then census(job,cell,time)
    elseif job.phase == "candidate" then nextCandidate(job,time)
    elseif job.phase == "exclusions" then
        for _ = 1, C.ZonesPerStep do
            local id, zone = job.exclusionCursor()
            if not id then
                local c = job.candidate
                local square = squareAt(cell,c.x,c.y,job.policy.z)
                local dx,dy = p:getX()-c.x,p:getY()-c.y
                if not spawnable(square) or SafeHouse.isSafeHouse(square,nil,false)
                    or dx*dx+dy*dy < C.MinPlayerDistance*C.MinPlayerDistance then nextCandidate(job,time)
                else startSearch(job,p,time) end
                return
            end
            if tostring(id) ~= job.id and excluded(zone,job.candidate.x,job.candidate.y,job.policy.z,job.id) then
                nextCandidate(job,time); return
            end
        end
    elseif job.phase == "search" then search(job,cell,p,time)
    elseif job.phase == "finalCoverage" then
        if coverage(job,cell,time) then job.phase = "validatePath" end
    elseif job.phase == "validatePath" then
        validatePath(job,cell,time)
        if job.phase == "playerSafety" then job.finalCensus = true; startCensus(job,cell) end
    elseif job.phase == "playerSafety" then
        local players = getOnlinePlayers()
        if not job.safetyStart then job.safetyStart, job.safetyCount = time, players:size() end
        if job.safetyCount ~= players:size() or time - job.safetyStart > C.PlayerSafetyMaxAgeMs then
            job.safetyStart, job.safetyIndex = nil, 0
            return
        end
        for _ = 1, C.PlayersPerStep do
            if job.safetyIndex >= players:size() then spawn(job,cell,p,time); return end
            local other = players:get(job.safetyIndex)
            job.safetyIndex = job.safetyIndex + 1
            if other and not other:isDead() then
                local dx,dy = other:getX()-job.candidate.x, other:getY()-job.candidate.y
                if dx*dx+dy*dy < C.MinPlayerDistance*C.MinPlayerDistance then nextCandidate(job,time); return end
            end
        end
    end
end

function Population.Tick()
    if not C or C.Enabled == false then return end
    local current = RegionManager.Server and RegionManager.Server.registeredZones
    if not current then return end
    if registry ~= current then
        registry, jobs, cursor, discovery, discovering = current, {}, 0, tableCursor(current), true
    end
    if not saved then
        saved = ModData.getOrCreate("RegionManager_Population")
        saved.regions = saved.regions or {}
        saved.water = saved.water or {}
        saved.waterCount = saved.waterCount or 0
    end
    -- Registration changes replace the table. Discover one entry per tick.
    if discovering then
        local id, zone = discovery()
        if not id then discovering = false
        else
            local resolved = policy(zone)
            if resolved then
                id = tostring(id)
                saved.regions[id] = saved.regions[id] or {issued=0,completed=false}
                jobs[#jobs+1] = {id=id,policy=resolved,phase="idle",nextAt=0}
                RegionManager.Log("Population", id .. ": registered, effectiveTarget=" .. resolved.target
                    .. ", budget=" .. resolved.budget .. ", issued=" .. saved.regions[id].issued
                    .. ", respawn=" .. tostring(resolved.respawn))
            end
        end
    end
    if #jobs == 0 then return end
    cursor = cursor % #jobs + 1
    local cell = getCell()
    if cell then step(jobs[cursor],cell,now()) end
end

-- Scalar diagnostics; never expose retained zombie/square references.
function Population.GetStatus(id)
    for _, job in ipairs(jobs) do
        if job.id == id then
            return {phase=job.phase,reason=job.reason,target=job.policy.target,
                issued=saved.regions[id].issued,budget=job.policy.budget,observed=job.count,
                cachedWaterTiles=saved.waterCount,searchNodes=job.search and job.search.size,
                expandedNodes=job.search and job.search.expanded}
        end
    end
end

-- Explicit maintenance escape hatch if an admin changes formerly-water terrain.
function Population.ClearWaterCache()
    if saved then saved.water, saved.waterCount = {}, 0 end
end

Events.OnTick.Add(Population.Tick)
