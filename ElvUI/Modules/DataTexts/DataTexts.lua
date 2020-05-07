local E, L, V, P, G = unpack(select(2, ...)); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local DT = E:GetModule('DataTexts')
local TT = E:GetModule('Tooltip')
local LDB = E.Libs.LDB
local LSM = E.Libs.LSM

local _G = _G
local type, error, pcall = type, error, pcall
local ipairs, pairs, strlen = ipairs, pairs, strlen
local CreateFrame = CreateFrame
local IsInInstance = IsInInstance
local InCombatLockdown = InCombatLockdown
local RegisterStateDriver = RegisterStateDriver
local UnregisterStateDriver = UnregisterStateDriver

function DT:Initialize()
	DT.Initialized = true
	DT.db = E.db.datatexts

	DT.tooltip = CreateFrame("GameTooltip", "DatatextTooltip", E.UIParent, "GameTooltipTemplate")
	TT:HookScript(DT.tooltip, 'OnShow', 'SetStyle')

	-- Ignore header font size on DatatextTooltip
	local font = E.Libs.LSM:Fetch("font", E.db.tooltip.font)
	local fontOutline = E.db.tooltip.fontOutline
	local textSize = E.db.tooltip.textFontSize
	_G.DatatextTooltipTextLeft1:FontTemplate(font, textSize, fontOutline)
	_G.DatatextTooltipTextRight1:FontTemplate(font, textSize, fontOutline)

	LDB.RegisterCallback(E, "LibDataBroker_DataObjectCreated", DT.SetupObjectLDB)
	DT:RegisterLDB() -- LibDataBroker
	DT:RegisterCustomCurrencyDT() -- Register all the user created currency datatexts from the "CustomCurrency" DT.

	for name, db in pairs(E.global.datatexts.panels) do
		DT:BuildPanel(name, db)
	end

	DT:RegisterEvent('PLAYER_ENTERING_WORLD', 'LoadDataTexts')
end

DT.RegisteredPanels = {}
DT.RegisteredDataTexts = {}
DT.UnitEvents = {
	UNIT_AURA = true,
	UNIT_RESISTANCES = true,
	UNIT_STATS = true,
	UNIT_ATTACK_POWER = true,
	UNIT_RANGED_ATTACK_POWER = true,
	UNIT_TARGET = true,
	UNIT_SPELL_HASTE = true
}

DT.PanelPool = { InUse = {}, Free = {}, Count = 0 }

function DT:FetchFrame(givenName)
	local count = DT.PanelPool.Count
	local name = 'ElvUI_DTPanel' .. count
	local frame

	local poolName, poolFrame = next(DT.PanelPool.Free)
	if poolName then
		frame = poolFrame
		DT.PanelPool.Free[poolName] = nil
	else
		frame = CreateFrame('Frame', name, E.UIParent)
		DT.PanelPool.Count = DT.PanelPool.Count + 1
	end

	DT.PanelPool.InUse[givenName] = frame

	return frame
end

function DT:ReleasePanel(givenName)
	local panel = DT.PanelPool.InUse[givenName]
	if panel then
		panel:Hide()

		for _, dt in ipairs(panel.dataPanels) do
			dt:UnregisterAllEvents()
			dt:SetScript('OnUpdate', nil)
			dt:SetScript('OnEnter', nil)
			dt:SetScript('OnLeave', nil)
			dt:SetScript('OnClick', nil)
			dt.text:SetText(' ') -- Keep this as a space, it fixes init load in with a custom font added by a plugin. ~Simpy
		end

		UnregisterStateDriver(panel, 'visibility')
		E:DisableMover(panel.moverName)

		DT.PanelPool.Free[givenName] = panel
		DT.PanelPool.InUse[givenName] = nil
		DT.RegisteredPanels[givenName] = nil
	end
end

function DT:BuildPanel(name, db)
	local Panel = DT:FetchFrame(name)
	Panel:Point('CENTER')
	Panel:Size(100, 10)

	local MoverName = 'DTPanel'..name..'Mover'
	Panel.moverName = MoverName
	Panel.givenName = name

	if not E:HasMover(MoverName) then
		E:CreateMover(Panel, MoverName, name, nil, nil, nil, nil, nil, 'general,solo')
	end

	DT:UpdateDTPanelAttributes(name, db)
