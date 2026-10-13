-- ============================================================================
-- File: media/lua/client/RegionManager_MapPicker.lua
-- Admin region editor with an embedded map and scrollable properties sidebar
-- ============================================================================
if not isClient() then
    return
end

require "RegionManager_Config"
require "ISUI/Maps/ISWorldMap"
require "ISUI/ISPanel"
require "ISUI/ISContextMenu"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "ISUI/ISScrollBar"

RegionManager.MapPicker = RegionManager.MapPicker or {}

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)

local function T(key)
    return getText("UI_RMMP_" .. key)
end

local function toInt(value)
    value = tonumber(value)
    if value == nil then
        return nil
    end
    return math.floor(value)
end

-- ============================================================================
-- Main Map Picker Panel
-- ============================================================================
ISRegionMapPicker = ISPanel:derive("ISRegionMapPicker")

ISRegionMapFormPanel = ISPanel:derive("ISRegionMapFormPanel")

function ISRegionMapFormPanel:prerender()
    ISPanel.prerender(self)
    -- Hard clip all child widgets to this panel's viewport while scrolling.
    self:setStencilRect(0, 0, self.width, self.height)
end

function ISRegionMapFormPanel:render()
    ISPanel.render(self)
    self:clearStencilRect()
end

-- Selection states
local STATE_PICK_FIRST = 0
local STATE_READY = 2

-- Embedded map, using the PvP Territory editor's input and map styling flow.
ISRegionMapWidget = ISPanel:derive("ISRegionMapWidget")

function ISRegionMapWidget:new(x, y, width, height, picker)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.picker = picker
    return o
end

function ISRegionMapWidget:instantiate()
    self.javaObject = UIWorldMap.new(self)
    self.mapAPI = self.javaObject:getAPIv3()
    self.mapAPI:setMapItem(MapItem.getSingleton())
    self.javaObject:setX(self.x)
    self.javaObject:setY(self.y)
    self.javaObject:setWidth(self.width)
    self.javaObject:setHeight(self.height)
    self.javaObject:setDoStencil(true)
end

function ISRegionMapWidget:onMouseDown(x, y)
    if self.picker.drawingDrag then
        self.picker.savedPoint1 = self.picker.point1
        self.picker.savedPoint2 = self.picker.point2
        self.picker.point1 = {x = toInt(self.mapAPI:uiToWorldX(x, y)), y = toInt(self.mapAPI:uiToWorldY(x, y))}
        self.picker.point2 = self.picker.point1
        self.drawing = true
        self.picker:updateSelection()
    else
        self.dragging = true
        self.dragStartX, self.dragStartY = x, y
        self.dragStartCX = self.mapAPI:getCenterWorldX()
        self.dragStartCY = self.mapAPI:getCenterWorldY()
        self.dragStartZoomF = self.mapAPI:getZoomF()
        self.dragStartWorldX = self.mapAPI:uiToWorldX(x, y)
        self.dragStartWorldY = self.mapAPI:uiToWorldY(x, y)
    end
    return true
end

function ISRegionMapWidget:onMouseMove(dx, dy)
    local x, y = self:getMouseX(), self:getMouseY()
    if self.drawing then
        -- Clamp outside drags to the map viewport.
        x, y = math.max(0, math.min(self.width, x)), math.max(0, math.min(self.height, y))
        self.picker.point2 = {x = toInt(self.mapAPI:uiToWorldX(x, y)), y = toInt(self.mapAPI:uiToWorldY(x, y))}
        self.picker:updateSelection()
    elseif self.dragging then
        if math.abs(x - self.dragStartX) > 4 or math.abs(y - self.dragStartY) > 4 then
            self.dragMoved = true
        end
        if self.dragMoved then
            local wx = self.mapAPI:uiToWorldX(x, y, self.dragStartZoomF, self.dragStartCX, self.dragStartCY)
            local wy = self.mapAPI:uiToWorldY(x, y, self.dragStartZoomF, self.dragStartCX, self.dragStartCY)
            self.mapAPI:centerOn(self.dragStartCX + self.dragStartWorldX - wx, self.dragStartCY + self.dragStartWorldY - wy)
        end
    end
    return true
end

function ISRegionMapWidget:onMouseMoveOutside(dx, dy)
    return self:onMouseMove(dx, dy)
end

