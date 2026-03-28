-- KeyChange.lua
-- Core logic: events, keystone detection, reminder display

KeyChange = KeyChange or {}

local frame = CreateFrame("Frame", "KeyChangeFrame", UIParent)

-- Tracks whether a run is currently in progress
local runInProgress = false
local currentRunLevel = nil

-- ──────────────────────────────────────────────
-- Reminder display
-- ──────────────────────────────────────────────

local reminderLabel = nil
local reminderWatching = false

local function GetCurrentKeystoneState()
    local mapID, level = nil, nil
    if C_MythicPlus then
        if C_MythicPlus.GetOwnedKeystoneChallengeMapID then
            mapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
        end
        if C_MythicPlus.GetOwnedKeystoneLevel then
            level = C_MythicPlus.GetOwnedKeystoneLevel()
        end
    end
    return mapID, level
end

local function DismissReminder()
    if not reminderWatching then return end
    reminderWatching = false
    frame:UnregisterEvent("ZONE_CHANGED_NEW_AREA")
    if reminderLabel and reminderLabel:IsShown() then
        reminderLabel.pulseGroup:Stop()
        -- Quick final fade out
        reminderLabel.exitGroup:Stop()
        reminderLabel:SetAlpha(1)
        reminderLabel.exitGroup:Play()
    end
end

local function GetOrCreateLabel()
    if reminderLabel then return reminderLabel end

    reminderLabel = CreateFrame("Frame", "KeyChangeLabel", UIParent)
    reminderLabel:SetSize(600, 80)
    reminderLabel:SetMovable(true)
    reminderLabel:EnableMouse(false)
    reminderLabel:SetClampedToScreen(true)
    reminderLabel:SetFrameStrata("FULLSCREEN_DIALOG")

    local t = reminderLabel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetAllPoints()
    t:SetJustifyH("CENTER")
    t:SetJustifyV("MIDDLE")
    reminderLabel.text = t

    -- Looping pulse: fade out then fade back in, repeat
    local pulse = reminderLabel:CreateAnimationGroup()
    pulse:SetLooping("REPEAT")
    local fadeOut = pulse:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0.15)
    fadeOut:SetDuration(1)
    fadeOut:SetSmoothing("IN_OUT")
    fadeOut:SetOrder(1)
    local fadeIn = pulse:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0.15)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(1)
    fadeIn:SetSmoothing("IN_OUT")
    fadeIn:SetOrder(2)
    reminderLabel.pulseGroup = pulse

    -- Exit animation: quick fade to hidden
    local exit = reminderLabel:CreateAnimationGroup()
    exit:SetLooping("NONE")
    local exitFade = exit:CreateAnimation("Alpha")
    exitFade:SetFromAlpha(1)
    exitFade:SetToAlpha(0)
    exitFade:SetDuration(0.4)
    exit:SetScript("OnFinished", function() reminderLabel:Hide() end)
    reminderLabel.exitGroup = exit

    return reminderLabel
end

local function ApplyLabelPosition()
    local lbl = GetOrCreateLabel()
    lbl:ClearAllPoints()
    lbl:SetPoint(
        KeyChange:Get("anchorPoint") or "CENTER",
        UIParent,
        KeyChange:Get("anchorPoint") or "CENTER",
        KeyChange:Get("anchorX") or 0,
        KeyChange:Get("anchorY") or 200
    )
end

local function ApplyPulseSpeed()
    if not reminderLabel then return end
    local speed = KeyChange:Get("pulseSpeed") or 1.0
    -- Each animation is half the total cycle duration
    local half = speed / 2
    local anims = { reminderLabel.pulseGroup:GetAnimations() }
    for _, anim in ipairs(anims) do
        anim:SetDuration(half)
    end
end

function KeyChange:ShowReminder(msg)
    local lbl = GetOrCreateLabel()
    ApplyLabelPosition()
    ApplyPulseSpeed()

    local hex = self:GetColorHex()
    local r = tonumber(hex:sub(3, 4), 16) / 255
    local g = tonumber(hex:sub(5, 6), 16) / 255
    local b = tonumber(hex:sub(7, 8), 16) / 255

    local fs = self:Get("fontSize") or 42
    lbl.text:SetFont(STANDARD_TEXT_FONT, fs, "OUTLINE")
    lbl.text:SetTextColor(r, g, b, 1)
    lbl.text:SetText(msg)

    lbl.exitGroup:Stop()
    lbl.pulseGroup:Stop()
    lbl:SetAlpha(1)
    lbl:Show()
    lbl.pulseGroup:Play()

    reminderWatching = true
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

    print(string.format("|cff00ccff[KeyChange]|r %s", msg))