end

function DT:UpdateDTPanelAttributes(name, db)
	local Panel = DT.PanelPool.InUse[name]

	Panel:Size(db.width, db.height)
	Panel:SetFrameStrata(db.frameStrata)
	Panel:SetFrameLevel(db.frameLevel)
	Panel:SetTemplate(db.backdrop and (db.panelTransparency and 'Transparent' or 'Default') or 'NoBackdrop', true)

	E:TogglePixelBorders(Panel, db.backdrop and db.border)
	DT:RegisterPanel(Panel, db.numPoints, db.tooltipAnchor, db.tooltipXOffset, db.tooltipYOffset, db.growth == 'VERTICAL')

	if DT.db.panels[name].enable then
		E:EnableMover(Panel.moverName)
		RegisterStateDriver(Panel, "visibility", db.visibility)
	else
		UnregisterStateDriver(Panel, "visibility")
		Panel:Hide()
		E:DisableMover(Panel.moverName)
	end
end

local LDBHex = '|cffFFFFFF'
function DT:BuildPanelFunctions(name, obj)
	local panel

	local function OnEnter(dt)
		DT:SetupTooltip(dt)
		if obj.OnTooltipShow then obj.OnTooltipShow(DT.tooltip) end
		if obj.OnEnter then obj.OnEnter(dt) end
		DT.tooltip:Show()
	end

	local function OnLeave(dt)
		if obj.OnLeave then obj.OnLeave(dt) end
		DT.tooltip:Hide()
	end

	local function OnClick(dt, button)
		if obj.OnClick then obj.OnClick(dt, button) end
	end

	local function UpdateText(_, Name, _, Value)
		if Value == nil or (strlen(Value) >= 3) or Value == 'n/a' or Name == Value then
			panel.text:SetText(Value ~= 'n/a' and Value or Name)
		else
			panel.text:SetFormattedText("%s: %s%s|r", Name, LDBHex, Value)
		end
	end

	local function OnCallback(newHex)
		if name and obj then
			LDBHex = newHex
			LDB.callbacks:Fire("LibDataBroker_AttributeChanged_"..name.."_text", name, nil, obj.text, obj)
		end
	end

	local function OnEvent(dt)
		panel = dt
		LDB:RegisterCallback("LibDataBroker_AttributeChanged_"..name.."_text", UpdateText)
		LDB:RegisterCallback("LibDataBroker_AttributeChanged_"..name.."_value", UpdateText)
		OnCallback(LDBHex)
	end

	return OnEnter, OnLeave, OnClick, OnCallback, OnEvent, UpdateText
end

function DT:SetupObjectLDB(name, obj)
	local onEnter, onLeave, onClick, onCallback, onEvent = DT:BuildPanelFunctions(name, obj)
	local data = DT:RegisterDatatext(name, nil, onEvent, nil, onClick, onEnter, onLeave)
	E.valueColorUpdateFuncs[onCallback] = true
	data.isLibDataBroker = true

	-- Update config if it has been loaded
	if DT.PanelLayoutOptions then
		DT:PanelLayoutOptions()
	end
end

function DT:RegisterLDB()
	for name, obj in LDB:DataObjectIterator() do
		DT:SetupObjectLDB(name, obj)
	end
end

function DT:GetDataPanelPoint(panel, i, numPoints, vertical)
	if numPoints == 1 then
		return 'CENTER', panel, 'CENTER'
	else
		local point, relativePoint, xOffset, yOffset = 'LEFT', i == 1 and 'LEFT' or 'RIGHT', 4, 0
		if vertical then
			point, relativePoint, xOffset, yOffset = 'TOP', i == 1 and 'TOP' or 'BOTTOM', 0, -4
		end

		local lastPanel = (i == 1 and panel) or panel.dataPanels[i - 1]
		return point, lastPanel, relativePoint, xOffset, yOffset
	end
end

