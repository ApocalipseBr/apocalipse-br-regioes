const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');
const YAML = require('yaml');
const mod = process.env.REGIONS_MOD || path.resolve(__dirname, '../Apocalipsebr-regions');

function run(source, name) {
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    const status = lauxlib.luaL_dostring(L, to_luastring(source));
    if (status !== lua.LUA_OK) throw new Error(`${name}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    lua.lua_close(L);
}

function files(dir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
        const full = path.join(dir, entry.name);
        return entry.isDirectory() ? files(full) : [full];
    });
}

for (const file of files(mod)) {
    if (file.endsWith('.json')) JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!file.endsWith('.lua')) continue;
    const L = lauxlib.luaL_newstate();
    const source = fs.readFileSync(file);
    const result = lauxlib.luaL_loadbuffer(L, source, source.length, to_luastring(file));
    if (result !== lua.LUA_OK) throw new Error(`${file}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    lua.lua_close(L);
}

for (const version of ['42.14', '42.18']) {
    const media = path.join(mod, version, 'media');
    const sandbox = fs.readFileSync(path.join(media, 'sandbox-options.txt'), 'utf8');
    const labels = JSON.parse(fs.readFileSync(path.join(media, 'lua/shared/Translate/EN/Sandbox.json'), 'utf8'));
    for (const [name, value] of [['AutomaticSafeZones', 'false'], ['EnforcePVP', 'true']]) {
        const block = sandbox.match(new RegExp(`option RegionManager\\.${name}\\s*\\{([^}]+)\\}`));
        assert.ok(block, name);
        assert.match(block[1], /type = boolean,/);
        assert.ok(block[1].includes(`default = ${value},`));
        assert.ok(labels[`Sandbox_RegionManager_${name}`]);
        assert.ok(labels[`Sandbox_RegionManager_${name}_tooltip`]);
    }
    const auto = fs.readFileSync(path.join(media, 'lua/server/RegionManager_AutoSafeZones.lua'), 'utf8');
    run(`
        isServer = function() return true end
        RegionManager = { Log = function() end, Config = { Categories = { PVP = { pvpEnabled = true } } } }
        local function loadModule()
            ${auto}
        end
        loadModule()
        local configured = {{id='pvp', enabled=true, categories={'PVP'}, x1=10,y1=10,x2=20,y2=20}}
        assert(#RegionManager.AutoSafeZones.generateSafeZones(configured) == 0)
        SandboxVars = { RegionManager = { AutomaticSafeZones = false } }
        local merged = RegionManager.AutoSafeZones.mergeWithConfigured(configured)
        assert(#merged == 1 and merged[1] == configured[1])
        SandboxVars.RegionManager.AutomaticSafeZones = true
        local zones = RegionManager.AutoSafeZones.generateSafeZones(configured)
        assert(#zones > 0)
        local function covered(x,y)
            for _,zone in ipairs(zones) do
                assert(zone.customProperties.pvpEnabled == false)
                if x >= zone.x1 and x <= zone.x2 and y >= zone.y1 and y <= zone.y2 then return true end
            end
            return false
        end
        assert(not covered(10,10) and not covered(20,20) and not covered(15,15))
        assert(covered(9,10) and covered(21,20) and covered(15,9) and covered(15,21))
        configured[1].customProperties = {pvpEnabled=false}
        zones = RegionManager.AutoSafeZones.generateSafeZones(configured)
        assert(covered(15,15))
        SandboxVars.RegionManager.AutomaticSafeZones = false
        assert(#RegionManager.AutoSafeZones.mergeWithConfigured(configured) == 1)
    `, `${version} automatic coverage`);

    const config = fs.readFileSync(path.join(media, 'lua/shared/RegionManager_Config.lua'), 'utf8');
    const server = fs.readFileSync(path.join(media, 'lua/server/RegionManager_Server.lua'), 'utf8');
    const traitsFile = path.join(media, 'lua/shared/RegionManager_ZombieTraits.lua');
    const traits = fs.existsSync(traitsFile) ? fs.readFileSync(traitsFile, 'utf8') : '';
    run(`
        isServer = function() return true end
        local function loadConfig() ${config} end
        loadConfig()
        local function loadAuto() ${auto} end
        loadAuto()
        RegionManager.Config.Regions = {
            {id='pvp',name='PvP',enabled=true,categories={'PVP'},x1=10,y1=10,x2=20,y2=20,z=0,customProperties={navigationChance=42,normalVisionChance=20}},
            {id='manual',name='Safe',enabled=true,categories={'SAFEZONE'},x1=40,y1=40,x2=45,y2=45,z=0},
            {id='neutral',name='Zombies',enabled=true,categories={'SPRINTERS'},x1=60,y1=60,x2=65,y2=65,z=0}
        }
        require = function(name)
            if name=='RegionManager_JSON' then return {encode=function() return '{}' end} end
        end
        local function loadTraits() ${traits} end
        loadTraits()
        getFileReader = function() return nil end
        getFileWriter = function() return {write=function() end,close=function() end} end
        local world={registerZone=function() return {} end,checkVehiclesZones=function() end}
        getWorld=function() return world end
        getGameTime=function() return {getWorldAgeHours=function() return 0 end} end
        local saved={}
        ModData={getOrCreate=function() return saved end,add=function() end}
        local native={}
        local function add(title,x1,y1,x2,y2)
            native[#native+1]={getTitle=function() return title end,x1=x1,y1=y1,x2=x2,y2=y2}
        end
        add('ExternalZone',0,0,1,1)
        NonPvpZone={
            getAllZones=function() return {size=function() return #native end,get=function(_,i) return native[i+1] end} end,
            addNonPvpZone=add,
            removeNonPvpZone=function(title)
                for i=#native,1,-1 do if native[i]:getTitle()==title then table.remove(native,i) end end
            end
        }
        local loadZones,clientCommand
        Events={
            OnServerStarted={Add=function() end},
            OnLoadMapZones={Add=function(fn) loadZones=fn end},
            OnClientCommand={Add=function(fn) clientCommand=fn end}
        }
        local function loadServer() ${server} end
        loadServer()
        SandboxVars={RegionManager={AutomaticSafeZones=true}}
        loadZones()
        assert(#saved.zones>3 and #native>2, 'enabled coverage: saved='..#saved.zones..' native='..#native)
        SandboxVars.RegionManager.AutomaticSafeZones=false
        loadZones()
        assert(#saved.zones==3 and #native==2, 'disabled coverage: saved='..#saved.zones..' native='..#native)
        assert(native[1]:getTitle()=='ExternalZone')
        assert(native[2]:getTitle()=='SafeZone_manual')
        assert(native[2].x2==46 and native[2].y2==46)
        local payload
        sendServerCommand=function(_,_,_,args) payload=args end
        clientCommand('RegionManager','RequestAllBoundaries',{getUsername=function() return 'test' end},{})
        assert(#payload.zones==3)
        for _,zone in ipairs(payload.zones) do
            if zone.id=='neutral' then assert(zone.pvpEnabled==nil) end
            if zone.id=='manual' then assert(zone.pvpEnabled==false) end
            if zone.id=='pvp' then assert(zone.pvpEnabled==true) end
            if zone.id=='pvp' and RegionManager.ZombieTraits then
                assert(zone.zombieTraits.navigationChance==42 and zone.zombieTraits.normalVisionChance==20)
            end
        end
    `, `${version} server registration and coverage cleanup`);

    const pvp = fs.readFileSync(path.join(media, 'lua/client/RegionManager_PVP.lua'), 'utf8');
    run(`
        isServer = function() return false end
        require = function() end
        local module
        RegionManager = { Log = function() end, ClientTick = { registerModule = function(m) module=m end } }
        Events = { OnGameStart = { Add = function(fn) fn() end } }
        local function loadModule()
            ${pvp}
        end
        loadModule()
        local enabled, cooldown, toggle, calls = true, 45, 0, 0
        local safety = {
            isEnabled=function() return enabled end,
            getToggle=function() return toggle end,
            setCooldown=function(_,v) cooldown=v; calls=calls+1 end,
            toggleSafety=function() enabled=not enabled; calls=calls+1 end
        }
        local player = { getSafety=function() return safety end }
        local zones = { pvp = {pvpEnabled=true} }
        SandboxVars = { RegionManager = { EnforcePVP=false } }
        module.onTick(player,zones)
        module.onTick(player,{})
        assert(calls==0 and cooldown==45 and enabled)
        SandboxVars.RegionManager.EnforcePVP=true
        module.onTick(player,zones)
        assert(calls==2 and cooldown==0 and not enabled)
        enabled=true; cooldown=45; calls=0
        module.onTick(player,{}) -- Exit must release the previous requirement.
        module.onTick(player,{neutral={}})
        assert(calls==0 and cooldown==45 and enabled)
        module.onTick(player,{pvp={pvpEnabled=true},safe={pvpEnabled=false}})
        assert(calls==0)
        module.onTick(player,{pvp={pvpEnabled=true},neutral={}})
        assert(calls==2 and not enabled)
        enabled=true; calls=0; toggle=10
        module.onTick(player,zones)
        assert(calls==0) -- Don't resend toggle packets while a transition is pending.
        toggle=0; SandboxVars=nil
        module.onTick(player,zones)
        assert(calls==2 and not enabled)
        enabled=true; calls=0
        SandboxVars={RegionManager={EnforcePVP=false}}
        module.onTick(player,zones)
        assert(calls==0) -- Runtime disabling leaves no cached enforcement behind.
    `, `${version} PvP enforcement`);
}

const traitsSource = fs.readFileSync(path.join(mod, '42.18/media/lua/shared/RegionManager_ZombieTraits.lua'), 'utf8');
const traitsClient = fs.readFileSync(path.join(mod, '42.18/media/lua/client/RegionManager_ZombieTraitsClient.lua'), 'utf8');
run(`
    require=function() end
    isServer=function() return false end
    RegionManager={Log=function() end,Client={zoneData={
        {bounds={minX=0,minY=0,maxX=1000,maxY=1000},zombieTraits={navigationChance=100,hawkVisionChance=100,poorHearingChance=100}}
    }}}
    Events={}
    for _,name in ipairs({'OnGameStart','OnZombieCreate','OnZombieUpdate','OnTick','OnServerCommand'}) do
        Events[name]={Add=function() end}
    end
    local function loadTraits() ${traitsSource} end
    loadTraits()
    local Traits=RegionManager.ZombieTraits
    local defaults={cognition=3,doorOpening=10,sight=2,hearing=2}
    local roll=Traits.roll('identity','cognition')
    assert(roll>=0 and roll<100 and roll==Traits.roll('identity','cognition'))
    assert(not Traits.cognition('identity',{navigationChance=0},defaults))
    assert(Traits.cognition('identity',{navigationChance=100},defaults))
    assert(Traits.sense('identity','sight',{hawkVisionChance=100},defaults)==1)
    assert(Traits.sense('identity','hearing',{badHearingChance=100},defaults)==3)
    assert(Traits.sense('identity','sight',{randomVisionChance=100},defaults)==Traits.sense('identity','sight',{randomVisionChance=100},defaults))
    local chances,active=Traits.aggregate({
        {bounds={minX=0,minY=0,maxX=20,maxY=20},zombieTraits={navigationChance=20}},
        {bounds={minX=0,minY=0,maxX=20,maxY=20},zombieTraits={navigationChance=80}},
        {enabled=false,bounds={minX=0,minY=0,maxX=20,maxY=20},zombieTraits={navigationChance=100}}
    },10,10)
    assert(active and chances.navigationChance==80)
    local _,outside=Traits.aggregate(RegionManager.Client.zoneData,2000,2000)
    assert(not outside)
    local settings={Cognition=3,DoorOpeningPercentage=25,Sight=2,Hearing=2}
    local config={}
    for key in pairs(settings) do
        local name=key
        config[name]={getValue=function() return settings[name] end,setValue=function(_,value) settings[name]=value end}
        config[name].asConfigOption=function() return config[name] end
    end
    getSandboxOptions=function() return {getOptionByName=function(_,key) return config[key:match('%.(.+)$')] end} end
    local function loadClient() ${traitsClient} end
    loadClient()
    local Client=RegionManager.ZombieTraitsClient
    local calls,frameCalls=0,0
    local square={getX=function() return 10 end,getY=function() return 10 end,getZ=function() return 0 end}
    local staleSquare={getX=function() return 10 end,getY=function() return 10 end,getZ=function() return 0 end}
    getCell=function() return {getGridSquare=function() return square end} end
    local function zombie(outfit)
        local z={outfit=outfit,onlineId=outfit % 30000,md={},walk='sprint2',speed=0.93,under=true,remote=true,x=10,y=10}
        function z:getModData() return self.md end
        function z:getPersistentOutfitID() return self.outfit end
        function z:isFemale() return false end
        function z:isDead() return self.dead or false end
        function z:getCurrentSquare() if self.unloaded then return nil end; return self.stale and staleSquare or square end
        function z:getMovingObjectIndex() return self.detached and -1 or 0 end
        function z:getOnlineID() return self.onlineId end
        function z:getX() return self.x end
        function z:getY() return self.y end
        function z:getWalkType() return self.walk end
        function z:getSpeedMod() return self.speed end
        function z:isCanCrawlUnderVehicle() return self.under end
        function z:isRemoteZombie() return self.remote end
        function z:setWalkType(value) self.walk=value end
        function z:setSpeedTypeFromWalkType() end
        function z:setSpeedMod(value) self.speed=value end
        function z:setCanCrawlUnderVehicle(value) self.under=value end
        function z:DoZombieStats()
            frameCalls=frameCalls+1; calls=calls+1
            assert(settings.Cognition==4 and settings.DoorOpeningPercentage==100)
            assert(settings.Sight==1 and settings.Hearing==3)
            self.walk='slow1'; self.speed=0.4; self.under=false
            if self.fail then error('injected failure') end
            self.cognition=1; self.sight=settings.Sight; self.hearing=settings.Hearing
        end
        return z
    end
    local z=zombie(65537)
    local identity=Traits.identity(z)
    z.outfit=65537+32768
    assert(Traits.identity(z)==identity) -- Hat loss must not reroll.
    z.md.Apocalipse_TSY_AssignedPID='65537_0'
    assert(Traits.identity(z)==identity)
    local unknown=zombie(0)
    assert(Traits.identity(unknown)==nil)
    local group={}
    for i=1,100 do
        group[i]=zombie(65536+i)
        Client.enqueue(group[i],true)
        Client.enqueue(group[i]) -- Duplicate callbacks don't duplicate jobs.
    end
    for i=1,700 do
        frameCalls=0
        Client.tick()
        assert(frameCalls<=1,'application burst')
        assert(settings.Cognition==3 and settings.DoorOpeningPercentage==25 and settings.Sight==2 and settings.Hearing==2,'sandbox leaked across ticks')
    end
    assert(calls==100,'100 jobs must complete in 700 ticks')
    for _,item in ipairs(group) do
        assert(item.walk=='sprint2' and item.speed==0.93 and item.under)
        assert(item.md.Apocalipse_TSY_ClientTraits.identity==Traits.identity(item))
    end
    local reloaded=zombie(group[1].outfit)
    assert(Traits.roll(Traits.identity(reloaded),'sight')==Traits.roll(Traits.identity(group[1]),'sight'))
    reloaded.x=2000 -- Preserve cached profile after unload even when it moved.
    Client.enqueue(reloaded,true)
    for i=1,7 do Client.tick() end
    assert(reloaded.md.Apocalipse_TSY_ClientTraits.doors)
    local buckets={}
    for i=1,1000 do buckets[Traits.roll(tostring(i),'sight')]=true end
    local count=0; for _ in pairs(buckets) do count=count+1 end
    assert(count==100,'identity hashing must reach all percentiles')
    local previous=calls
    Client.update(group[1]); group[1].remote=false; Client.update(group[1])
    for i=1,7 do Client.tick() end
    assert(calls==previous+1,'ownership acquisition repairs traits')
    local failed=zombie(66000); failed.fail=true
    Client.enqueue(failed,true)
    for i=1,7 do Client.tick() end
    assert(settings.Cognition==3 and settings.Sight==2 and settings.Hearing==2 and settings.DoorOpeningPercentage==25)
    assert(failed.walk=='sprint2' and failed.speed==0.93 and failed.under)
    local pending=zombie(0)
    Client.enqueue(pending,true)
    Client.tick(); pending.outfit=66001
    for i=1,7 do Client.tick() end
    assert(pending.md.Apocalipse_TSY_ClientTraits)
    local dead=zombie(66002); dead.dead=true
    previous=calls; Client.enqueue(dead,true); Client.tick()
    assert(calls==previous)
    local changing=zombie(66003)
    Client.enqueue(changing,true)
    Client.tick(); Client.tick()
    Client.onServerCommand('RegionManager','AllZoneBoundaries')
    for i=1,7 do Client.tick() end
    assert(changing.md.Apocalipse_TSY_ClientTraits,'configuration refresh restarts staged profile')

    -- Stream out before every stage, including the final cache/metadata step.
    for stage=1,7 do
        local streaming=zombie(67000+stage)
        Client.enqueue(streaming,true)
        for i=1,stage-1 do Client.tick() end
        previous=calls
        local record=streaming.md.Apocalipse_TSY_ClientTraits
        streaming.unloaded=true
        function streaming:getModData() error('unloaded metadata access') end
        for i=1,8 do Client.tick() end
        assert(calls==previous,'unloaded job reached initializer at stage '..stage)
        assert(streaming.md.Apocalipse_TSY_ClientTraits==record)
        Client.update(streaming) -- Must not requeue zombies outside loaded world.
        for i=1,8 do Client.tick() end
        assert(calls==previous)
    end
    for _,kind in ipairs({'detached','stale'}) do
        local streaming=zombie(kind=='detached' and 68001 or 68002)
        Client.enqueue(streaming,true)
        for i=1,5 do Client.tick() end
        streaming[kind]=true
        previous=calls
        for i=1,8 do Client.tick() end
        assert(calls==previous,'stale square/object membership must discard '..kind)
        assert(not Client.apply(streaming,{doors=true,sight=1,hearing=3}))
        assert(calls==previous,'direct applier must also reject unloaded objects')
        streaming[kind]=false
        Client.update(streaming)
        for i=1,7 do Client.tick() end
        assert(calls==previous+1,'reloaded zombie should start fresh')
    end
    local recycled=zombie(69001)
    Client.enqueue(recycled,true)
    for i=1,5 do Client.tick() end
    previous=calls
    recycled.onlineId=recycled.onlineId+1
    for i=1,8 do Client.tick() end
    assert(calls==previous,'old job must not apply to a recycled incarnation')
    Client.update(recycled)
    for i=1,7 do Client.tick() end
    assert(calls==previous+1)
    local replaced=zombie(69002)
    Client.enqueue(replaced,true)
    for i=1,5 do Client.tick() end
    Client.enqueue(replaced,true) -- New creation replaces the old queued job.
    previous=calls
    for i=1,8 do Client.tick() end
    assert(calls==previous+1,'superseded job must not invalidate its replacement')
`, '42.18 deterministic cognition/senses and paced queue');

if (!process.env.REGIONS_MOD) {
    for (const name of ['publish-workshop.yml', 'steam-workshop.yml']) {
        const document = YAML.parseDocument(fs.readFileSync(path.resolve(__dirname, '../.github/workflows', name), 'utf8'), { uniqueKeys: true });
        assert.deepEqual(document.errors, []);
    }
}
console.log('Lua syntax, JSON, sandbox/PvP checks and latest-version deterministic zombie queue passed.');