end

function KeyChange:HideReminder()
    DismissReminder()
end

-- ──────────────────────────────────────────────
-- Keystone helpers
-- ──────────────────────────────────────────────

-- Level of the currently active key (inside dungeon)
-- GetActiveKeystoneInfo returns an empty table for level in Midnight — not reliable.
-- We snapshot from the bag before the run starts instead.
local function GetActiveKeystoneLevel()
    if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
        local _, level = C_ChallengeMode.GetActiveKeystoneInfo()
        -- Handle Midnight returning level as a table
        if type(level) == "table" then
            level = level.level or level[1] or level.keystoneLevel
        end
        if type(level) == "number" and level > 0 then return level end
    end
    return nil
end

-- Level of the keystone in the player's bag.
-- GetOwnedKeystoneLevel() confirmed working in Midnight (returns numeric level directly).
local function GetBagKeystoneLevel()
    if C_MythicPlus then
        if C_MythicPlus.GetOwnedKeystoneLevel then
            local level = C_MythicPlus.GetOwnedKeystoneLevel()
            if type(level) == "number" and level > 0 then return level end
        end
        -- Older API fallback
        if C_MythicPlus.GetOwnedKeystoneChallengeMapID then
            local _, level = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
            if type(level) == "number" and level > 0 then return level end
        end
    end
    return nil
end

-- ──────────────────────────────────────────────
-- Events
-- ──────────────────────────────────────────────

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
frame:RegisterEvent("CHALLENGE_MODE_RESET")

frame:SetScript("OnEvent", function(self, event, arg1)

    if event == "ADDON_LOADED" and arg1 == "KeyChange" then
        KeyChange:InitDB()
        print("|cff00ccff[KeyChange]-v@project-version@|r Loaded. Type |cffffd700/keychange|r for options.")
        self:UnregisterEvent("ADDON_LOADED")  -- no longer needed after this point

    elseif event == "CHALLENGE_MODE_START" then
        -- Determine if this is our key or someone else's
        local ownedMapID = nil
        if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneChallengeMapID then
            ownedMapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
        end
        local activeMapID = nil
        if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
            activeMapID = C_ChallengeMode.GetActiveKeystoneInfo()
        end
        if ownedMapID and activeMapID and type(ownedMapID) == "number"
           and type(activeMapID) == "number" and ownedMapID == activeMapID then
            currentRunLevel = GetBagKeystoneLevel()
        else
            currentRunLevel = nil
        end
        runInProgress = false  -- block RESET during grace window
        -- Midnight fires CHALLENGE_MODE_RESET immediately after START when the key
        -- is consumed from the bag into the socket. Wait 5s before trusting a RESET
        -- as a genuine mid-run depletion.
        C_Timer.After(5, function()
            runInProgress = true
        end)

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        runInProgress = false
        C_Timer.After(3, function()
            local minLevel = KeyChange:Get("minKeyLevel") or 0
            if minLevel > 0 and currentRunLevel and currentRunLevel < minLevel then
                currentRunLevel = nil
                return
            end
            KeyChange:ShowReminder("Change your key!")
            currentRunLevel = nil
        end)

    elseif event == "CHALLENGE_MODE_RESET" then
        -- CHALLENGE_MODE_RESET fires both when a key is consumed at the START
        -- of a run AND when it depletes. Only remind if a run was actually in progress.
        if runInProgress then
            runInProgress = false
            C_Timer.After(2, function()
                KeyChange:ShowReminder("Change your key!")
                currentRunLevel = nil
            end)
        end
    elseif event == "ZONE_CHANGED_NEW_AREA" and reminderWatching then
        local inInstance = IsInInstance and select(2, IsInInstance()) ~= "none"
        if not inInstance then
            DismissReminder()
        end

    end  -- end if/elseif event chain
end)

-- ──────────────────────────────────────────────
-- Slash commands
-- ──────────────────────────────────────────────

SLASH_KEYCHANGE1 = "/keychange"

SlashCmdList["KEYCHANGE"] = function()
    if KeyChange.optionsCategory then
        Settings.OpenToCategory(KeyChange.optionsCategory.ID)
    else
        print("|cff00ccff[KeyChange]|r Options not ready yet.")
    end
end
