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
        RegionManager.Log=function() end
        local C=RegionManager.Config.Population
        C.SettleMs=20; C.RetryMs=20; C.IntervalSeconds=1; C.SpawnSpacingMs=0
        C.CoverageMaxAgeMs=10000; C.CycleMaxAgeMs=30000
        local clock, loaded, missing, water, wall, safehouse, occupied = 0,true,false,false,false,false,false
        local clockStep=10
        local stairs, nofloor, vehicle, collision = false,false,false,false
        local door, window, fence = false,false,false
        local worldSquares, waterReads, squareReads, pathChecks = nil, {}, {}, 0
        local probes, reads, zombieReads, playerReads, spawned = 0,0,0,0,0
        local zombies, players, state = {}, {}, {}
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
            tile=tile or {}
            return {
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
            getZombieList=function() return list(zombies,'zombie') end
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
        local function zombie(x,y,z)
            return {getX=function() return x end,getY=function() return y end,getZ=function() return z end,isDead=function() return false end}
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
            zombiePopulationTarget=3,zombiePopulationMaxDensity=0.2,zombiePopulationBudget=4,zombieRespawn=true
        })}}
        local tick
        Events={OnTick={Add=function(fn) tick=fn end}}
        local function loadModule() ${source} end
        loadModule()
        local function ticks(n)
            for i=1,n do
                probes,reads,zombieReads,playerReads,pathChecks=0,0,0,0,0
                clock=clock+clockStep
                tick()
                assert(probes<=C.ChunkProbesPerStep+1,'unbounded chunk work')
                assert(zombieReads<=C.ZombiesPerStep,'unbounded census')
                assert(playerReads<=C.PlayersPerStep,'unbounded player scan')
                assert(reads<=math.max(C.PathNodesPerStep+C.PathProbesPerStep,C.PathNodesPerStep*2)+2,'unbounded square work')
                assert(pathChecks<=2*math.max(C.PathProbesPerStep,C.PathNodesPerStep),'unbounded edge work')
            end
        end
    `;
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
        assert(spawned==2,'density must clamp count target to floor(1024*0.2/100)')
        assert(RegionManager.Population.GetStatus('test').target==2)
        assert(state.regions.test.issued==2)
        zombies={}; ticks(1000)
        assert(spawned==4 and state.regions.test.issued==4,'respawn must stop at persisted allowance')
        zombies={}; loadModule(); ticks(1000)
        assert(spawned==4,'restart must preserve allowance')
    `, 'population density, bounded work, replenishment and persistence');

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
        RegionManager.Server.registeredZones.a=zone('a',{zombiePopulationTarget=2,zombiePopulationBudget=2})
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
        ticks(1000); assert(spawned==0,'final census must catch population arriving during search')
    `, 'population recounts before adding');

    run(fixture + `
        for i=1,500 do
            ticks(1)
            local status=RegionManager.Population.GetStatus('test')
            if status and status.phase=='search' then missing=true; break end
        end
        ticks(1000); assert(spawned==0,'final coverage must catch an unloaded interior chunk')
    `, 'population rechecks whole-region coverage before adding');

    run(fixture + `
        C.CoverageMaxAgeMs=5
        C.ChunkProbesPerStep=1
        ticks(1000); assert(spawned==0,'coverage exceeding its time budget must defer')
    `, 'population rejects stale multi-tick coverage');

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
        clockStep=100; C.SettleMs=3000; C.CoverageMaxAgeMs=5000
        ticks(120)
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
            zombiePopulationTarget=2,zombiePopulationBudget=2})}
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
        C.CycleMaxAgeMs=50; C.SettleMs=1000
        local sawTimeout=false
        for i=1,500 do
            ticks(1)
            local status=RegionManager.Population.GetStatus('test')
            if status and status.reason=='cycle expired during settling' then sawTimeout=true; break end
        end
        assert(sawTimeout,'timeout must identify its phase separately from player departure')
    `, 'population reports the expired phase');

    run(fixture + `
        for i=1,500 do
            ticks(1)
            local status=RegionManager.Population.GetStatus('test')
            if status and status.phase=='finalCoverage' then collision=true; break end
        end
        ticks(700)
        assert(spawned==0,'route must be rechecked after geometry changes')
    `, 'population revalidates live path geometry before spawning');
    console.log('Population coverage, density/count, placement, work budgets and persistence checks passed.');
};