function DT:UpdatePanelDimensions()
	local panelWidth, panelHeight = self:GetSize()
	local width, height = (panelWidth / self.numPoints) - 4, panelHeight - 4
	if self.vertical then
		width, height = panelWidth - 4, (panelHeight / self.numPoints) - 4
	end

	for i, dt in ipairs(self.dataPanels) do
		dt:SetShown(i <= self.numPoints)
		dt:Size(width, height)
		dt:ClearAllPoints()
		dt:Point(DT:GetDataPanelPoint(self, i, self.numPoints, self.vertical))
	end
end

function DT:Data_OnLeave()
	DT.tooltip:Hide()
end

function DT:SetupTooltip(panel)
	local parent = panel:GetParent()
	DT.tooltip:Hide()
	DT.tooltip:SetOwner(parent, parent.anchor, parent.xOff, parent.yOff)
	DT.tooltip:ClearLines()

	if not _G.GameTooltip:IsForbidden() then
		_G.GameTooltip:Hide() -- WHY??? BECAUSE FUCK GAMETOOLTIP, THATS WHY!!
	end
end

function DT:RegisterPanel(panel, numPoints, anchor, xOff, yOff, vertical)
	local realName = panel:GetName()
	local name = panel.givenName or realName

	if not name then
		E:Print('DataTexts: Requires a panel name.')
		return
	end

	DT.RegisteredPanels[name] = panel
	panel.dataPanels = panel.dataPanels or {}
	panel.numPoints = numPoints
	panel.xOff = xOff
	panel.yOff = yOff
	panel.anchor = anchor
	panel.vertical = vertical

	if not E.db.datatexts.panels[name] then
		E.db.datatexts.panels[name] = { enable = false }

		for i = 1, numPoints do
			E.db.datatexts.panels[name][i] = ''
		end
	end

	for i = 1, numPoints do
		local dt = panel.dataPanels[i]
		if not dt then
			dt = CreateFrame('Button', realName..'_DataText'..i, panel)
			dt:RegisterForClicks("AnyUp")

			dt.text = dt:CreateFontString(nil, 'OVERLAY')
			dt.text:SetAllPoints()
			dt.text:SetJustifyH("CENTER")
			dt.text:SetJustifyV("MIDDLE")

			panel.dataPanels[i] = dt
		end
	end

	panel:HookScript('OnSizeChanged', DT.UpdatePanelDimensions)
	DT.UpdatePanelDimensions(panel)
end

function DT:AssignPanelToDataText(panel, data, event, ...)
	data.panel = panel
	panel.name = data.name or ""

	if data.events then
		for _, ev in pairs(data.events) do
			if data.objectEvent then
				if not E:HasFunctionForObject(ev, data.objectEvent, data.objectEventFunc) then
					E:RegisterEventForObject(ev, data.objectEvent, data.objectEventFunc)
				end
			elseif data.eventFunc then
				if DT.UnitEvents[ev] then
					pcall(panel.RegisterUnitEvent, panel, ev, 'player')
				else
					pcall(panel.RegisterEvent, panel, ev)
				end
			end
		end
	end

	local ev = event or 'ELVUI_FORCE_UPDATE'
	if data.objectEvent then
		data.objectEventFunc(data.objectEvent, ev, ...)
	elseif data.eventFunc then
		panel:SetScript('OnEvent', data.eventFunc)
		data.eventFunc(panel, ev, ...)
	end

	if data.onUpdate then
		panel:SetScript('OnUpdate', data.onUpdate)
		data.onUpdate(panel, 20000)
	end

	if data.onClick then
		panel:SetScript('OnClick', function(p, button)
			if E.db.datatexts.noCombatClick and InCombatLockdown() then return end
			data.onClick(p, button)
		end)
	end

	if data.onEnter then
		panel:SetScript('OnEnter', function(p)
			if E.db.datatexts.noCombatHover and InCombatLockdown() then return end
			data.onEnter(p)
		end)
	end

	panel:SetScript('OnLeave', data.onLeave or DT.Data_OnLeave)
end

