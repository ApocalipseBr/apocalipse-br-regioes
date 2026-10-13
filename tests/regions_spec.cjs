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
    run(`
        isServer = function() return true end
        local function loadConfig() ${config} end
        loadConfig()
        local function loadAuto() ${auto} end
        loadAuto()
        RegionManager.Config.Regions = {
            {id='pvp',name='PvP',enabled=true,categories={'PVP'},x1=10,y1=10,x2=20,y2=20,z=0},
            {id='manual',name='Safe',enabled=true,categories={'SAFEZONE'},x1=40,y1=40,x2=45,y2=45,z=0},
            {id='neutral',name='Zombies',enabled=true,categories={'SPRINTERS'},x1=60,y1=60,x2=65,y2=65,z=0}
        }
        require = function(name)
            if name=='RegionManager_JSON' then return {encode=function() return '{}' end} end
        end
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

if (!process.env.REGIONS_MOD) {
    for (const name of ['publish-workshop.yml', 'steam-workshop.yml']) {
        const document = YAML.parseDocument(fs.readFileSync(path.resolve(__dirname, '../.github/workflows', name), 'utf8'), { uniqueKeys: true });
        assert.deepEqual(document.errors, []);
    }
}
console.log('Lua syntax, translation JSON, sandbox defaults, coverage boundaries and PvP behavior passed for both versions.');