function ISRegionMapWidget:onMouseUp(x, y)
    if self.drawing then
        self:onMouseMove(0, 0)
        self.drawing = false
        self.picker.drawingDrag = false
        self.picker.savedPoint1, self.picker.savedPoint2 = nil, nil
        self.picker:updateSelection()
    end
    self.dragging, self.dragMoved = false, false
    return true
end

function ISRegionMapWidget:onMouseUpOutside(x, y)
    return self:onMouseUp(x, y)
end

function ISRegionMapWidget:onMouseWheel(del)
    self.mapAPI:zoomAt(self:getMouseX(), self:getMouseY(), del)
    return true
end

function ISRegionMapWidget:onRightMouseDown(x, y)
    return true
end

function ISRegionMapWidget:onRightMouseUp(x, y)
    if self.picker.drawingDrag then
        if self.drawing then
            self.picker.point1, self.picker.point2 = self.picker.savedPoint1, self.picker.savedPoint2
        end
        self.drawing, self.dragging, self.picker.drawingDrag = false, false, false
        self.picker.savedPoint1, self.picker.savedPoint2 = nil, nil
        self.picker:updateSelection()
        return true
    end
    local player = getPlayer()
    if not player then return true end
    local point = {x = toInt(self.mapAPI:uiToWorldX(x, y)), y = toInt(self.mapAPI:uiToWorldY(x, y))}
    local context = ISContextMenu.get(player:getPlayerNum(), self:getAbsoluteX() + x, self:getAbsoluteY() + y)
    context:addOption(T("SetStart"), self.picker, function(picker)
        picker.point1 = point
        picker:updateSelection()
    end)
    context:addOption(T("SetEnd"), self.picker, function(picker)
        picker.point2 = point
        picker:updateSelection()
    end)
    return true
end

function ISRegionMapWidget:render()
    self:setStencilRect(0, 0, self.width, self.height)
    self.picker:renderMapOverlay()
    self:clearStencilRect()
end

function ISRegionMapPicker:initialise()
    ISPanel.initialise(self)
end

