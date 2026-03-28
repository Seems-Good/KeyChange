-- KeyChangeOptions.lua
-- Builds the addon settings panel (WoW Settings API, 10.0+)
-- Registered under AddOns → KeyChange in the game Options screen.

KeyChange = KeyChange or {}

-- ──────────────────────────────────────────────
-- Helpers
-- ──────────────────────────────────────────────

local function MakeHeader(parent, text, yOffset)
    local f = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    f:SetPoint("TOPLEFT", 16, yOffset)
    f:SetText(text)
    f:SetTextColor(1, 0.82, 0, 1)  -- WoW gold
    return f
end

local function MakeLine(parent, yOffset)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetSize(560, 1)
    t:SetPoint("TOPLEFT", 16, yOffset)
    t:SetColorTexture(0.4, 0.4, 0.4, 0.6)
    return t
end

local function MakeLabel(parent, text, yOffset, xOffset)
    local f = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f:SetPoint("TOPLEFT", xOffset or 16, yOffset)
    f:SetText(text)
    return f
end

-- Standard styled button matching the screenshot
local function MakeButton(parent, label, width, yOffset, xOffset)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(width or 160, 26)
    btn:SetPoint("TOPLEFT", xOffset or 16, yOffset)
    btn:SetText(label)
    return btn
end

-- ──────────────────────────────────────────────
-- Build the panel
-- ──────────────────────────────────────────────

