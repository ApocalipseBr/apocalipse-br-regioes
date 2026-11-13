-- Server-authoritative, bounded population additions. No chunk loading requests.
if not isServer() then return end
require "RegionManager_Config"

RegionManager.Population = {}
local Population = RegionManager.Population
local C = RegionManager.Config.Population
local jobs, registry, discovery, discovering, cursor = {}, nil, nil, false, 0
local saved, lastSpawn = nil, -math.huge
-- Neither side of this reverse index keeps a zombie or region alive. In
-- particular, its values must never contain entries that point back to zombies.
local memberships = setmetatable({}, {__mode="k"})
local deaths, deathHead, deathTail, deathQueued = {}, 1, 0, {}
local function resetRuntime()
    registry, jobs, cursor, discovery, discovering = nil, {}, 0, nil, false
    memberships = setmetatable({}, {__mode="k"})
    deaths, deathHead, deathTail, deathQueued = {}, 1, 0, {}
end
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
    job.playerId = nil
end

local function removeMember(job, zombie)
    local entry = job.positions[zombie]
    if not entry then return end
    local members, index = job.members, entry.index
    local last = members[#members]
    members[index] = last
    members[#members] = nil
    if index <= #members then last.index = index end
    job.positions[zombie] = nil
    local regions = memberships[zombie]
    if regions then regions[job] = nil end
    job.count = #members
end

local function remember(job, zombie)
    if not zombie or not instanceof(zombie,"IsoZombie") or zombie:isDead()
        or math.floor(zombie:getZ()) ~= job.policy.z
        or not contains(job.policy.bounds,zombie:getX(),zombie:getY()) then return end
    local entry = job.positions[zombie]
    if entry then
        entry.onlineId, entry.outfitId = zombie:getOnlineID(), zombie:getPersistentOutfitID()
    else
        entry = {zombie=zombie,index=#job.members+1,onlineId=zombie:getOnlineID(),outfitId=zombie:getPersistentOutfitID()}
        job.members[entry.index], job.positions[zombie] = entry, entry
    end
    local regions = memberships[zombie]
    if not regions then regions = setmetatable({}, {__mode="k"}); memberships[zombie] = regions end
    regions[job] = true
    job.count = #job.members
end

local function invalidate(job, time, reason)
    -- O(1) release. The reverse index uses weak keys on both levels, so it
    -- cannot retain this discarded set or its zombie references.
    job.members, job.positions, job.count = {}, {}, 0
    job.ready, job.census, job.watch = false, nil, nil
    job.pruneIndex, job.maintenance = 1, 0
    suspend(job,time,reason)
end

function Population.OnZombieDead(zombie)
    local regions = memberships[zombie]
    if not regions or deathQueued[zombie] then return end
    -- Detach the reverse set before traversing it: removals and later reuse of
    -- this zombie must not mutate a suspended Kahlua pairs iterator.
    memberships[zombie] = nil
    deathTail = deathTail + 1
    deaths[deathTail] = {zombie=zombie,cursor=tableCursor(regions),
        onlineId=zombie:getOnlineID(),outfitId=zombie:getPersistentOutfitID()}
    deathQueued[zombie] = true
end

local function drainDeaths()
    -- A death in many overlapping regions cannot cause an unbounded event loop.
    for _ = 1, C.DeathMembershipsPerTick do
        local event = deaths[deathHead]
        if not event then return end
        local job = event.cursor()
        if job then
            local entry = job.positions[event.zombie]
            if entry and entry.onlineId == event.onlineId and entry.outfitId == event.outfitId then
                removeMember(job,event.zombie)
            end
        else
            deathQueued[event.zombie], deaths[deathHead] = nil, nil
            deathHead = deathHead + 1
            if deathHead > deathTail then deaths, deathHead, deathTail = {}, 1, 0 end
        end
    end
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
    job.cx, job.cy, job.phase = job.cxMin, job.cyMin, phase
end

local function coverage(job, cell, time)
    for _ = 1, C.ChunkProbesPerStep do
        if not cell:getChunkForGridSquare(job.cx * 8, job.cy * 8, job.policy.z) then
            invalidate(job, time, "missing chunk")
            return false
        end
        job.cx = job.cx + 1
        if job.cx > job.cxMax then job.cx, job.cy = job.cxMin, job.cy + 1 end
        if job.cy > job.cyMax then
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
    job.search = {heap={node},seen={[key(node.x,node.y,node.z)]=true},size=1,
        tx=math.floor(p:getX()),ty=math.floor(p:getY()),tz=math.floor(p:getZ()),expanded=0}
    job.phase = "search"
end

local function search(job, cell, p, time)
    local s = job.search
    if math.floor(p:getX()) ~= s.tx
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
                job.path, job.validated, job.phase = node, {}, "validatePath"
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

local function startCensus(job, time)
    local b = job.policy.bounds
    -- The rolling square cursor retains no squares or lists. Only the region's
    -- deduplicated members array retains live zombie references.
    job.census = {cx=job.cxMin,cy=job.cyMin,x=b.minX,y=b.minY,index=0,tiles=0,started=time,lastLog=time}
    if not job.ready then
        job.phase = "census"
        job.lastLoggedReason = nil
        RegionManager.Log("Population", job.id .. ": starting initial population bookkeeping, target=" .. job.policy.target)
    end
end

local function census(job, cell, time)
    local scan, b = job.census, job.policy.bounds
    local tiles, objects, probes = 0, 0, 0
    local checkedX, checkedY
    if time-scan.lastLog >= 5000 then
        RegionManager.Log("Population", job.id .. ": population scan progress, tracked " .. #job.members
            .. "/" .. job.policy.target .. ", tiles=" .. scan.tiles .. ", elapsedMs=" .. (time-scan.started))
        scan.lastLog = time
    end
    local squareBudget = job.ready and C.MaintenanceSquaresPerStep or C.CensusSquaresPerStep
    local objectBudget = job.ready and C.MaintenanceObjectsPerStep or C.CensusObjectsPerStep
    while tiles < squareBudget do
        if scan.cy > job.cyMax then
            if not job.ready then
                RegionManager.Log("Population", job.id .. ": initial population scan complete, tracked " .. #job.members
                    .. "/" .. job.policy.target .. ", tiles=" .. scan.tiles .. ", elapsedMs=" .. (time-scan.started))
                job.ready, job.phase, job.nextAt = true, "idle", 0
            end
            startCensus(job,time)
            return
        end
        if checkedX ~= scan.cx or checkedY ~= scan.cy then
            if probes >= C.ChunkProbesPerStep then return end
            probes = probes + 1
            if not cell:getChunkForGridSquare(scan.cx*8,scan.cy*8,job.policy.z) then
                invalidate(job,time,"missing chunk"); return
            end
            checkedX, checkedY = scan.cx, scan.cy
        end
        local square = squareAt(cell,scan.x,scan.y,job.policy.z)
        local list = square and square:getMovingObjects()
        -- Freeze only this tile's upper index, so arrivals cannot keep extending
        -- a crowded tile forever. Shrinkage/movement is accepted approximation.
        if not scan.limit then scan.limit = list and list:size() or 0 end
        tiles = tiles + 1
        while list and scan.index < math.min(scan.limit,list:size()) do
            if objects >= objectBudget then return end
            local zombie = list:get(scan.index)
            scan.index = scan.index + 1
            objects = objects + 1
            remember(job,zombie)
        end
        scan.tiles, scan.index = scan.tiles + 1, 0
        scan.limit = nil
        scan.x = scan.x + 1
        if scan.x > math.min(b.maxX,scan.cx*8+7) then
            scan.x, scan.y = math.max(b.minX,scan.cx*8), scan.y+1
            if scan.y > math.min(b.maxY,scan.cy*8+7) then
                scan.cx = scan.cx + 1
                if scan.cx > job.cxMax then scan.cx, scan.cy = job.cxMin, scan.cy+1 end
                scan.x, scan.y = math.max(b.minX,scan.cx*8), math.max(b.minY,scan.cy*8)
            end
        end
    end
end

local function maintain(job, cell, time)
    job.maintenance = (job.maintenance or 0) % 3 + 1
    if job.maintenance == 1 then
        -- Independent rolling chunk watcher: it advances even while placement
        -- is idle, target is met, or the lifetime spawn allowance is exhausted.
        local w = job.watch or {cx=job.cxMin,cy=job.cyMin}
        job.watch = w
        for _ = 1, C.ChunkProbesPerStep do
            if not cell:getChunkForGridSquare(w.cx*8,w.cy*8,job.policy.z) then
                invalidate(job,time,"missing chunk"); return
            end
            w.cx = w.cx + 1
            if w.cx > job.cxMax then w.cx, w.cy = job.cxMin, w.cy+1 end
            if w.cy > job.cyMax then w.cx, w.cy = job.cxMin, job.cyMin; return end
        end
    elseif job.maintenance == 2 then
        for _ = 1, math.min(C.MembersPerStep,#job.members) do
            local index = job.pruneIndex or 1
            if index > #job.members then index = 1 end
            local entry = job.members[index]
            if not entry then return end
            local zombie = entry.zombie
            if entry.onlineId == -1 and zombie:getPersistentOutfitID() == entry.outfitId then
                entry.onlineId = zombie:getOnlineID()
            end
            local valid = not zombie:isDead() and zombie:getOnlineID() == entry.onlineId
                and zombie:getPersistentOutfitID() == entry.outfitId
                and math.floor(zombie:getZ()) == job.policy.z
                and contains(job.policy.bounds,zombie:getX(),zombie:getY())
            if valid then
                local square = zombie:getCurrentSquare()
                valid = square ~= nil and cell:getGridSquare(square:getX(),square:getY(),square:getZ()) == square
            end
            if valid then job.pruneIndex = index+1
            else removeMember(job,zombie); job.pruneIndex = index end
        end
    else
        census(job,cell,time)
    end
end

local function spawn(job, cell, p, time)
    if not job.ready then return end
    if #job.members >= job.policy.target then
        if not job.policy.respawn then saved.regions[job.id].completed = true end
        suspend(job,time,"target met"); return
    end
    if not job.validated[key(math.floor(p:getX()),math.floor(p:getY()),math.floor(p:getZ()))] then
        suspend(job,time,"walking anchor expired"); return
    end
    local c, z = job.candidate, job.policy.z
    local dx,dy = p:getX()-c.x,p:getY()-c.y
    if dx*dx+dy*dy < C.MinPlayerDistance*C.MinPlayerDistance then nextCandidate(job,time); return end
    local square = squareAt(cell,c.x,c.y,z)
    if not cell:getChunkForGridSquare(c.x,c.y,z) then invalidate(job,time,"missing chunk"); return end
    if not spawnable(square) or SafeHouse.isSafeHouse(square,nil,false) then nextCandidate(job,time); return end
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
    if added > 0 then remember(job,result:get(0)) end
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
        if job.ready and (data.issued >= job.policy.budget or (not job.policy.respawn and data.completed)
            or (data.nextAt or 0) > time) then return end
        job.phase, job.playerIndex, job.playerId = "players", 0, nil
    end
    if job.phase == "players" then
        local players = getOnlinePlayers()
        for _ = 1, C.PlayersPerStep do
            if job.playerIndex >= players:size() then
                if job.playerId then
                    if job.ready then
                        if #job.members >= job.policy.target then
                            if not job.policy.respawn then saved.regions[job.id].completed = true end
                            suspend(job,time,"target met")
                        else job.attempts = 0; nextCandidate(job,time) end
                    else startCoverage(job,"coverage",time) end
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
    if not p then invalidate(job,time,"player left"); return end
    if job.phase == "coverage" then
        if coverage(job,cell,time) then job.phase, job.settleUntil = "settling", time + C.SettleMs end
    elseif job.phase == "settling" then
        if time >= job.settleUntil then startCensus(job,time) end
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
    elseif job.phase == "validatePath" then
        validatePath(job,cell,time)
    elseif job.phase == "playerSafety" then
        local players = getOnlinePlayers()
        if not job.safetyStart then job.safetyStart, job.safetyCount = time, players:size() end
        if job.safetyCount ~= players:size() then
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
    if not C or C.Enabled == false then
        if registry then resetRuntime() end
        return
    end
    local current = RegionManager.Server and RegionManager.Server.registeredZones
    if not current then
        if registry then resetRuntime() end
        return
    end
    if registry ~= current then
        resetRuntime()
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
                jobs[#jobs+1] = {id=id,policy=resolved,phase="idle",nextAt=0,
                    members={},positions={},count=0,ready=false,pruneIndex=1}
                RegionManager.Log("Population", id .. ": registered, effectiveTarget=" .. resolved.target
                    .. ", budget=" .. resolved.budget .. ", issued=" .. saved.regions[id].issued
                    .. ", respawn=" .. tostring(resolved.respawn))
            end
        end
    end
    if #jobs == 0 then return end
    drainDeaths()
    cursor = cursor % #jobs + 1
    local cell = getCell()
    if cell then
        local job, time = jobs[cursor], now()
        if job.ready then
            job.monitorTurn = not job.monitorTurn
            if job.monitorTurn then maintain(job,cell,time); return end
        end
        step(job,cell,time)
    end
end

-- Scalar diagnostics; never expose retained zombie/square references.
function Population.GetStatus(id)
    for _, job in ipairs(jobs) do
        if job.id == id then
            return {phase=job.phase,reason=job.reason,target=job.policy.target,
                issued=saved.regions[id].issued,budget=job.policy.budget,observed=#job.members,
                ready=job.ready,maintenancePhase=job.maintenance,
                censusTiles=job.census and job.census.tiles,
                censusElapsedMs=job.census and (now()-job.census.started),
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
Events.OnZombieDead.Add(Population.OnZombieDead)