function ISRegionMapPicker:createChildren()
    ISPanel.createChildren(self)

    local pad = 10
    local btnWid = 120
    local btnHgt = math.max(25, FONT_HGT_SMALL + 6)
    local fieldHgt = math.max(22, FONT_HGT_SMALL + 6)

    -- Title
    local panelTitle = T("Title")
    if self.isEditMode then
        panelTitle = T("EditTitle")
    end
    self.titleLabel = ISLabel:new(pad, pad, FONT_HGT_MEDIUM, panelTitle, 1, 1, 1, 1, UIFont.Medium, true)
    self.titleLabel:initialise()
    self:addChild(self.titleLabel)

    -- ========== Map area ==========
    local mapY = pad + FONT_HGT_MEDIUM + pad
    local btnY = self.height - btnHgt - pad
    local formW = math.floor(self.width * 0.38)
    local mapHeight = btnY - mapY - FONT_HGT_SMALL * 2 - pad * 2
    self.mapX, self.mapY = pad, mapY
    self.mapW, self.mapH = self.width - formW - pad * 3, mapHeight
    self.mapWidget = ISRegionMapWidget:new(self.mapX, self.mapY, self.mapW, self.mapH, self)
    self.mapWidget:initialise()
    self.mapWidget:instantiate()
    self:addChild(self.mapWidget)
    self.worldMap = self.mapWidget.javaObject
    local api = self.mapWidget.mapAPI
    MapUtils.initDefaultMapData(self.mapWidget)
    api:setBoundsFromWorld()
    MapUtils.initDefaultStreetData(self.mapWidget)
    MapUtils.initDefaultStyleV3(self.mapWidget)
    api:getSymbolsAPIv2():initDefaultAnnotations()
    api:setBoolean("Isometric", false)
    api:setBoolean("HideUnvisited", false)
    api:setBoolean("ClampBaseZoomToPoint5", false)

    -- ========== Status bar ==========
    local statusY = mapY + mapHeight + 4
    self.statusLabel = ISLabel:new(pad, statusY, FONT_HGT_SMALL, T("StatusPickFirst"), 1, 1, 0.5, 1, UIFont.Small, true)
    self.statusLabel:initialise()
    self:addChild(self.statusLabel)

    self.coordLabel = ISLabel:new(pad, statusY + FONT_HGT_SMALL + 2, FONT_HGT_SMALL, T("CoordNone"), 0.7, 0.7, 0.7, 1,
        UIFont.Small, true)
    self.coordLabel:initialise()
    self:addChild(self.coordLabel)

    -- ========== Action buttons ==========
    -- ========== Scrollable form fields ==========
    local formY = mapY
    local formH = btnY - formY - pad
    self.formPanel = ISRegionMapFormPanel:new(self.mapX + self.mapW + pad, formY, formW, formH)
    self.formPanel:initialise()
    self.formPanel:instantiate()
    self.formPanel.background = true
    self.formPanel.backgroundColor = {
        r = 0.06,
        g = 0.06,
        b = 0.06,
        a = 0.75
    }
    self.formPanel.borderColor = {
        r = 0.25,
        g = 0.25,
        b = 0.25,
        a = 1
    }
    self.formPanel:setScrollChildren(true)
    self.formPanel:addScrollBars(false)
    self.formPanel:setScrollHeight(formH)
    self:addChild(self.formPanel)

    local formPad = 8
    local rowY = formPad
    local entryW = self.formPanel.width - formPad * 2 - 18

    local function addSpacer(h)
        rowY = rowY + (h or 4)
    end

    local function addSection(title)
        local lbl = ISLabel:new(formPad, rowY, fieldHgt, title, 1, 0.85, 0.35, 1, UIFont.Small, true)
        lbl:initialise()
        self.formPanel:addChild(lbl)
        rowY = rowY + fieldHgt + 2
    end

    local function addLabel(text)
        local lbl = ISLabel:new(formPad, rowY, fieldHgt, text, 0.9, 0.9, 0.9, 1, UIFont.Small, true)
        lbl:initialise()
        self.formPanel:addChild(lbl)
        rowY = rowY + fieldHgt + 2
    end

    local function addTextEntry(defaultValue)
        local ent = ISTextEntryBox:new(defaultValue or "", formPad, rowY, entryW, fieldHgt)
        ent:initialise()
        ent:instantiate()
        self.formPanel:addChild(ent)
        rowY = rowY + fieldHgt + 6
        return ent
    end

    local function addNumericField(labelText)
        addLabel(labelText)
        return addTextEntry("0")
    end

    addSection(T("SecBasic"))
    addLabel(T("LblName"))
    self.nameEntry = addTextEntry("")

    addLabel(T("LblIDAuto"))
    self.idEntry = addTextEntry("")

    addSpacer(2)
    addSection(T("SecFlags"))
    addLabel(T("LblPVPMode"))
    self.pvpMode = ISComboBox:new(formPad, rowY, entryW, fieldHgt)
    self.pvpMode:initialise()
    self.pvpMode:instantiate()
    self.pvpMode:addOption(T("PVPInherit"))
    self.pvpMode:addOption(T("PVPSafe"))
    self.pvpMode:addOption(T("PVPEnabled"))
    self.formPanel:addChild(self.pvpMode)
    rowY = rowY + fieldHgt + 8
    self.chanceEntries = {}
    local function chance(key, label, optional)
        local entry = addNumericField(T(label))
        entry:setText(optional and "" or "0")
        entry.tooltip = T(optional and "TraitFieldHint" or "ChanceFieldHint")
        self.chanceEntries[key] = entry
        return entry
    end
    addSection(T("SecSpeed"))
    self.sprinterEntry = chance("sprinterChance", "LblSprinter")
    self.shamblerEntry = chance("shamblerChance", "LblShambler")
    addSection(T("SecToughness"))
    self.toughnessEntry = chance("toughnessChance", "LblTough")
    self.maxHitsEntry = addNumericField(T("LblMaxHits"))
    self.maxHitsEntry:setText("1")
    self.maxHitsEntry.tooltip = T("NoteMaxHitsOnlyTough") .. " " .. T("NoteMaxHitsDesc")

    addSection(T("SecCognition"))
    self.navigationEntry = chance("navigationChance", "LblDoorOpening", true)
    addSection(T("SecVision"))
    self.hawkVisionEntry = chance("hawkVisionChance", "LblHawkVision", true)
    self.normalVisionEntry = chance("normalVisionChance", "LblNormalVision", true)
    self.poorVisionEntry = chance("poorVisionChance", "LblPoorVision", true)
    self.badVisionEntry = chance("badVisionChance", "LblBadVision", true)
    self.randomVisionEntry = chance("randomVisionChance", "LblRandomVision", true)
    addSection(T("SecHearing"))
    self.pinpointHearingEntry = chance("pinpointHearingChance", "LblPinpointHearing", true)
    self.goodHearEntry = chance("goodHearingChance", "LblGoodHearing", true)
    self.normalHearingEntry = chance("normalHearingChance", "LblNormalHearing", true)
    self.poorHearingEntry = chance("poorHearingChance", "LblPoorHearing", true)
    self.badHearEntry = chance("badHearingChance", "LblBadHearing", true)
    self.randomHearingEntry = chance("randomHearingChance", "LblRandomHearing", true)
    addSection(T("SecBehaviorNotes"))
    local help = ISButton:new(formPad, rowY, entryW, fieldHgt, T("TraitHelp"), nil, nil)
    help.tooltip = T("TraitRules")
    help:initialise()
    self.formPanel:addChild(help)
    rowY = rowY + fieldHgt + 8

    addLabel(T("LblEntryMessage"))
    self.messageEntry = addTextEntry("")
    self.messageEntry.tooltip = T("EntryMessageHint")

    -- Allow the form to grow arbitrarily while remaining inside the window.
    self.formPanel:setScrollHeight(rowY + formPad)
    self.formPanel:updateScrollbars()

    self.resetBtn = ISButton:new(pad, btnY, btnWid, btnHgt, T("BtnDraw"), self, ISRegionMapPicker.onReset)
    self.resetBtn:initialise()
    self.resetBtn:instantiate()
    self.resetBtn.borderColor = {
        r = 1,
        g = 1,
        b = 1,
        a = 0.4
    }
    self:addChild(self.resetBtn)

    local submitText = self.isEditMode and T("BtnSave") or T("BtnSubmit")
    self.submitBtn =
        ISButton:new(pad + btnWid + pad, btnY, btnWid, btnHgt, submitText, self, ISRegionMapPicker.onSubmit)
    self.submitBtn:initialise()
    self.submitBtn:instantiate()
    self.submitBtn.borderColor = {
        r = 0.3,
        g = 1,
        b = 0.3,
        a = 0.6
    }
    self:addChild(self.submitBtn)

    self.cancelBtn = ISButton:new(self.width - btnWid - pad, btnY, btnWid, btnHgt, T("BtnCancel"), self,
        ISRegionMapPicker.onCancel)
    self.cancelBtn:initialise()
    self.cancelBtn:instantiate()
    self.cancelBtn.borderColor = {
        r = 1,
        g = 0.3,
        b = 0.3,
        a = 0.6
    }
    self:addChild(self.cancelBtn)

    self.backBtn = ISButton:new(self.width - (btnWid + pad) * 2, btnY, btnWid, btnHgt, T("BtnBack"), self,
        ISRegionMapPicker.onBack)
    self.backBtn:initialise()
    self.backBtn:instantiate()
    self.backBtn.borderColor = {
        r = 1,
        g = 0.7,
        b = 0.1,
        a = 0.7
    }
    self:addChild(self.backBtn)

    if self.isEditMode then
        self.deleteBtn = ISButton:new(self.width - (btnWid + pad) * 3, btnY, btnWid, btnHgt, T("BtnDelete"), self,
            ISRegionMapPicker.onDelete)
        self.deleteBtn:initialise()
        self.deleteBtn:instantiate()
        self.deleteBtn.borderColor = {
            r = 1,
            g = 0.2,
            b = 0.2,
            a = 0.8
        }
        self:addChild(self.deleteBtn)
    end

    -- ========== Initialize state ==========
    self.selectionState = STATE_PICK_FIRST
    self.point1 = nil -- {x, y}
    self.point2 = nil -- {x, y}

    if self.isEditMode and self.editRegion then
        local r = self.editRegion
        self.nameEntry:setText(r.name or "")
        self.idEntry:setText(r.id or "")

        self.point1 = {
            x = r.x1 or 0,
            y = r.y1 or 0
        }
        self.point2 = {
            x = r.x2 or 0,
            y = r.y2 or 0
        }
        self.selectionState = STATE_READY
        self.statusLabel:setName(T("StatusReady"))
        self.statusLabel.r = 0.3
        self.statusLabel.g = 1
        self.statusLabel.b = 0.3

        local props = r.customProperties or {}
        self.pvpMode.selected = props.pvpEnabled == true and 3 or (props.pvpEnabled == false and 2 or 1)

        local function setNum(entry, value)
            if entry then
                entry:setText(value ~= nil and tostring(value) or "")
            end
        end

        for key, entry in pairs(self.chanceEntries) do setNum(entry, props[key]) end
        setNum(self.maxHitsEntry, props.maxHits)
        self.messageEntry:setText(props.message or "")
    end

    -- Fit map bounds to the viewport on open so users start with a usable view.
    self:resetMapViewToFit()
    self.drawingDrag = not self.isEditMode
    self:updateSelection()
    if self.point1 and self.point2 then
        api:centerOn((self.point1.x + self.point2.x) / 2, (self.point1.y + self.point2.y) / 2)
    end
