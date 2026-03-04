-- RaidMarkerPro
-- Keybind-triggered dropdown + per-marker keybinds for raid target markers
-- TBC Classic Anniversary (2.5.5 / Interface 20505)
--
-- SetRaidTarget() is NOT protected — called directly from OnClick handlers.
-- Buttons inherit SecureActionButtonTemplate so SetBindingClick works.
-- RegisterForClicks("AnyDown","AnyUp") for all ActionButtonUseKeyDown states.
-- GameTooltip:GetUnit() used as fallback when UnitExists("mouseover") is stale.

local ADDON_NAME = "RaidMarkerPro"
local RMP = CreateFrame("Frame", "RaidMarkerProFrame", UIParent)
RMP:RegisterEvent("ADDON_LOADED")
RMP:RegisterEvent("PLAYER_LOGIN")
RMP:RegisterEvent("UPDATE_MOUSEOVER_UNIT")

-- ─── Debug ───────────────────────────────────────────────────────────────────
local debugMode = false
local function dbg(msg)
    if debugMode then print("|cff999999RMP-DBG|r " .. msg) end
end

-- ─── Saved Variables ─────────────────────────────────────────────────────────
RaidMarkerProDB = RaidMarkerProDB or {}

local defaults = {
    triggerKey       = "ALT-Q",
    dropdownOnEnemy  = true,
    dropdownOnFriend = true,
    toggleMode       = true,
    unitPriority     = "mouseover_then_target",
    markerBinds = {
        [1] = "ALT-1", [2] = "ALT-2", [3] = "ALT-3", [4] = "ALT-4",
        [5] = "ALT-5", [6] = "ALT-6", [7] = "ALT-7", [8] = "ALT-8",
        [9] = "ALT-9",
    },
}

