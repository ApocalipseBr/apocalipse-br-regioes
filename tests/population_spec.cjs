const fs = require('node:fs');
const path = require('node:path');

module.exports = function(mod, run) {
    const root = path.join(mod, '42.18/media/lua');
    const config = fs.readFileSync(path.join(root, 'shared/RegionManager_Config.lua'), 'utf8');
    const source = fs.readFileSync(path.join(root, 'server/RegionManager_Population.lua'), 'utf8');
    const fixture = `
        -- Match PZ Kahlua: pairs exists, global next does not.
        next=nil
        isServer=function() return true end
        require=function() end
        local function loadConfig() ${config} end
        loadConfig()
        local logs={}
        RegionManager.Log=function(_,message) logs[#logs+1]=message end
        local C=RegionManager.Config.Population
        C.SettleMs=20; C.RetryMs=20; C.IntervalSeconds=1; C.SpawnSpacingMs=0
        local clock, loaded, missing, water, wall, safehouse, occupied = 0,true,false,false,false,false,false
        local clockStep=10
        local stairs, nofloor, vehicle, collision = false,false,false,false
        local door, window, fence = false,false,false
        local worldSquares, waterReads, squareReads, pathChecks = nil, {}, {}, 0
        local probes, reads, zombieReads, playerReads, spawned = 0,0,0,0,0
        local zombies, players, state = {}, {}, {}
        local squareCache, defaultTile = {}, {}
        instanceof=function(object,name) return name=='IsoZombie' and object.zombie==true end
        local function list(t, kind)
            return {size=function() return #t end,get=function(_,i)
                if kind=='zombie' then zombieReads=zombieReads+1 end
                if kind=='player' then playerReads=playerReads+1 end
                return t[i+1]
            end}
        end
        local function square(x,y,z)
            local coordinate=x..':'..y..':'..z
            local tile=worldSquares and worldSquares[coordinate]
            if not loaded or (worldSquares and not tile)
                or (not worldSquares and (z~=0 or y~=1 or x<0 or x>31)) then return nil end
            tile=tile or defaultTile
            local cached=squareCache[coordinate]
            if cached and cached.tile==tile then return cached end
            local result={
                tile=tile,
                getMovingObjects=function()
                    local localObjects={}
                    for _,object in ipairs(zombies) do
                        if not object.detached and math.floor(object:getX())==x and math.floor(object:getY())==y
                            and math.floor(object:getZ())==z then localObjects[#localObjects+1]=object end
                    end
                    return list(localObjects,'zombie')
                end,
                isWaterSquare=function()
                    waterReads[coordinate]=(waterReads[coordinate] or 0)+1
                    return tile.water or (water and x==14)
                end,
                TreatAsSolidFloor=function() return not nofloor end,
                HasStairs=function() return stairs or tile.north or tile.west end,
                HasStairTopNorth=function() return tile.north==true end,
                HasStairTopWest=function() return tile.west==true end,
                isVehicleIntersecting=function() return vehicle end,
                isFree=function(_,countOthers) return not (countOthers and occupied and x==14) end,
                isBlockedTo=function(_,other) return wall and (x==7 or other.x==7) end,
                isHoppableTo=function() return false end,isWindowTo=function() return false end,
                testCollideAdjacentAdvanced=function() return collision end,
                testPathFindAdjacent=function(_,mover,dx,dy,dz)
                    pathChecks=pathChecks+1
                    if collision then return true end
                    local nextSquare=square(x+dx,y+dy,z+dz)
                    if not nextSquare then return true end
                    if dz~=0 then
                        local lower=dz>0 and tile or worldSquares and worldSquares[(x+dx)..':'..(y+dy)..':'..(z+dz)] or {}
                        return not ((lower.north and dx==0 and dy==-dz)
                            or (lower.west and dx==-dz and dy==0))
                    end
                    if tile.north and dy<0 or tile.west and dx<0 then return true end
                    return wall and (x==7 or x+dx==7) and not (door or window or fence)
                end,
                getX=function() return x end,getY=function() return y end,getZ=function() return z end,
                x=x,y=y,z=z
            }
            squareCache[coordinate]=result
            return result
        end
        local cell={
            getChunkForGridSquare=function(_,x,y,z)
                probes=probes+1
                if loaded and not (missing and x==8 and y==8) then return {} end
            end,
            getGridSquare=function(_,x,y,z)
                reads=reads+1
                local coordinate=x..':'..y..':'..z
                squareReads[coordinate]=(squareReads[coordinate] or 0)+1
                return square(x,y,z)
            end,
            getZombieList=function() error('population must never scan the global zombie list') end
        }
        local function player(id,x,y,z)
            local p={id=id,x=x,y=y,z=z,dead=false}
            function p:getOnlineID() return self.id end
            function p:getX() return self.x end
            function p:getY() return self.y end
            function p:getZ() return self.z end
            function p:isDead() return self.dead end
            function p:getSquare() return square(self.x,self.y,self.z) end
            return p
        end
        players[1]=player(1,1,1,0)
        getOnlinePlayers=function() return list(players,'player') end
        getPlayerByOnlineID=function(id) for _,p in ipairs(players) do if p.id==id then return p end end end
        getCell=function() return cell end
        getTimestampMs=function() return clock end
        SafeHouse={isSafeHouse=function(sq) return safehouse and sq and sq.x==14 and {} or nil end}
        ModData={getOrCreate=function() return state end}
        local randomCoordinate=0
        ZombRand=function(a,b)
            if not b then return 0 end
            if b==32 then randomCoordinate=randomCoordinate+1; return randomCoordinate%2==1 and 14 or 1 end
            return a
        end
        local zombieId=0
        local function zombie(x,y,z)
            zombieId=zombieId+1
            local object={zombie=true,x=x,y=y,z=z,id=zombieId,outfit=zombieId,dead=false}
            function object:getX() return self.x end
            function object:getY() return self.y end
            function object:getZ() return self.z end
            function object:getOnlineID() return self.id end
            function object:getPersistentOutfitID() return self.outfit end
            function object:isDead() return self.dead end
            function object:getCurrentSquare()
                if self.detached then return nil end
                for _,live in ipairs(zombies) do
                    if live==self then return square(math.floor(self.x),math.floor(self.y),math.floor(self.z)) end
                end
                return nil
            end
            return object
        end
        addZombiesInOutfit=function(x,y,z,count)
            assert(count==1 and z==0 and x==14 and y==1)
            spawned=spawned+1
            local added=zombie(x,y,z); zombies[#zombies+1]=added
            return list({added})
        end
        local function zone(id,props)
            return {region={id=id,z=0},bounds={minX=0,minY=0,maxX=31,maxY=31},properties=props}
        end
        RegionManager.Server={registeredZones={test=zone('test',{
            zombiePopulationTarget=2,zombiePopulationMaxDensity=2,zombiePopulationBudget=4,zombieRespawn=true
        })}}
        local tick,deathHandler
        Events={OnTick={Add=function(fn) tick=fn end},OnZombieDead={Add=function(fn) deathHandler=fn end}}
        local function loadModule() ${source} end
        loadModule()
        local function ticks(n)
            for i=1,n do
                probes,reads,zombieReads,playerReads,pathChecks=0,0,0,0,0
                clock=clock+clockStep
                tick()
                assert(probes<=C.ChunkProbesPerStep+1,'unbounded chunk work')
                assert(zombieReads<=math.max(C.CensusObjectsPerStep,C.MaintenanceObjectsPerStep,1),'unbounded census')
                assert(playerReads<=C.PlayersPerStep,'unbounded player scan')
                assert(reads<=math.max(C.CensusSquaresPerStep,C.MaintenanceSquaresPerStep,C.MembersPerStep,C.PathNodesPerStep+C.PathProbesPerStep,C.PathNodesPerStep*2)+2,'unbounded square work')
                assert(pathChecks<=2*math.max(C.PathProbesPerStep,C.PathNodesPerStep),'unbounded edge work')
            end
        end
    `;
    run(fixture + `
        local z=zombie(1,1,0)
        zombies={z,z,zombie(2,1,0),zombie(3,1,0)}
        RegionManager.Server.registeredZones.test.properties.zombiePopulationBudget=0
        ticks(2500)
        assert(RegionManager.Population.GetStatus('test').observed==3,
            'set must count unique references, including population above target')
        z.dead=true; deathHandler(z); deathHandler(z)
        ticks(1)
        assert(RegionManager.Population.GetStatus('test').observed==2,'duplicate death events must remove only one member')
        zombies[3].dead=true; zombies[4].dead=true
        deathHandler(zombies[3]); deathHandler(zombies[4]); ticks(2)
        assert(RegionManager.Population.GetStatus('test').observed==0,'swap removals must keep membership indices correct')
        assert(spawned==0)
    `, 'population deduplicates references and removes deaths from the maintained set');

    run(fixture + `
        local z=zombie(1,1,0); zombies={z}
        C.CensusSquaresPerStep=1
        RegionManager.Server.registeredZones.test.properties.zombiePopulationBudget=0
        local moved=false
        for i=1,1500 do
            ticks(1)
            local status=RegionManager.Population.GetStatus('test')
            if status.observed==1 and not moved then z.x=14; moved=true end
            if status.ready then break end
        end
        assert(moved and RegionManager.Population.GetStatus('test').ready)
        assert(RegionManager.Population.GetStatus('test').observed==1,'moving ahead of the scan must not count twice')
    `, 'population deduplicates zombies moving between scan squares');

    run(fixture + `
        local z=zombie(1,1,0); zombies={z}
        RegionManager.Server.registeredZones.test.properties.zombiePopulationBudget=0
        ticks(200); assert(RegionManager.Population.GetStatus('test').observed==1)
        z.x=100; ticks(60)
        assert(RegionManager.Population.GetStatus('test').observed==0,'departures must be pruned')
        z.x=1; ticks(2000)
        assert(RegionManager.Population.GetStatus('test').observed==1,'rolling scan must discover returning zombies')
        z.detached=true; z.id=z.id+100; z.outfit=z.outfit+100; ticks(60)
        assert(RegionManager.Population.GetStatus('test').observed==0,'detached/recycled references must be removed')
        z.detached=false; ticks(2000)
        assert(RegionManager.Population.GetStatus('test').observed==1,'reused live object can be discovered again')
        z.dead=true; ticks(60)
        assert(RegionManager.Population.GetStatus('test').observed==0,'pruning handles missing death callbacks')
    `, 'population prunes departures, detached incarnations and missed deaths');

    run(fixture + `
        zombies={zombie(1,1,0)}
        RegionManager.Server.registeredZones.test.properties.zombiePopulationBudget=0
        ticks(200)
        for i=1,200 do
            ticks(1)
            assert(reads<=math.max(C.MaintenanceSquaresPerStep,C.MembersPerStep),'maintenance must use slower square budget')
            assert(zombieReads<=C.MaintenanceObjectsPerStep,'maintenance must use slower object budget')
        end
        loaded=false; ticks(100)
        local status=RegionManager.Population.GetStatus('test')
        assert(not status.ready and status.observed==0,'unloading must discard the reference set')
        loaded=true; ticks(200)
        status=RegionManager.Population.GetStatus('test')
        assert(status.ready and status.observed==1,'reloading must initialize a fresh set')
        C.Enabled=false; ticks(1)
        assert(RegionManager.Population.GetStatus('test')==nil,'disable must release runtime ledgers')
    `, 'population throttles maintenance and clears ledgers on unload or disable');

    run(fixture + `
        C.DeathMembershipsPerTick=0; C.MembersPerStep=0
        local z=zombie(1,1,0); zombies={z}
        RegionManager.Server.registeredZones.test.properties.zombiePopulationBudget=0
        ticks(200)
        z.dead=true; deathHandler(z)
        z.dead=false; z.id=z.id+100; z.outfit=z.outfit+100
        ticks(2000)
        C.DeathMembershipsPerTick=8; ticks(2)
        assert(RegionManager.Population.GetStatus('test').observed==1,
            'delayed death from an old incarnation must not remove a newly observed one')
    `, 'population distinguishes reincarnations in delayed death processing');

    run(fixture + `
        C.DeathMembershipsPerTick=1; C.MembersPerStep=0
        local z=zombie(1,1,0); zombies={z}
        RegionManager.Server.registeredZones={}
        for i=1,12 do
            local id='overlap'..i
            RegionManager.Server.registeredZones[id]=zone(id,{zombiePopulationTarget=1,zombiePopulationBudget=0})
        end
        ticks(2000)
        for i=1,12 do assert(RegionManager.Population.GetStatus('overlap'..i).observed==1) end
        z.dead=true; deathHandler(z); deathHandler(z); ticks(1)
        local total=0
        for i=1,12 do total=total+RegionManager.Population.GetStatus('overlap'..i).observed end
        assert(total==11,'one death must process at most one overlapping membership per tick')
        ticks(30)
        for i=1,12 do assert(RegionManager.Population.GetStatus('overlap'..i).observed==0) end
    `, 'population bounds death processing across overlapping regions');

    run(fixture + `
        C.CensusSquaresPerStep=1; C.CensusObjectsPerStep=1
        C.MaintenanceSquaresPerStep=1; C.MaintenanceObjectsPerStep=1
        RegionManager.Server.registeredZones.test.properties.zombiePopulationBudget=0
        for i=1,140 do
            local object=zombie(1,1,0); object.zombie=false
            zombies[#zombies+1]=object
        end
        zombies[#zombies+1]=zombie(1,1,0)
        zombies[#zombies+1]=zombie(1,1,0)
        ticks(2000)
        assert(RegionManager.Population.GetStatus('test').observed==2,
            'crowded tile must resume until real zombies are counted')
    `, 'population bounds crowded moving-object scans and ignores non-zombies');

    run(fixture + `
        C.CensusSquaresPerStep=1
        local began=false
        for i=1,1800 do
            ticks(1)
            local status=RegionManager.Population.GetStatus('test')
            if status and status.censusTiles and not status.ready then
                began=true
                -- Unrelated loaded-world activity changes list size every turn.
                zombies[#zombies+1]=zombie(1000+i,1000,0)
            end
        end
        assert(began and spawned==2,'unrelated zombie churn must not abort local counting')
        local progress,complete=false,false
        for _,message in ipairs(logs) do
            if string.find(message,'population scan progress',1,true) then progress=true end
            if string.find(message,'initial population scan complete',1,true) then complete=true end
        end
        assert(progress and complete,'slow local counts need progress and completion diagnostics')
    `, 'population tolerates unrelated zombie-list changes');

    run(fixture + `
        C.CensusSquaresPerStep=1; clockStep=100
        local finished=false
        for i=1,3000 do
            ticks(1)
            local status=RegionManager.Population.GetStatus('test')
            assert(not status or status.reason~='cycle expired during census')
            if status and status.ready then finished=true; break end
        end
        assert(finished and clock>30000,'large census must make bounded progress without the placement deadline')
    `, 'population allows a large incremental census to finish');

    run(fixture + `
        local zone=RegionManager.Server.registeredZones.test
        zone.bounds={minX=5,maxX=10,minY=1,maxY=2}
        zone.properties.zombiePopulationTarget=1
        zone.properties.zombiePopulationMaxDensity=10
        zone.properties.zombieRespawn=false
        zombies={zombie(10.5,1,0),zombie(4,1,0),zombie(10,1,1)}
        ticks(500)
        assert(spawned==0 and RegionManager.Population.GetStatus('test').observed==1,
            'clipped chunks must count inclusive edges on the configured floor')
    `, 'population scans clipped regional chunk footprints');

    run(fixture + `
        -- Also accept an iterator-only pairs implementation, as used by Kahlua.
        local standardPairs=pairs
        pairs=function(values)
            local iterator,state,control=standardPairs(values)
            return function()
                local id,value=iterator(state,control)
                control=id
                return id,value
            end
        end
        ticks(1000)
        assert(spawned==2,'resumable cursors must support iterator-only pairs')
    `, 'population Kahlua-style iteration without global next');

    run(fixture + `
        ticks(1000)
        assert(spawned==2,'configured region target should stop additions')
        assert(RegionManager.Population.GetStatus('test').target==2)
        assert(state.regions.test.issued==2)
        zombies={}; ticks(1000)
        assert(spawned==4 and state.regions.test.issued==4,'respawn must stop at persisted allowance')
        zombies={}; loadModule(); ticks(1000)
        assert(spawned==4,'restart must preserve allowance')
    `, 'population density, bounded work, replenishment and persistence');

    run(fixture + `
        C.CensusSquaresPerStep=1
        ticks(480)
        local status=RegionManager.Population.GetStatus('test')
        assert(spawned>0 and not status.ready and status.censusTiles>0,
            'placement must succeed while the initial census is still scanning')
        local before=status.censusTiles
        players[1].x=1000
        ticks(100)
        assert(RegionManager.Population.GetStatus('test').censusTiles>before,
            'the initial census must continue after the player leaves')
    `, 'population spawns during the initial census');

    run(fixture + `
        local region=RegionManager.Server.registeredZones.test
        worldSquares={}
        for x=0,31 do worldSquares[x..':1:0']={} end
        worldSquares['19:9:0']={}; worldSquares['19:10:0']={}; worldSquares['20:1:0']={}
        region.properties.zombiePopulationTarget=4
        region.properties.zombiePopulationMaxDensity=0.2
        C.CensusSquaresPerStep=1
        zombies={zombie(19,9,0),zombie(20,1,0),zombie(14,1,1)}
        ticks(500)
        assert(spawned==0,'a same-floor zombie in the candidate block must block the addition')
        assert(not RegionManager.Population.GetStatus('test').ready)
        zombies[1].y=10
        ticks(500)
        assert(spawned==1,'the next block and other floors must not consume local density')
        assert(RegionManager.Population.GetStatus('test').target==4,
            'local density must not scale down the configured region target')
    `, 'population limits additions per 10-by-10 block before census completion');

    for (const [name, setup] of [
        ['unloaded interior chunk', 'missing=true'],
        ['water', 'water=true'],
        ['occupied square', 'occupied=true'],
        ['safehouse', 'safehouse=true'],
        ['stairs', 'stairs=true'],
        ['missing floor', 'nofloor=true'],
        ['vehicle obstruction', 'vehicle=true'],
        ['collision matrix', 'collision=true'],
        ['disconnected walking area', 'wall=true'],
        ['more than two floors away', 'players[1].z=3'],
        ['no stairs to other floor', 'players[1].z=1'],
        ['nearby second player', 'players[2]=player(2,14,1,0)'],
        ['noZombies overlap', `RegionManager.Server.registeredZones.excluded=zone('excluded',{noZombies=true})`],
        ['disabled module', 'C.Enabled=false'],
        ['density zero', 'RegionManager.Server.registeredZones.test.properties.zombiePopulationMaxDensity=0'],
        ['no explicit target', 'RegionManager.Server.registeredZones.test.properties.zombiePopulationTarget=nil']
    ]) {
        run(fixture + `${setup}; ticks(700); assert(spawned==0, '${name}')`, `population rejects ${name}`);
    }

    run(fixture + `
        missing=true; ticks(50); assert(spawned==0)
        missing=false; ticks(500); assert(spawned>0)
        zombies={}; loaded=false; ticks(1000)
        local before=spawned
        assert(before<=2,'unload must stop topups')
        loaded=true; players[1].x=1000; ticks(1000)
        assert(spawned==before,'departure must stop topups')
        players[1].x=1; ticks(1000)
        assert(spawned>before,'return should resume within remaining allowance')
        RegionManager.Server.registeredZones={}; zombies={}; before=spawned; ticks(1000)
        assert(spawned==before,'deleted region must cancel all queued work')
    `, 'population activation, unload, departure, return and hot reload');

    run(fixture + `
        RegionManager.Server.registeredZones.test.properties.zombieRespawn=false
        zombies={zombie(1,1,0),zombie(2,1,0)}
        ticks(500); assert(spawned==0 and state.regions.test.completed)
        zombies={}; ticks(1000); assert(spawned==0,'no replenishment after first target completion')
    `, 'population non-respawning encounters');

    run(fixture + `
        RegionManager.Server.registeredZones.a=zone('a',{
            zombiePopulationTarget=2,zombiePopulationMaxDensity=2,zombiePopulationBudget=2})
        ticks(1000)
        assert(spawned==2)
        assert(state.regions.test.issued==0,'overlap must have a single deterministic spawn owner')
    `, 'population overlap ownership');

    run(fixture + `
        C.ChunkProbesPerStep=1
        for i=1,500 do
            ticks(1)
            local status=RegionManager.Population.GetStatus('test')
            if status and status.phase=='search' then players[1].x=1000; break end
        end
        ticks(1000); assert(spawned==0,'departure during queued work must cancel spawning')
    `, 'population invalidates in-progress work');

    run(fixture + `
        for i=1,500 do
            ticks(1)
            local status=RegionManager.Population.GetStatus('test')
            if status and status.phase=='search' then
                zombies={zombie(1,1,0),zombie(2,1,0)}
                break
            end
        end
        ticks(2000); assert(spawned<=1,'rolling ledger must eventually observe arrivals')
    `, 'population discovers arrivals through ongoing regional bookkeeping');

    run(fixture + `
        for i=1,500 do
            ticks(1)
            local status=RegionManager.Population.GetStatus('test')
            if status and status.phase=='search' then missing=true; break end
        end
        ticks(1000)
        local status=RegionManager.Population.GetStatus('test')
        assert(not status.ready and status.observed==0,'unload detection must clear the ledger')
        local before=spawned; ticks(500); assert(spawned==before,'no additions after unload detection')
    `, 'population watches regional coverage independently of spawning');

    run(fixture + `
        C.ChunkProbesPerStep=1
        clockStep=1000
        ticks(1000); assert(spawned>0,'slow bounded coverage must finish without a timeout')
    `, 'population completes coverage without elapsed-time deadlines');

    for (const kind of ['door', 'window', 'fence']) {
        run(fixture + `
            wall=true; ${kind}=true
            ticks(500)
            assert(spawned==2,'pathable ${kind} must not block the route')
        `, `population traverses closed ${kind} edges`);
    }

    for (const direction of ['north', 'west']) {
        for (const descending of [false, true]) {
            const points = direction === 'north'
                ? `for x=7,14 do worldSquares[x..':1:0']={} end
                   worldSquares['7:1:0']={north=true}
                   for x=1,7 do worldSquares[x..':0:1']={} end
                   worldSquares['1:1:1']={}`
                : `for x=7,14 do worldSquares[x..':1:0']={} end
                   worldSquares['7:1:0']={west=true}
                   for x=1,6 do worldSquares[x..':1:1']={} end`;
            run(fixture + `
                worldSquares={}
                ${points}
                players[1].z=1
                ${descending ? `
                    -- Reverse the route: spawn on the upper landing's floor.
                    local reversed={}
                    for coordinate,tile in pairs(worldSquares) do
                        local x,y,z=string.match(coordinate,'(%d+):(%d+):(%d+)')
                        reversed[x..':'..y..':'..(tonumber(z)-1)]=tile
                    end
                    worldSquares=reversed
                    players[1].x=14; players[1].z=-1
                    ZombRand=function(a,b)
                        if not b then return 0 end
                        if b==32 then return 1 end
                        return a
                    end
                    addZombiesInOutfit=function(x,y,z,count)
                        assert(x==1 and y==1 and z==0 and count==1)
                        spawned=spawned+1
                        local added=zombie(x,y,z); zombies[#zombies+1]=added
                        return list({added})
                    end
                ` : ''}
                ticks(1000)
                assert(spawned==2,'must follow actual ${direction} stairs ${descending ? 'down' : 'up'}')
            `, `population traverses ${direction} stairs ${descending ? 'down' : 'up'}`);
        }
    }

    run(fixture + `
        worldSquares={}
        for x=0,31 do for y=0,31 do worldSquares[x..':'..y..':0']={} end end
        players[1].x=31; players[1].y=31
        clockStep=100; C.SettleMs=3000
        ticks(240)
        assert(spawned>0,'directed search must reach a distant player at ten ticks/sec')
    `, 'population directed search avoids breadth-first flooding at real server cadence');

    run(fixture + `
        C.PathProbesPerStep=1
        ticks(3000)
        assert(spawned==2,'neighbor cursor must resume with a one-probe budget')
    `, 'population resumes partially expanded nodes within the probe budget');

    run(fixture + `
        water=true; ticks(700)
        assert(spawned==0 and waterReads['14:1:0']==1)
        assert(RegionManager.Population.GetStatus('test').cachedWaterTiles==1)
        local before=squareReads['14:1:0']
        loadModule(); ticks(700)
        assert(squareReads['14:1:0']==before,'water survives reload without square lookup')
        assert(waterReads['14:1:0']==1,'cached water must never be queried again')
        RegionManager.Population.ClearWaterCache()
        water=false; ticks(700)
        assert(spawned==2,'explicit cache clearing permits rebuilt terrain')
    `, 'population persists packed water exclusions and supports explicit terrain reset');

    run(fixture + `
        water=true; ticks(500)
        worldSquares={}
        for x=0,31 do worldSquares[x..':1:1']={} end
        RegionManager.Server.registeredZones={test=zone('test',{
            zombiePopulationTarget=2,zombiePopulationMaxDensity=2,zombiePopulationBudget=2})}
        RegionManager.Server.registeredZones.test.region.z=1
        players[1].z=1; water=false
        addZombiesInOutfit=function(x,y,z,count)
            assert(z==1 and x==14 and y==1)
            spawned=spawned+1
            local added=zombie(x,y,z); zombies[#zombies+1]=added
            return list({added})
        end
        ticks(700)
        assert(spawned==2,'cached water below must not poison another floor')
    `, 'population water cache includes floor coordinates');

    run(fixture + `
        worldSquares={['14:1:0']={water=true},['15:1:0']={water=true},['1:1:0']={}}
        local draws=0
        ZombRand=function(a,b)
            if not b then return 0 end
            if b==32 then
                draws=draws+1
                if draws%2==0 then return 1 end
                return draws%4==1 and 14 or 15
            end
            return a
        end
        ticks(1000)
        assert(spawned==0 and state.waterCount==2)
        assert(state.water['1:0:0'][2]==192,'row mask must retain both water bits')
        assert(waterReads['14:1:0']==1 and waterReads['15:1:0']==1)
        assert(squareReads['14:1:0']==1 and squareReads['15:1:0']==1)
    `, 'population water masks retain multiple tiles without repeat lookups');

    run(fixture + `
        C.MaxPathNodes=1
        ticks(700)
        assert(spawned==0,'node admission limit must defer instead of exceeding budget')
    `, 'population enforces the retained-node limit');

    run(fixture + `
        ticks(1000)
        local initial=0
        for _,message in ipairs(logs) do
            if string.find(message,'initial population scan complete',1,true) then initial=initial+1 end
        end
        assert(spawned==2 and initial==1,'successive additions must reuse the initialized set')
        assert(RegionManager.Population.GetStatus('test').ready)
    `, 'population reuses its set across spawn attempts');

    run(fixture + `
        for i=1,500 do
            ticks(1)
            local status=RegionManager.Population.GetStatus('test')
            if status and status.phase=='validatePath' then collision=true; break end
        end
        ticks(700)
        assert(spawned==0,'route must be rechecked after geometry changes')
    `, 'population revalidates live path geometry before spawning');
    console.log('Population coverage, density/count, placement, work budgets and persistence checks passed.');
};