end

function ISRegionMapPicker:resetMapViewToFit()
    local api = self.worldMap and self.worldMap:getAPIv1()
    if not api then
        return
    end

    -- resetView computes a zoom/center that fits current map bounds to widget size.
    local ok = pcall(function()
        api:resetView()
    end)
    if ok then
        return
    end

    -- Fallback if resetView is unavailable/fails in some builds.
    local okMinX, minX = pcall(function()
        return api:getMinXInSquares()
    end)
    local okMaxX, maxX = pcall(function()
        return api:getMaxXInSquares()
    end)
    local okMinY, minY = pcall(function()
        return api:getMinYInSquares()
    end)
    local okMaxY, maxY = pcall(function()
        return api:getMaxYInSquares()
    end)
    if okMinX and okMaxX and okMinY and okMaxY and minX and maxX and minY and maxY then
        local cx = (minX + maxX) / 2
        local cy = (minY + maxY) / 2
        pcall(function()
            api:centerOn(cx, cy)
        end)
    end
end

function ISRegionMapPicker:clipRectToMap(rx, ry, rw, rh)
    if rw <= 0 or rh <= 0 then
        return nil
    end

    local x1 = math.max(rx, self.mapX)
    local y1 = math.max(ry, self.mapY)
    local x2 = math.min(rx + rw, self.mapX + self.mapW)
    local y2 = math.min(ry + rh, self.mapY + self.mapH)

    local w = x2 - x1
    local h = y2 - y1
    if w <= 0 or h <= 0 then
        return nil
    end

    return x1, y1, w, h