function DT:LoadDataTexts(...)
	local font, fontSize, fontOutline = LSM:Fetch("font", DT.db.font), DT.db.fontSize, DT.db.fontOutline
	local inInstance, instanceType = IsInInstance()
	local isInPVP = inInstance and instanceType == "pvp"
	local isBGPanel, enableBGPanel

	for panel, db in pairs(E.global.datatexts.panels) do
		DT:UpdateDTPanelAttributes(panel, db)
	end

	for panelName, panel in pairs(DT.RegisteredPanels) do
		isBGPanel = isInPVP and (panelName == 'LeftChatDataPanel' or panelName == 'RightChatDataPanel')
		enableBGPanel = isBGPanel and (not DT.ForceHideBGStats and E.db.datatexts.battleground)

		--Restore Panels
		for i, dt in ipairs(panel.dataPanels) do
			dt:UnregisterAllEvents()
			dt:SetScript('OnUpdate', nil)
			dt:SetScript('OnEnter', nil)
			dt:SetScript('OnLeave', nil)
			dt:SetScript('OnClick', nil)
			dt.text:FontTemplate(font, fontSize, fontOutline)
			dt.text:SetWordWrap(DT.db.wordWrap)
			dt.text:SetText(' ') -- Keep this as a space, it fixes init load in with a custom font added by a plugin. ~Simpy
			dt.pointIndex = i

			if enableBGPanel then
				dt:RegisterEvent('UPDATE_BATTLEFIELD_SCORE')
				dt:SetScript('OnEvent', DT.UPDATE_BATTLEFIELD_SCORE)
				dt:SetScript('OnEnter', DT.BattlegroundStats)
				dt:SetScript('OnLeave', DT.Data_OnLeave)
				dt:SetScript('OnClick', DT.HideBattlegroundTexts)
				DT.UPDATE_BATTLEFIELD_SCORE(dt)
				DT.ShowingBGStats = true
			else
				-- we aren't showing BGStats anymore
				if (isBGPanel or not isInPVP) and DT.ShowingBGStats then
					DT.ShowingBGStats = nil
				end

				--Register Panel to Datatext
				for name, data in pairs(DT.RegisteredDataTexts) do
					for option, value in pairs(DT.db.panels) do
						if value and type(value) == 'table' then
							if option == panelName and DT.db.panels[option][i] and DT.db.panels[option][i] == name then
								DT:AssignPanelToDataText(dt, data, ...)
							end
						elseif value and type(value) == 'string' and value == name then
							if DT.db.panels[option] == name and option == panelName then
								DT:AssignPanelToDataText(dt, data, ...)
							end
						end
					end
				end
			end
		end
	end

	if DT.ForceHideBGStats then
		DT.ForceHideBGStats = nil
	end
end

--[[
	DT:RegisterDatatext(name, events, eventFunc, updateFunc, clickFunc, onEnterFunc, onLeaveFunc, localizedName)

	name - name of the datatext (required)
	events - must be a table with string values of event names to register
	eventFunc - function that gets fired when an event gets triggered
	updateFunc - onUpdate script target function
	click - function to fire when clicking the datatext
	onEnterFunc - function to fire OnEnter
	onLeaveFunc - function to fire OnLeave, if not provided one will be set for you that hides the tooltip.
	localizedName - localized name of the datetext
	objectEvent - register events on an object, using E.RegisterEventForObject instead of panel.RegisterEvent
]]
function DT:RegisterDatatext(name, events, eventFunc, updateFunc, clickFunc, onEnterFunc, onLeaveFunc, localizedName, objectEvent)
	if not name then error('Cannot register datatext no name was provided.') end
	local data = {name = name}

	if type(events) ~= 'table' and events ~= nil then
		error('Events must be registered as a table.')
	else
		data.events = events
		data.eventFunc = eventFunc
		data.objectEvent = objectEvent
		data.objectEventFunc = data.objectEvent and function(_, ...)
			if data.eventFunc then
				data.eventFunc(data.panel, ...)
			end
		end
	end

	if updateFunc and type(updateFunc) == 'function' then
		data.onUpdate = updateFunc
	end

	if clickFunc and type(clickFunc) == 'function' then
		data.onClick = clickFunc
	end

	if onEnterFunc and type(onEnterFunc) == 'function' then
		data.onEnter = onEnterFunc
	end

	if onLeaveFunc and type(onLeaveFunc) == 'function' then
		data.onLeave = onLeaveFunc
	end

	if localizedName and type(localizedName) == 'string' then
		data.localizedName = localizedName
	end

	DT.RegisteredDataTexts[name] = data

	return data
end

E:RegisterModule(DT:GetName())