local MARKERS = {
    { index = 1, name = "Star",     icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1" },
    { index = 2, name = "Circle",   icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_2" },
    { index = 3, name = "Diamond",  icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3" },
    { index = 4, name = "Triangle", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4" },
    { index = 5, name = "Moon",     icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5" },
    { index = 6, name = "Square",   icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6" },
    { index = 7, name = "Cross",    icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7" },
    { index = 8, name = "Skull",    icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8" },
    { index = 0, name = "Clear",    icon = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"          },
}

local UNIT_PRIORITY_OPTIONS = {
    { value = "mouseover",             label = "Mouseover only" },
    { value = "target",                label = "Target only" },
    { value = "mouseover_then_target", label = "Mouseover, then target" },
}

-- ─── Mouseover Cache ─────────────────────────────────────────────────────────
local mouseoverGUID    = nil
local mouseoverIsEnemy = nil
local mouseoverTime    = 0
local MOUSEOVER_GRACE  = 0.6

-- ─── GUID → UnitID (no nameplateN in TBC Classic) ───────────────────────────
local function FindUnitByGUID(guid)
    if not guid then return nil end
    if UnitExists("mouseover") and UnitGUID("mouseover") == guid then return "mouseover" end
    if UnitExists("target")    and UnitGUID("target")    == guid then return "target" end
    if UnitExists("focus")     and UnitGUID("focus")     == guid then return "focus" end
    if UnitExists("pet")       and UnitGUID("pet")       == guid then return "pet" end
    for i = 1, 5 do
        local u = "boss" .. i
        if UnitExists(u) and UnitGUID(u) == guid then return u end
    end
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) and UnitGUID(u) == guid then return u end
    end
    for i = 1, 40 do
        local u = "raid" .. i
        if UnitExists(u) and UnitGUID(u) == guid then return u end
    end

    return nil
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────
local function DB() return RaidMarkerProDB end

local function CanMark()
    if IsInRaid() then
        return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
    end
    return true
end

-- Resolve the best available unit to mark.
-- Priority chain:
--   1. UnitExists("mouseover")          — standard mouseover check
--   2. GameTooltip:GetUnit()             — tooltip can persist after mouseover clears
--   3. Cached GUID matching target       — mouseover just disappeared, target matches
--   4. UnitExists("target")             — plain target fallback
local function GetMarkUnit()
    local prio = DB().unitPriority or "mouseover_then_target"

    if prio ~= "target" then
        -- (1) Direct mouseover
        if UnitExists("mouseover") then
            dbg("GetMarkUnit: mouseover exists")
            return "mouseover"
        end

        -- (2) GameTooltip fallback — tooltip may still reference the unit
        local ttName, ttUnit = GameTooltip:GetUnit()
        if ttUnit and UnitExists(ttUnit) then
            dbg("GetMarkUnit: tooltip unit=" .. ttUnit .. " name=" .. (ttName or "?"))
            return ttUnit
        end

        -- (3) Cached GUID — mouseover recently vanished, check if target matches
        if mouseoverGUID and (GetTime() - mouseoverTime) < MOUSEOVER_GRACE then
            if UnitExists("target") and UnitGUID("target") == mouseoverGUID then
                dbg("GetMarkUnit: cached GUID matches target")
                return "target"
            end
        end

        if prio == "mouseover" then
            dbg("GetMarkUnit: mouseover-only mode, no unit found")
            return nil
        end
    end

    -- (4) Target fallback
    if UnitExists("target") then
        dbg("GetMarkUnit: using target")
        return "target"
    end

    dbg("GetMarkUnit: no unit found")
    return nil
end

local function ApplyMarker(markerIndex)
    if not CanMark() then return end
    local unit = GetMarkUnit()
    if not unit then return end

    dbg("ApplyMarker(" .. markerIndex .. ") on " .. unit ..
        " (" .. (UnitName(unit) or "?") .. ")")

    if DB().toggleMode and markerIndex > 0 then
        local current = GetRaidTargetIndex(unit)
        if current and current == markerIndex then
            SetRaidTarget(unit, 0)
            return
        end
    end
    SetRaidTarget(unit, markerIndex)
end

local function ShouldHandleSecureClick(down)
    if down == nil then return true end
    if GetCVarBool and GetCVarBool("ActionButtonUseKeyDown") then
        return down
    end
    return not down
end

-- ─── Per-Marker Buttons ──────────────────────────────────────────────────────
-- Inherit SecureActionButtonTemplate so SetBindingClick works properly.
-- OnClick handler calls SetRaidTarget directly (not protected, no macrotext needed).

local markerButtons = {}

local function CreateMarkerButtons()
    if #markerButtons > 0 then return end
    for i, m in ipairs(MARKERS) do
        local idx = m.index
        local btn = CreateFrame("Button", "RMPMarkerBtn" .. i, UIParent, "SecureActionButtonTemplate")
        btn:RegisterForClicks("AnyDown", "AnyUp")
        btn:SetScript("OnClick", function(_, _, down)
            if ShouldHandleSecureClick(down) then
                ApplyMarker(idx)
            end
        end)
        markerButtons[i] = btn
    end
end

local function RegisterMarkerBindings()
    for i = 1, #MARKERS do
        local k1, k2 = GetBindingKey("CLICK RMPMarkerBtn" .. i .. ":LeftButton")
        if k1 then SetBinding(k1) end
        if k2 then SetBinding(k2) end
        local bind = DB().markerBinds and DB().markerBinds[i]
        if bind and bind ~= "" then
            SetBinding(bind) -- unbind existing action on this combo first
            SetBindingClick(bind, "RMPMarkerBtn" .. i)
        end
    end
end

local function SaveAllBindings()
    if GetCurrentBindingSet then SaveBindings(GetCurrentBindingSet()) end
end

local function NormalizeBind(combo)
    if not combo then return "" end
    return strupper(combo)
end

local function UnbindConflictingAddonBinds(combo, ownerType, ownerIndex)
    if not combo or combo == "" then return end
    local norm = NormalizeBind(combo)

    if ownerType ~= "trigger" and NormalizeBind(DB().triggerKey or "") == norm then
        DB().triggerKey = ""
    end

    if not DB().markerBinds then DB().markerBinds = {} end
    for i = 1, #MARKERS do
        if not (ownerType == "marker" and ownerIndex == i) then
            if NormalizeBind(DB().markerBinds[i] or "") == norm then
                DB().markerBinds[i] = ""
            end
        end
    end
end

-- ─── Keybind Capture ─────────────────────────────────────────────────────────
local activeCapture = nil

local function KeyComboToString(key)
    if not key or key == "ESCAPE" or key == "UNKNOWN" then return nil end
    if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
       or key == "LALT" or key == "RALT" then return nil end
    local parts = {}
    if IsAltKeyDown() then tinsert(parts, "ALT") end
    if IsControlKeyDown() then tinsert(parts, "CTRL") end
    if IsShiftKeyDown() then tinsert(parts, "SHIFT") end
    tinsert(parts, key)
    return table.concat(parts, "-")
end

local captureFrame = CreateFrame("Frame", "RMPKeyCaptureFrame", UIParent)
captureFrame:EnableKeyboard(false)
captureFrame:SetPropagateKeyboardInput(true)
captureFrame:SetScript("OnKeyDown", function(self, key)
    if not activeCapture then return end
    if key == "ESCAPE" then
        self:SetPropagateKeyboardInput(true)
        self:EnableKeyboard(false)
        local btn = activeCapture
        activeCapture = nil
        btn:SetText(btn.currentBind or "Not Bound")
        btn:UnlockHighlight()
        return
    end
    local combo = KeyComboToString(key)
    if not combo then return end
    self:SetPropagateKeyboardInput(true)
    self:EnableKeyboard(false)
    local btn = activeCapture
    activeCapture = nil
    btn.currentBind = combo
    btn:SetText(combo)
    btn:UnlockHighlight()
    if btn.onCapture then btn.onCapture(combo) end
end)

local function CancelCapture()
    if activeCapture then
        activeCapture:SetText(activeCapture.currentBind or "Not Bound")
        activeCapture:UnlockHighlight()
        activeCapture = nil
        captureFrame:EnableKeyboard(false)
        captureFrame:SetPropagateKeyboardInput(true)
    end
end

local function StartCapture(btn)
    if activeCapture and activeCapture ~= btn then CancelCapture() end
    activeCapture = btn
    btn:SetText("|cff00ff00Press a key...|r")
    btn:LockHighlight()
    captureFrame:EnableKeyboard(true)
    captureFrame:SetPropagateKeyboardInput(false)
end

local function CreateCaptureButton(parent, width)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width or 150, 22)
    btn.currentBind = ""
    btn:SetScript("OnClick", function(self) StartCapture(self) end)
    return btn
end

-- ─── Dropdown ────────────────────────────────────────────────────────────────
local dropdown = CreateFrame("Frame", "RaidMarkerProDropdown", UIParent, "UIDropDownMenuTemplate")
local dropdownGUID = nil
local dropdownName = nil

local function ApplyMarkerByGUID(markerIndex)
    if not CanMark() then return end
    local unit = FindUnitByGUID(dropdownGUID)
    if not unit then
        if UnitExists("target") then
            unit = "target"
            dbg("Dropdown: GUID lost, using target")
        else
            print("|cff00ccffRaidMarkerPro|r Unit lost — target it first, or use direct keybinds while hovering.")
            return
        end
    else
        dbg("Dropdown: resolved " .. unit .. " (" .. (UnitName(unit) or "?") .. ")")
    end

    if DB().toggleMode and markerIndex > 0 then
        local current = GetRaidTargetIndex(unit)
        if current and current == markerIndex then
            SetRaidTarget(unit, 0)
            return
        end
    end
    SetRaidTarget(unit, markerIndex)
end

local function InitDropdown(self, level)
    local info = UIDropDownMenu_CreateInfo()
    info.text = "|cffffcc00Mark: " .. (dropdownName or "Target") .. "|r"
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info, level)
    for _, m in ipairs(MARKERS) do
        local marker = m
        info = UIDropDownMenu_CreateInfo()
        info.text = "|T" .. marker.icon .. ":16:16:2:0|t " .. marker.name
        info.notCheckable = true
        info.func = function()
            ApplyMarkerByGUID(marker.index)
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info, level)
    end
end
UIDropDownMenu_Initialize(dropdown, InitDropdown, "MENU")

-- ─── Dropdown Trigger ────────────────────────────────────────────────────────
local triggerBtn

local function ShowMarkerDropdown()
    if not CanMark() then return end
    local unit
    local prio = DB().unitPriority or "mouseover_then_target"

    if prio ~= "target" then
        if UnitExists("mouseover") then
            unit = "mouseover"
        else
            -- Try tooltip
            local ttName, ttUnit = GameTooltip:GetUnit()
            if ttUnit and UnitExists(ttUnit) then
                unit = ttUnit
            elseif mouseoverGUID and (GetTime() - mouseoverTime) < MOUSEOVER_GRACE then
                unit = FindUnitByGUID(mouseoverGUID)
            end
        end
        if not unit and prio == "mouseover" then return end
    end
    if not unit and UnitExists("target") then unit = "target" end
    if not unit then return end

    local isEnemy = UnitCanAttack("player", unit)
    if isEnemy and not DB().dropdownOnEnemy then return end
    if (not isEnemy) and not DB().dropdownOnFriend then return end

    CloseDropDownMenus()

    dropdownGUID = UnitGUID(unit)
    dropdownName = UnitName(unit) or "Unknown"
    dbg("Dropdown: " .. unit .. " (" .. dropdownName .. ") enemy=" .. tostring(isEnemy))

    ToggleDropDownMenu(1, nil, dropdown, "cursor", 0, -10)
end

local function CreateTriggerButton()
    if triggerBtn then return end
    triggerBtn = CreateFrame("Button", "RMPTriggerBtn", UIParent, "SecureActionButtonTemplate")
    triggerBtn:RegisterForClicks("AnyDown", "AnyUp")
    triggerBtn:SetScript("OnClick", function(_, _, down)
        if ShouldHandleSecureClick(down) then
            ShowMarkerDropdown()
        end
    end)
end

local function RegisterTriggerBinding()
    local k1, k2 = GetBindingKey("CLICK RMPTriggerBtn:LeftButton")
    if k1 then SetBinding(k1) end
    if k2 then SetBinding(k2) end
    local bind = DB().triggerKey
    if bind and bind ~= "" then
        SetBinding(bind) -- unbind existing action on this combo first
        SetBindingClick(bind, "RMPTriggerBtn")
    end
end

-- ─── Config Frame ────────────────────────────────────────────────────────────
local configFrame, configBuilt

local function BuildConfigFrame()
    if configBuilt then return configFrame end

    local ok, frame = pcall(CreateFrame, "Frame", "RaidMarkerProConfig", UIParent, "BasicFrameTemplateWithInset")
    if ok and frame then
        configFrame = frame
    else
        configFrame = CreateFrame("Frame", "RaidMarkerProConfig", UIParent)
        configFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 }
        })
        local cb = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
        cb:SetPoint("TOPRIGHT", -2, -2)
    end

    configFrame:SetSize(420, 590)
    configFrame:SetPoint("CENTER")
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", configFrame.StartMoving)
    configFrame:SetScript("OnDragStop", configFrame.StopMovingOrSizing)
    configFrame:SetFrameStrata("HIGH")
    configFrame:SetScript("OnHide", function() CancelCapture(); CloseDropDownMenus() end)

    if configFrame.TitleText then
        configFrame.TitleText:SetText("RaidMarkerPro")
    else
        local tt = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tt:SetPoint("TOP", 0, -6)
        tt:SetText("|cff00ccffRaidMarkerPro|r")
    end

    local y = -32

    -- Unit Priority
    local prioHeader = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    prioHeader:SetPoint("TOPLEFT", 16, y)
    prioHeader:SetText("|cffffcc00Unit Priority|r")
    configFrame.prioRadios = {}
    for idx, opt in ipairs(UNIT_PRIORITY_OPTIONS) do
        local radio = CreateFrame("CheckButton", "RMPPrio" .. idx, configFrame, "UIRadioButtonTemplate")
        radio:SetPoint("TOPLEFT", 16, y - (idx * 18))
        radio.text:SetText(opt.label)
        radio.value = opt.value
        radio:SetScript("OnClick", function(s)
            DB().unitPriority = s.value
            RaidMarkerPro_RefreshConfig()
        end)
        configFrame.prioRadios[idx] = radio
    end
    y = y - (#UNIT_PRIORITY_OPTIONS * 18) - 24

    -- Dropdown Trigger
    local secHeader = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    secHeader:SetPoint("TOPLEFT", 16, y)
    secHeader:SetText("|cffffcc00Dropdown Trigger|r")
    local trigHint = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    trigHint:SetPoint("TOPLEFT", secHeader, "BOTTOMLEFT", 0, -2)
    trigHint:SetText("Click the button, then press the key combo you want")
    local trigCapBtn = CreateCaptureButton(configFrame, 160)
    trigCapBtn:SetPoint("TOPLEFT", trigHint, "BOTTOMLEFT", 0, -4)
    trigCapBtn.onCapture = function(combo)
        UnbindConflictingAddonBinds(combo, "trigger")
        DB().triggerKey = combo
        RegisterTriggerBinding(); RegisterMarkerBindings(); SaveAllBindings()
        RaidMarkerPro_RefreshConfig()
    end
    configFrame.trigCapBtn = trigCapBtn
    local trigClearBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    trigClearBtn:SetSize(60, 22)
    trigClearBtn:SetPoint("LEFT", trigCapBtn, "RIGHT", 4, 0)
    trigClearBtn:SetText("Clear")
    trigClearBtn:SetScript("OnClick", function()
        DB().triggerKey = ""
        RegisterTriggerBinding(); SaveAllBindings()
        trigCapBtn.currentBind = ""; trigCapBtn:SetText("Not Bound")
    end)
    y = y - 60

    -- Per-Marker Keybinds
    local mkHeader = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mkHeader:SetPoint("TOPLEFT", 16, y)
    mkHeader:SetText("|cffffcc00Direct Marker Keybinds|r")
    local mkHint = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mkHint:SetPoint("TOPLEFT", mkHeader, "BOTTOMLEFT", 0, -2)
    mkHint:SetText("Hover a unit and press the key — works on any unit")
    y = y - 30

    configFrame.markerCapBtns = {}
    for i, m in ipairs(MARKERS) do
        local rowY = y - ((i - 1) * 26)
        local icon = configFrame:CreateTexture(nil, "OVERLAY")
        icon:SetSize(18, 18); icon:SetPoint("TOPLEFT", 16, rowY); icon:SetTexture(m.icon)
        local lbl = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl:SetPoint("LEFT", icon, "RIGHT", 4, 0); lbl:SetWidth(55); lbl:SetJustifyH("LEFT"); lbl:SetText(m.name)
        local capBtn = CreateCaptureButton(configFrame, 130)
        capBtn:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
        capBtn.idx = i
        capBtn.onCapture = function(combo)
            UnbindConflictingAddonBinds(combo, "marker", i)
            if not DB().markerBinds then DB().markerBinds = {} end
            DB().markerBinds[i] = combo
            RegisterTriggerBinding(); RegisterMarkerBindings(); SaveAllBindings()
            RaidMarkerPro_RefreshConfig()
        end
        local clrBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
        clrBtn:SetSize(50, 22); clrBtn:SetPoint("LEFT", capBtn, "RIGHT", 3, 0); clrBtn:SetText("Clear")
        clrBtn:SetScript("OnClick", function()
            if not DB().markerBinds then DB().markerBinds = {} end
            DB().markerBinds[i] = ""
            RegisterMarkerBindings(); SaveAllBindings()
            capBtn.currentBind = ""; capBtn:SetText("Not Bound")
        end)
        configFrame.markerCapBtns[i] = capBtn
    end
    y = y - (#MARKERS * 26) - 8

    -- Options
    local chkToggle = CreateFrame("CheckButton", nil, configFrame, "UICheckButtonTemplate")
    chkToggle:SetPoint("TOPLEFT", 12, y)
    chkToggle.text:SetText("Toggle mode (same keybind twice removes marker)")
    chkToggle:SetScript("OnClick", function(s) DB().toggleMode = s:GetChecked() and true or false end)
    configFrame.chkToggle = chkToggle

    local chkEnemy = CreateFrame("CheckButton", nil, configFrame, "UICheckButtonTemplate")
    chkEnemy:SetPoint("TOPLEFT", 12, y - 26)
    chkEnemy.text:SetText("Dropdown on enemy units")
    chkEnemy:SetScript("OnClick", function(s) DB().dropdownOnEnemy = s:GetChecked() and true or false end)
    configFrame.chkEnemy = chkEnemy

    local chkFriend = CreateFrame("CheckButton", nil, configFrame, "UICheckButtonTemplate")
    chkFriend:SetPoint("TOPLEFT", 12, y - 52)
    chkFriend.text:SetText("Dropdown on friendly units")
    chkFriend:SetScript("OnClick", function(s) DB().dropdownOnFriend = s:GetChecked() and true or false end)
    configFrame.chkFriend = chkFriend

    -- Bottom Buttons
    local resetBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    resetBtn:SetSize(130, 24); resetBtn:SetPoint("BOTTOMRIGHT", -12, 10); resetBtn:SetText("Reset Defaults")
    resetBtn:SetScript("OnClick", function()
        for k, v in pairs(defaults) do
            if type(v) == "table" then
                DB()[k] = {}; for kk, vv in pairs(v) do DB()[k][kk] = vv end
            else DB()[k] = v end
        end
        RegisterTriggerBinding(); RegisterMarkerBindings(); SaveAllBindings()
        RaidMarkerPro_RefreshConfig()
    end)
    local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    closeBtn:SetSize(130, 24); closeBtn:SetPoint("BOTTOMLEFT", 12, 10); closeBtn:SetText("Close")
    closeBtn:SetScript("OnClick", function() configFrame:Hide() end)

    configBuilt = true
    return configFrame
end

function RaidMarkerPro_RefreshConfig()
    if not configFrame then return end
    configFrame.trigCapBtn.currentBind = DB().triggerKey or ""
    configFrame.trigCapBtn:SetText((DB().triggerKey or "") ~= "" and DB().triggerKey or "Not Bound")
    for i, capBtn in ipairs(configFrame.markerCapBtns) do
        local bind = (DB().markerBinds and DB().markerBinds[i]) or ""
        capBtn.currentBind = bind
        capBtn:SetText(bind ~= "" and bind or "Not Bound")
    end
    local prio = DB().unitPriority or "mouseover_then_target"
    for _, radio in ipairs(configFrame.prioRadios) do radio:SetChecked(radio.value == prio) end
    configFrame.chkToggle:SetChecked(DB().toggleMode)
    configFrame.chkEnemy:SetChecked(DB().dropdownOnEnemy)
    configFrame.chkFriend:SetChecked(DB().dropdownOnFriend)
end

function RaidMarkerPro_OpenConfig()
    BuildConfigFrame(); RaidMarkerPro_RefreshConfig()
    configFrame:Show(); configFrame:Raise()
end

-- ─── Settings Panel ──────────────────────────────────────────────────────────
local rmpCategory
local function CreateSettingsPanel()
    if not Settings or not Settings.RegisterCanvasLayoutCategory then return end
    local canvas = CreateFrame("Frame", "RaidMarkerProSettingsCanvas", UIParent)
    local title = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16); title:SetText("|cff00ccffRaidMarkerPro|r")
    local desc = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", 16, -40); desc:SetWidth(400); desc:SetJustifyH("LEFT")
    desc:SetText("Hover any unit and press a keybind to mark instantly, or use the dropdown.\nType /rmp to configure.")
    local openBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
    openBtn:SetSize(220, 30); openBtn:SetPoint("TOPLEFT", 16, -80); openBtn:SetText("Open Settings")
    openBtn:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then SettingsPanel:Hide() end
        RaidMarkerPro_OpenConfig()
    end)
    rmpCategory = Settings.RegisterCanvasLayoutCategory(canvas, "RaidMarkerPro")
    Settings.RegisterAddOnCategory(rmpCategory)
end

-- ─── Events ──────────────────────────────────────────────────────────────────
RMP:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        for k, v in pairs(defaults) do
            if type(v) == "table" then
                if not DB()[k] then DB()[k] = {} end
                for kk, vv in pairs(v) do if DB()[k][kk] == nil then DB()[k][kk] = vv end end
            else if DB()[k] == nil then DB()[k] = v end end
        end
    elseif event == "PLAYER_LOGIN" then
        CreateSettingsPanel()
        CreateTriggerButton()
        CreateMarkerButtons()
        RegisterTriggerBinding()
        RegisterMarkerBindings()
        SaveAllBindings()
        print("|cff00ccffRaidMarkerPro|r loaded — |cffffcc00/rmp|r settings. " ..
              "|cffffcc00" .. (DB().triggerKey or "ALT-Q") .. "|r dropdown, " ..
              "|cffffcc00ALT-1|r–|cffffcc008|r direct.")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        if UnitExists("mouseover") then
            mouseoverGUID    = UnitGUID("mouseover")
            mouseoverIsEnemy = UnitCanAttack("player", "mouseover")
            mouseoverTime    = GetTime()
            dbg("Mouseover: " .. (UnitName("mouseover") or "?") ..
                " enemy=" .. tostring(mouseoverIsEnemy))
        end
    end
end)

-- ─── Slash Commands ──────────────────────────────────────────────────────────
SLASH_RAIDMARKERPRO1 = "/rmp"
SLASH_RAIDMARKERPRO2 = "/raidmarker"
SlashCmdList["RAIDMARKERPRO"] = function(msg)
    msg = strtrim(msg:lower())
    if msg == "" or msg == "config" or msg == "settings" then
        CloseDropDownMenus(); RaidMarkerPro_OpenConfig()
    elseif msg == "options" then
        CloseDropDownMenus()
        if rmpCategory then Settings.OpenToCategory(rmpCategory:GetID())
        else RaidMarkerPro_OpenConfig() end
    elseif msg == "debug" then
        debugMode = not debugMode
        print("|cff00ccffRaidMarkerPro|r Debug: " .. (debugMode and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
    else
        print("|cff00ccffRaidMarkerPro|r — /rmp  /rmp options  /rmp debug")
    end
end