end

function ISRegionMapPicker:drawMapClippedRect(rx, ry, rw, rh, a, r, g, b)
    local x, y, w, h = self:clipRectToMap(rx, ry, rw, rh)
    if x then
        self:drawRect(x, y, w, h, a, r, g, b)
    end
end

function ISRegionMapPicker:drawMapClippedRectBorder(rx, ry, rw, rh, a, r, g, b)
    local x, y, w, h = self:clipRectToMap(rx, ry, rw, rh)
    if x then
        self:drawRectBorder(x, y, w, h, a, r, g, b)
    end
end

-- ============================================================================
-- Rendering — map widget + selection overlay
-- ============================================================================
function ISRegionMapPicker:prerender()
    ISPanel.prerender(self)

    -- Draw the map background area
    self:drawRect(self.mapX, self.mapY, self.mapW, self.mapH, 1, 0.05, 0.05, 0.05)
end

function ISRegionMapPicker:renderMapOverlay()
    local api = self.worldMap:getAPIv1()

    -- Draw existing zones on map as semi-transparent overlays
    if RegionManager.Client and RegionManager.Client.zoneData then
        for _, zone in ipairs(RegionManager.Client.zoneData) do
            local b = zone.bounds
            local uiX1 = api:worldToUIX(b.minX, b.minY) + self.mapX
            local uiY1 = api:worldToUIY(b.minX, b.minY) + self.mapY
            local uiX2 = api:worldToUIX(b.maxX, b.maxY) + self.mapX
            local uiY2 = api:worldToUIY(b.maxX, b.maxY) + self.mapY

            local rx = math.min(uiX1, uiX2)
            local ry = math.min(uiY1, uiY2)
            local rw = math.abs(uiX2 - uiX1)
            local rh = math.abs(uiY2 - uiY1)

            local c = zone.color or {
                r = 0.5,
                g = 0.5,
                b = 0.5
            }
            self:drawMapClippedRect(rx, ry, rw, rh, 0.15, c.r, c.g, c.b)
            self:drawMapClippedRectBorder(rx, ry, rw, rh, 0.6, c.r, c.g, c.b)
        end
    end

    -- Draw selection markers and rectangle
    if self.point1 then
        local p1uiX = api:worldToUIX(self.point1.x, self.point1.y) + self.mapX
        local p1uiY = api:worldToUIY(self.point1.x, self.point1.y) + self.mapY
        if p1uiX >= self.mapX and p1uiX <= self.mapX + self.mapW and p1uiY >= self.mapY and p1uiY <= self.mapY +
            self.mapH then
            -- Draw crosshair marker at point 1
            self:drawMapClippedRect(p1uiX - 4, p1uiY - 1, 9, 3, 0.9, 0, 1, 0)
            self:drawMapClippedRect(p1uiX - 1, p1uiY - 4, 3, 9, 0.9, 0, 1, 0)
        end
    end

    if self.point2 then
        local p2uiX = api:worldToUIX(self.point2.x, self.point2.y) + self.mapX
        local p2uiY = api:worldToUIY(self.point2.x, self.point2.y) + self.mapY
        if p2uiX >= self.mapX and p2uiX <= self.mapX + self.mapW and p2uiY >= self.mapY and p2uiY <= self.mapY +
            self.mapH then
            -- Draw crosshair marker at point 2
            self:drawMapClippedRect(p2uiX - 4, p2uiY - 1, 9, 3, 0.9, 1, 0.3, 0)
            self:drawMapClippedRect(p2uiX - 1, p2uiY - 4, 3, 9, 0.9, 1, 0.3, 0)
        end
    end

    -- Draw selection rectangle between both points
    if self.point1 and self.point2 then
        local p1uiX = api:worldToUIX(self.point1.x, self.point1.y) + self.mapX
        local p1uiY = api:worldToUIY(self.point1.x, self.point1.y) + self.mapY
        local p2uiX = api:worldToUIX(self.point2.x, self.point2.y) + self.mapX
        local p2uiY = api:worldToUIY(self.point2.x, self.point2.y) + self.mapY

        local rx = math.min(p1uiX, p2uiX)
        local ry = math.min(p1uiY, p2uiY)
        local rw = math.abs(p2uiX - p1uiX)
        local rh = math.abs(p2uiY - p1uiY)

        -- Semi-transparent green fill
        self:drawMapClippedRect(rx, ry, rw, rh, 0.2, 0, 1, 0)
        -- Bright green border
        self:drawMapClippedRectBorder(rx, ry, rw, rh, 0.9, 0, 1, 0)
    elseif self.point1 and self:isMouseOverMap() then
        -- Live preview: draw rectangle from point1 to mouse cursor
        local api2 = self.worldMap:getAPIv1()
        local mouseWorldX = toInt(api2:mouseToWorldX())
        local mouseWorldY = toInt(api2:mouseToWorldY())

        if mouseWorldX and mouseWorldY then
            local p1uiX = api:worldToUIX(self.point1.x, self.point1.y) + self.mapX
            local p1uiY = api:worldToUIY(self.point1.x, self.point1.y) + self.mapY
            local mUiX = api:worldToUIX(mouseWorldX, mouseWorldY) + self.mapX
            local mUiY = api:worldToUIY(mouseWorldX, mouseWorldY) + self.mapY

            local rx = math.min(p1uiX, mUiX)
            local ry = math.min(p1uiY, mUiY)
            local rw = math.abs(mUiX - p1uiX)
            local rh = math.abs(mUiY - p1uiY)

            -- Semi-transparent yellow preview
            self:drawMapClippedRect(rx, ry, rw, rh, 0.12, 1, 1, 0)
            self:drawMapClippedRectBorder(rx, ry, rw, rh, 0.5, 1, 1, 0)
        end
    end

    -- Draw map border on top of everything
    self:drawRectBorder(self.mapX, self.mapY, self.mapW, self.mapH, 0.8, 0.4, 0.4, 0.4)

    -- Update coordinate label with mouse position
    if self:isMouseOverMap() then
        local api3 = self.worldMap:getAPIv1()
        local mwx = toInt(api3:mouseToWorldX())
        local mwy = toInt(api3:mouseToWorldY())
        if mwx and mwy then
            local coordText = getText("UI_RMMP_CoordMouse", mwx, mwy)
            if self.point1 and self.point2 then
                coordText = coordText .. " | " .. getText("UI_RMMP_SelectionSize",
                    math.abs(self.point2.x - self.point1.x) + 1, math.abs(self.point2.y - self.point1.y) + 1)
            end
            self.coordLabel:setName(coordText)
        end
    end
