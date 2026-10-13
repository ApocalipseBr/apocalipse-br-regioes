const fs = require('node:fs');
const path = require('node:path');

module.exports = function testMapPicker(mod, run) {
    const source = fs.readFileSync(path.join(mod, '42.18/media/lua/client/RegionManager_MapPicker.lua'), 'utf8');
    run(`
        isClient=function() return true end
        require=function() end
        RegionManager={}
        UIFont={Small=1,Medium=2}
        getTextManager=function() return {getFontHeight=function() return 14 end} end
        getText=function(key) return key end
        ISPanel={derive=function(_,name) return {name=name} end}
        local function loadPicker() ${source} end
        loadPicker()
        local function entry(text)
            return {getText=function() return text end,setText=function(_,value) text=value end}
        end
        local picker=setmetatable({
            nameEntry=entry('Renamed region'),idEntry=entry('stable_id'),messageEntry=entry('Welcome'),
            maxHitsEntry=entry('7'),pvpMode={selected=1},
            chanceEntries={navigationChance=entry(''),normalVisionChance=entry('0'),hawkVisionChance=entry('75')},
            statusLabel={setName=function() end},coordLabel={setName=function() end}
        },{__index=ISRegionMapPicker})
        local props=picker:getPropertiesFromForm({navigationChance=90,normalVisionChance=50,pvpEnabled=false,memoryLongChance=65,custom='keep'})
        assert(props.navigationChance==nil and props.normalVisionChance==0 and props.hawkVisionChance==75)
        assert(props.memoryLongChance==65 and props.custom=='keep' and props.maxHits==7)
        assert(props.pvpEnabled==nil and props.announceEntry and not props.announceExit)
        picker.messageEntry:setText('   ')
        props=picker:getPropertiesFromForm({message='Old message',announceEntry=true,announceExit=true})
        assert(props.message=='' and not props.announceEntry and not props.announceExit)
        picker.messageEntry:setText(' Welcome ')
        props=picker:getPropertiesFromForm({announceEntry=false,announceExit=true})
        assert(props.message=='Welcome' and props.announceEntry and not props.announceExit)
        picker.pvpMode.selected=2
        assert(picker:getPropertiesFromForm().pvpEnabled==false)
        picker.pvpMode.selected=3
        assert(picker:getPropertiesFromForm().pvpEnabled==true)

        local mouseX,mouseY=0,0
        local centerX,centerY=100,200
        local zoomDelta
        local api={
            uiToWorldX=function(_,x,y,zoom,cx,cy) return (cx or centerX)+x end,
            uiToWorldY=function(_,x,y,zoom,cx,cy) return (cy or centerY)+y end,
            getCenterWorldX=function() return centerX end,getCenterWorldY=function() return centerY end,
            getZoomF=function() return 17 end,
            centerOn=function(_,x,y) centerX,centerY=x,y end,
            zoomAt=function(_,x,y,del) zoomDelta=del end
        }
        local widget=setmetatable({picker=picker,mapAPI=api,width=400,height=300,
            getMouseX=function() return mouseX end,getMouseY=function() return mouseY end},
            {__index=ISRegionMapWidget})
        picker.mapWidget=widget
        -- Default left drag pans; it must never mutate the region.
        picker.point1={x=11,y=22}; picker.point2={x=33,y=44}
        widget:onMouseDown(10,20)
        mouseX,mouseY=12,22
        widget:onMouseMove(2,2)
        assert(centerX==100 and centerY==200)
        mouseX,mouseY=40,60
        widget:onMouseMove(28,38)
        assert(centerX==70 and centerY==160)
        widget:onMouseUpOutside(40,60)
        assert(not widget.dragging and picker.point1.x==11 and picker.point2.x==33)
        widget:onMouseWheel(1)
        assert(zoomDelta==1)
        -- Drawing uses world coordinates, supports reverse drags and outside releases.
        picker.drawingDrag=true
        widget:onMouseDown(100,100)
        assert(picker.point1.x==170 and picker.point1.y==260)
        mouseX,mouseY=-20,400
        widget:onMouseMoveOutside(-120,300)
        assert(picker.point2.x==70 and picker.point2.y==460)
        widget:onMouseUpOutside(-20,400)
        assert(not picker.drawingDrag and not widget.drawing)
        assert(picker.selectionState==2)
        local previous1,previous2=picker.point1,picker.point2
        picker:onReset()
        widget:onMouseDown(50,50)
        widget:onRightMouseUp(60,60)
        assert(picker.point1==previous1 and picker.point2==previous2 and not picker.drawingDrag)

        local sent
        getPlayer=function() return {Say=function() end} end
        sendClientCommand=function(module,command,args) sent={command=command,args=args} end
        picker.isEditMode=true
        picker.editRegion={id='stable_id',z=2,enabled=false,categories={'PVP'},customProperties={custom='keep'}}
        picker.editOriginalId='stable_id'
        picker:onSubmit()
        assert(sent.command=='UpdateRegion' and sent.args.id=='stable_id' and sent.args.originalId=='stable_id')
        assert(sent.args.z==2 and sent.args.enabled==false and sent.args.categories[1]=='PVP' and sent.args.customProperties.custom=='keep')
        sent=nil
        picker.chanceEntries.navigationChance=entry('101')
        picker:onSubmit()
        assert(sent==nil)
        picker.chanceEntries.navigationChance=entry('invalid')
        picker:onSubmit()
        assert(sent==nil)
        picker.chanceEntries.navigationChance=entry('0')
        picker.drawingDrag=true
        picker:onSubmit()
        assert(sent==nil)
        -- Native panels scroll with negative offsets.
        local scroll=0
        local form=setmetatable({height=100,getScrollHeight=function() return 300 end,
            getYScroll=function() return scroll end,setYScroll=function(_,v) scroll=v end,updateScrollbars=function() end},
            {__index=ISRegionMapFormPanel})
        form:onMouseWheel(-1)
        assert(scroll==-28)
        form:onMouseWheel(-100)
        assert(scroll==-200)
        form:onMouseWheel(100)
        assert(scroll==0)
    `, '42.18 map picker input and property round trips');

    const tick = fs.readFileSync(path.join(mod, '42.18/media/lua/client/RegionManager_ClientTick.lua'), 'utf8');
    run(`
        isServer=function() return false end
        require=function() end
        UIFont={Medium=1}
        local onTick
        Events={
            OnTick={Add=function(fn) onTick=fn end},
            OnCreatePlayer={Add=function() end},
            OnServerCommand={Add=function() end}
        }
        local x,y=5,5
        local messages={}
        local player={getX=function() return x end,getY=function() return y end,
            Say=function(_,message) messages[#messages+1]=message end}
        getPlayer=function() return player end
        local zone={id='test',name='Test',bounds={minX=0,minY=0,maxX=10,maxY=10},
            message='Welcome',announceEntry=false,announceExit=true}
        RegionManager={Log=function() end,Client={zoneData={zone}}}
        local function loadTick() ${tick} end
        loadTick()
        RegionManager.ClientTick.setTickInterval(1)
        local entries,exits=0,0
        RegionManager.ClientTick.registerModule({name='observer',
            onZoneEntered=function() entries=entries+1 end,
            onZoneExited=function() exits=exits+1 end})
        onTick()
        assert(#messages==1 and messages[1]=='Welcome' and entries==1)
        onTick()
        assert(#messages==1 and entries==1)
        x=20
        onTick()
        assert(#messages==1 and exits==1)
        x=5
        onTick()
        assert(#messages==2 and entries==2)
        for _,message in ipairs({'','   ','\\t\\n',false}) do
            x=20; onTick()
            zone.message=message
            zone.announceEntry=true
            x=5; onTick()
            assert(#messages==2)
        end
        x=20; onTick()
        zone.message=nil
        x=5; onTick()
        assert(#messages==2 and entries==7 and exits==6)
    `, '42.18 entry-only region messages');
};