local function BuildPanel(panel)
    local y = -10  -- running Y cursor (negative = downward)

    -- ── Position ──────────────────────────────
    MakeHeader(panel, "Position", y)
    y = y - 26
    MakeLine(panel, y)
    y = y - 14

    local btnShowWarning = MakeButton(panel, "Show Warning", 190, y, 16)
    btnShowWarning:SetScript("OnClick", function()
        KeyChange:ShowReminder("Change your key!")
    end)

    local btnHideWarning = MakeButton(panel, "Hide Warning", 190, y, 220)
    btnHideWarning:SetScript("OnClick", function()
        KeyChange:HideReminder()
    end)

    y = y - 34

    -- Drag-to-reposition toggle
    local dragging = false
    local btnDrag = MakeButton(panel, "Drag to Reposition", 190, y, 16)
    btnDrag:SetScript("OnClick", function()
        local lbl = KeyChangeLabel
        if not lbl then
            KeyChange:ShowReminder("Drag me!")
            lbl = KeyChangeLabel
        end
        if not dragging then
            lbl:EnableMouse(true)
            lbl:SetMovable(true)
            lbl:RegisterForDrag("LeftButton")
            lbl:SetScript("OnDragStart", function(self) self:StartMoving() end)
            lbl:SetScript("OnDragStop", function(self)
                self:StopMovingOrSizing()
                -- Save position relative to UIParent CENTER
                local point, _, _, x, y2 = self:GetPoint()
                KeyChange:Set("anchorPoint", point)
                KeyChange:Set("anchorX", math.floor(x + 0.5))
                KeyChange:Set("anchorY", math.floor(y2 + 0.5))
            end)
            btnDrag:SetText("Stop Dragging")
            dragging = true
        else
            lbl:EnableMouse(false)
            lbl:SetScript("OnDragStart", nil)
            lbl:SetScript("OnDragStop", nil)
            btnDrag:SetText("Drag to Reposition")
            dragging = false
        end
    end)

    local btnReset = MakeButton(panel, "Reset Position", 190, y, 220)
    btnReset:SetScript("OnClick", function()
        KeyChange:Set("anchorPoint", "CENTER")
        KeyChange:Set("anchorX", 0)
        KeyChange:Set("anchorY", 200)
        if KeyChangeLabel then
            KeyChangeLabel:ClearAllPoints()
            KeyChangeLabel:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
        end
    end)

    y = y - 44

    -- ── Font Size ──────────────────────────────
    MakeHeader(panel, "Font Size", y)
    y = y - 20
    MakeLine(panel, y)
    y = y - 10

    local sizeLabel = MakeLabel(panel, tostring(KeyChange:Get("fontSize") or 42) .. "pt", y, 300)

    local fontSlider = CreateFrame("Slider", "KeyChangeFontSlider", panel, "OptionsSliderTemplate")
    fontSlider:SetPoint("TOPLEFT", 16, y - 8)
    fontSlider:SetSize(270, 16)
    fontSlider:SetMinMaxValues(18, 96)
    fontSlider:SetValueStep(2)
    fontSlider:SetObeyStepOnDrag(true)
    fontSlider:SetValue(KeyChange:Get("fontSize") or 42)
    _G[fontSlider:GetName() .. "Low"]:SetText("18pt")
    _G[fontSlider:GetName() .. "High"]:SetText("96pt")
    _G[fontSlider:GetName() .. "Text"]:SetText("")
    fontSlider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val)
        KeyChange:Set("fontSize", val)
        sizeLabel:SetText(val .. "pt")
        -- Live preview
        if KeyChangeLabel and KeyChangeLabel:IsShown() then
            KeyChangeLabel.text:SetFont(STANDARD_TEXT_FONT, val, "OUTLINE")
        end
    end)

    y = y - 44

    -- ── Animation Speed ────────────────────────
    MakeHeader(panel, "Pulse Speed", y)
    y = y - 20
    MakeLine(panel, y)
    y = y - 10

    local pulseVal = KeyChange:Get("pulseSpeed") or 1.0
    local function pulseLabel(v)
        if v <= 0.4 then return "Fast"
        elseif v >= 1.8 then return "Slow"
        else return "Medium" end
    end
    local speedLabel = MakeLabel(panel, pulseLabel(pulseVal), y, 300)

    local pulseSlider = CreateFrame("Slider", "KeyChangePulseSlider", panel, "OptionsSliderTemplate")
    pulseSlider:SetPoint("TOPLEFT", 16, y - 1)
    pulseSlider:SetSize(270, 16)
    pulseSlider:SetMinMaxValues(0.3, 2.0)
    pulseSlider:SetValueStep(0.1)
    pulseSlider:SetObeyStepOnDrag(true)
    pulseSlider:SetValue(pulseVal)
    _G[pulseSlider:GetName() .. "Low"]:SetText("Fast")
    _G[pulseSlider:GetName() .. "High"]:SetText("Slow")
    _G[pulseSlider:GetName() .. "Text"]:SetText("")
    pulseSlider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val * 10 + 0.5) / 10  -- round to 1 decimal
        KeyChange:Set("pulseSpeed", val)
        speedLabel:SetText(pulseLabel(val))
        -- Live preview: update running animation if visible
        if KeyChangeLabel and KeyChangeLabel:IsShown() then
            local anims = { KeyChangeLabel.pulseGroup:GetAnimations() }
            local half = val / 2
            for _, anim in ipairs(anims) do
                anim:SetDuration(half)
            end
        end
    end)
    y = y - 46
    MakeHeader(panel, "Text Color", y)
    y = y - 20
    MakeLine(panel, y)
    y = y - 18

    local COLOR_LAYOUT = {
        { name = "RED",    label = "Red",    col = {1, 0.2, 0.2} },
        { name = "ORANGE", label = "Orange", col = {1, 0.6, 0} },
        { name = "YELLOW", label = "Yellow", col = {1, 1, 0} },
        { name = "WHITE",  label = "White",  col = {1, 1, 1} },
        { name = "CYAN",   label = "Cyan",   col = {0, 0.8, 1} },
        { name = "GREEN",  label = "Green",  col = {0, 1, 0.53} },
    }

    local BTN_W, BTN_H, GAP = 178, 26, 8
    for i, info in ipairs(COLOR_LAYOUT) do
        local col = (i - 1) % 3          -- 0, 1, 2
        local row = math.floor((i - 1) / 3)
        local bx = 16 + col * (BTN_W + GAP)
        local by = y - row * (BTN_H + GAP)

        local cb = MakeButton(panel, info.label, BTN_W, by, bx)
        cb:GetFontString():SetTextColor(info.col[1], info.col[2], info.col[3])
        cb:SetScript("OnClick", function()
            KeyChange:Set("color", info.name)
            -- Live preview
            if KeyChangeLabel and KeyChangeLabel:IsShown() then
                local hex = KeyChange:GetColorHex()
                local r = tonumber(hex:sub(3,4), 16) / 255
                local g = tonumber(hex:sub(5,6), 16) / 255
                local b = tonumber(hex:sub(7,8), 16) / 255
                KeyChangeLabel.text:SetTextColor(r, g, b, 1)
            end
        end)
    end

    y = y - 72

    -- ── Minimum Key Level ──────────────────────
    MakeHeader(panel, "Minimum Key Level", y)
    y = y - 26
    MakeLine(panel, y)
    y = y - 10

    MakeLabel(panel,
        "Only remind me when the key is at or above this level.\nSet to 0 to always remind.",
        y, 16)
    y = y - 38

    local minKeyLabel = MakeLabel(panel,
        "Level: " .. (KeyChange:Get("minKeyLevel") or 0) ..
        ((KeyChange:Get("minKeyLevel") or 0) == 0 and " (Always remind)" or ""),
        y, 300)

    local minKeySlider = CreateFrame("Slider", "KeyChangeMinKeySlider", panel, "OptionsSliderTemplate")
    minKeySlider:SetPoint("TOPLEFT", 16, y - 8)
    minKeySlider:SetSize(270, 16)
    minKeySlider:SetMinMaxValues(0, 30)
    minKeySlider:SetValueStep(1)
    minKeySlider:SetObeyStepOnDrag(true)
    minKeySlider:SetValue(KeyChange:Get("minKeyLevel") or 0)
    _G[minKeySlider:GetName() .. "Low"]:SetText("0")
    _G[minKeySlider:GetName() .. "High"]:SetText("30")
    _G[minKeySlider:GetName() .. "Text"]:SetText("")
    minKeySlider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val)
        KeyChange:Set("minKeyLevel", val)
        minKeyLabel:SetText("Level: " .. val .. (val == 0 and " (Always remind)" or ""))
    end)

    y = y - 44

    -- ── Debug ──────────────────────────────────
    MakeHeader(panel, "Debug", y)
    y = y - 26
    MakeLine(panel, y)
    y = y - 14

    local btnTest = MakeButton(panel, "Test Reminder", 190, y, 16)
    btnTest:SetScript("OnClick", function()
        KeyChange:ShowReminder("Test — Change your key!")
    end)

    local btnPrintKey = MakeButton(panel, "Print Key Info", 190, y, 220)
    btnPrintKey:SetScript("OnClick", function()
        print("|cff00ccff[KeyChange]-@project-version@|r ── Key Info Debug ──")

        -- Helper to safely dump a table one level deep
        local function dumpVal(v)
            if type(v) == "table" then
                local parts = {}
                for k2, v2 in pairs(v) do
                    parts[#parts+1] = tostring(k2) .. "=" .. tostring(v2)
                end
                return "{" .. table.concat(parts, ", ") .. "}"
            end
            return tostring(v)
        end

        -- C_ChallengeMode.GetActiveKeystoneInfo
        if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
            local a, b, c = C_ChallengeMode.GetActiveKeystoneInfo()
            print("  GetActiveKeystoneInfo: " .. dumpVal(a) .. " | " .. dumpVal(b) .. " | " .. dumpVal(c))
        else
            print("  GetActiveKeystoneInfo: NOT AVAILABLE")
        end

        -- C_MythicPlus.GetOwnedKeystoneChallengeMapID
        if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneChallengeMapID then
            local a, b = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
            print("  GetOwnedKeystoneChallengeMapID: " .. dumpVal(a) .. " | " .. dumpVal(b))
        else
            print("  GetOwnedKeystoneChallengeMapID: NOT AVAILABLE")
        end

        -- C_MythicPlus.GetOwnedKeystoneLevel (TWW+)
        if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel then
            local lvl = C_MythicPlus.GetOwnedKeystoneLevel()
            print("  GetOwnedKeystoneLevel: " .. dumpVal(lvl))
        else
            print("  GetOwnedKeystoneLevel: NOT AVAILABLE")
        end

        -- C_MythicPlus.GetOwnedKeystoneMapID (alternate name seen in some builds)
        if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneMapID then
            local a, b = C_MythicPlus.GetOwnedKeystoneMapID()
            print("  GetOwnedKeystoneMapID: " .. dumpVal(a) .. " | " .. dumpVal(b))
        else
            print("  GetOwnedKeystoneMapID: NOT AVAILABLE")
        end

        print("|cff00ccff[KeyChange]|r ────────────────────")
    end)
end

-- ──────────────────────────────────────────────
-- Register with the Settings system
-- ──────────────────────────────────────────────

local optFrame = CreateFrame("Frame")
optFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "KeyChange" then
        -- Give the DB a moment to initialise, then build the panel
        C_Timer.After(0, function()
            local panel = CreateFrame("Frame")
            panel.name = "KeyChange"
            panel:Hide()  -- must be hidden at start; Settings system shows/hides it as needed

            BuildPanel(panel)

            local category = Settings.RegisterCanvasLayoutCategory(panel, "KeyChange")
            Settings.RegisterAddOnCategory(category)
            KeyChange.optionsCategory = category
            KeyChange.settingsCategory = category
        end)
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
optFrame:RegisterEvent("ADDON_LOADED")