end

-- ============================================================================
-- Mouse handling
-- ============================================================================
function ISRegionMapPicker:isMouseOverMap()
    local mx = self:getMouseX()
    local my = self:getMouseY()
    return mx >= self.mapX and mx <= self.mapX + self.mapW and my >= self.mapY and my <= self.mapY + self.mapH
end

function ISRegionMapPicker:isMouseOverFormPanel()
    if not self.formPanel then
        return false
    end
    local mx = self:getMouseX()
    local my = self:getMouseY()
    local x1 = self.formPanel.x
    local y1 = self.formPanel.y
    local x2 = x1 + self.formPanel.width
    local y2 = y1 + self.formPanel.height
    return mx >= x1 and mx <= x2 and my >= y1 and my <= y2
end

function ISRegionMapPicker:scrollFormPanel(del)
    return self.formPanel and self.formPanel:onMouseWheel(del) or false
end

function ISRegionMapPicker:onMouseWheel(del)
    if self:isMouseOverFormPanel() then return self:scrollFormPanel(del) end
    return false
end

function ISRegionMapFormPanel:onMouseWheel(del)
    local current = self:getYScroll() or 0
    local minimum = math.min(0, self.height - self:getScrollHeight())
    self:setYScroll(math.max(minimum, math.min(0, current + del * 28)))
    self:updateScrollbars()
    return true
end

function ISRegionMapPicker:updateSelection()
    self.selectionState = self.point1 and self.point2 and STATE_READY or STATE_PICK_FIRST
    self.statusLabel:setName(T(self.drawingDrag and "DrawHint" or (self.selectionState == STATE_READY and "SelectionReady" or "MapHint")))
    self.statusLabel.r, self.statusLabel.g, self.statusLabel.b = 0.8, 1, 0.8
    self.coordLabel:setName(self.point1 and self.point2 and getText("UI_RMMP_SelectionSize",
        math.abs(self.point2.x - self.point1.x) + 1, math.abs(self.point2.y - self.point1.y) + 1) or T("CoordNone"))
end

-- ============================================================================
-- Form helpers
-- ============================================================================
function ISRegionMapPicker:updateIdFromName()
    local name = self.nameEntry:getText()
    if name and name ~= "" then
        -- Convert name to snake_case id
        local id = name:lower():gsub("%s+", "_"):gsub("[^%w_]", "")
        self.idEntry:setText(id)
    end
end

function ISRegionMapPicker:getPropertiesFromForm(baseProps)
    local props = {}
    if type(baseProps) == "table" then
        for k, v in pairs(baseProps) do
            props[k] = v
        end
    end

    local maxHits = math.floor(tonumber(self.maxHitsEntry:getText()) or 1)
    if maxHits < 1 then
        maxHits = 1
    end
    if maxHits > 99 then
        maxHits = 99
    end
    props.pvpEnabled = nil
    if self.pvpMode.selected == 2 then props.pvpEnabled = false end
    if self.pvpMode.selected == 3 then props.pvpEnabled = true end
    for key, entry in pairs(self.chanceEntries or {}) do
        local value = tonumber(entry:getText())
        props[key] = value and math.max(0, math.min(100, value)) or nil
    end
    props.maxHits = maxHits
    props.message = (self.messageEntry:getText() or ""):match("^%s*(.-)%s*$")
    props.announceEntry = props.message ~= ""
    props.announceExit = false

    return props
end

-- ============================================================================
-- Button callbacks
-- ============================================================================
function ISRegionMapPicker:onReset()
    self.drawingDrag = true
    self.mapWidget.drawing, self.mapWidget.dragging = false, false
    self.savedPoint1, self.savedPoint2 = nil, nil
    self.selectionState = STATE_PICK_FIRST
    self.statusLabel:setName(T("DrawHint"))
    self.statusLabel.r = 1;
    self.statusLabel.g = 1;
    self.statusLabel.b = 0.5
    self.coordLabel:setName(T("CoordNone"))
end

function ISRegionMapPicker:onSubmit()
    local player = getPlayer()
    if not player then
        return
    end

    if self.drawingDrag or not self.point1 or not self.point2 then
        player:Say(T("SaySelectBoth"), 1, 0.3, 0.3, UIFont.Small, 2, "radio")
        return
    end

    for _, entry in pairs(self.chanceEntries or {}) do
        local text = entry:getText()
        local value = tonumber(text)
        if text:match("%S") and (not value or value ~= value or value < 0 or value > 100) then
            player:Say(T("InvalidChance"), 1, 0.3, 0.3, UIFont.Small, 2, "radio")
            return
        end
    end

    local name = self.nameEntry:getText()
    if not name or name == "" then
        player:Say(T("SayEnterName"), 1, 0.3, 0.3, UIFont.Small, 2, "radio")
        return
    end

    if self.idEntry:getText() == "" then self:updateIdFromName() end
    local id = self.idEntry:getText()
    if not id or id == "" then
        player:Say(T("SayEnterId"), 1, 0.3, 0.3, UIFont.Small, 2, "radio")
        return
    end

    local props = self:getPropertiesFromForm(self.isEditMode and self.editRegion and self.editRegion.customProperties or
                                                 nil)

    local regionDef = {
        id = id,
        name = name,
        x1 = math.floor(self.point1.x),
        y1 = math.floor(self.point1.y),
        x2 = math.floor(self.point2.x),
        y2 = math.floor(self.point2.y),
        z = self.isEditMode and self.editRegion.z or 0,
        enabled = not self.isEditMode or self.editRegion.enabled ~= false,
        categories = self.isEditMode and self.editRegion.categories or {},
        customProperties = props
    }

    if self.isEditMode then
        regionDef.originalId = self.editOriginalId or id
        sendClientCommand("RegionManager", "UpdateRegion", regionDef)
        player:Say(getText("UI_RMMP_SayUpdating", name), 0.7, 0.7, 1, UIFont.Small, 2, "radio")
        print("[RegionManager MapPicker] Sent UpdateRegion command: " .. tostring(regionDef.originalId) .. " -> " .. id)
    else
        sendClientCommand("RegionManager", "AddRegion", regionDef)
        player:Say(string.format(T("SaySubmitting"), name), 0.7, 0.7, 1, UIFont.Small, 2, "radio")
        print("[RegionManager MapPicker] Sent AddRegion command: " .. id)
    end
end

function ISRegionMapPicker:onDelete()
    if not self.isEditMode then
        return
    end

    local player = getPlayer()
    local originalId = self.editOriginalId or (self.editRegion and self.editRegion.id)
    if not player or not originalId or originalId == "" then
        return
    end

    sendClientCommand("RegionManager", "DeleteRegion", {
        originalId = originalId
    })
    player:Say(getText("UI_RMMP_SayDeleting", tostring(originalId)), 1, 0.6, 0.2, UIFont.Small, 2, "radio")
end

function ISRegionMapPicker:onBack()
    self:close()
    RegionManager.AdminPanel.Open()
end

function ISRegionMapPicker:onCancel()
    self:close()
end

function ISRegionMapPicker:close()
    if RegionManager and RegionManager.MapPicker and RegionManager.MapPicker.instance == self then
        RegionManager.MapPicker.instance = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
end

-- ============================================================================
-- Constructor
-- ============================================================================
function ISRegionMapPicker:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.borderColor = {
        r = 0.4,
        g = 0.4,
        b = 0.4,
        a = 1
    }
    o.backgroundColor = {
        r = 0,
        g = 0,
        b = 0,
        a = 0.95
    }
    o.moveWithMouse = true
    o.isEditMode = false
    o.editRegion = nil
    o.editOriginalId = nil
    return o
end

-- ============================================================================
-- Public API
-- ============================================================================
function RegionManager.MapPicker.Open()
    local player = getPlayer()
    if not player then
        return
    end

    if player:getAccessLevel() == "None" then
        return
    end

    local width = math.min(1280, getCore():getScreenWidth() - 40)
    local height = math.min(850, getCore():getScreenHeight() - 40)
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2

    local panel = ISRegionMapPicker:new(x, y, width, height)
    panel.isEditMode = false
    panel.editRegion = nil
    panel.editOriginalId = nil
    RegionManager.MapPicker.instance = panel
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)

    print("[RegionManager MapPicker] Panel opened by: " .. player:getUsername())
end

---@param region RegionDefinition
function RegionManager.MapPicker.OpenForEdit(region)
    local player = getPlayer()
    if not player then
        return
    end

    if player:getAccessLevel() == "None" then
        return
    end

    if not region or not region.id then
        return
    end

    local width = math.min(1280, getCore():getScreenWidth() - 40)
    local height = math.min(850, getCore():getScreenHeight() - 40)
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2

    local panel = ISRegionMapPicker:new(x, y, width, height)
    panel.isEditMode = true
    panel.editRegion = region
    panel.editOriginalId = region.id
    RegionManager.MapPicker.instance = panel
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(true)

    print("[RegionManager MapPicker] Edit panel opened by: " .. player:getUsername() .. " for region " ..
              tostring(region.id))
end

print("[RegionManager MapPicker] Map picker module loaded")

return RegionManager.MapPicker
