-- KeyChangeReminder.lua (Core.lua)
-- Core logic: events, keystone detection, reminder display
-- Target: Midnight 12.0.5+ — no backward-compat shims

KeyChangeReminder = KeyChangeReminder or {}

local frame = CreateFrame("Frame", "KeyChangeReminderFrame", UIParent)

local VERSION   = "@project-version@"
local TIMESTAMP = "@project-date-iso@"

-- COLOR CODES
local COLOR_YELLOW = "|cffffff00"
local COLOR_GRAY   = "|cff808080"
local COLOR_BLUE   = "|cff00ccff"
local FORMAT_NAME  = COLOR_BLUE .. "KeyChangeReminder[ KCR ]|r" .. COLOR_GRAY .. "-(" .. VERSION .. ")|r"
local FORMAT_SLUG  = COLOR_BLUE .. "[KeyChangeReminder]|r" .. COLOR_GRAY .. "-(" .. VERSION .. ")|r"

-- ──────────────────────────────────────────────
-- State machine
-- ──────────────────────────────────────────────
--
-- States:
--   IDLE          No run in progress.
--   STARTING      CHALLENGE_MODE_START fired; 5-second grace window is active.
--                 This window exists solely to eat Midnight's spurious
--                 CHALLENGE_MODE_RESET that fires right after key consumption.
--   IN_PROGRESS   Grace window elapsed; run is underway.
--   COMPLETED     CHALLENGE_MODE_COMPLETED fired AND onTime == true.
--   DEPLETED      CHALLENGE_MODE_RESET fired while IN_PROGRESS,
--                 OR CHALLENGE_MODE_COMPLETED fired with onTime == false.
--
-- Transitions:
--   IDLE         → STARTING     on CHALLENGE_MODE_START
--   STARTING     → IN_PROGRESS  after 5-second timer
--   IN_PROGRESS  → COMPLETED    on CHALLENGE_MODE_COMPLETED (onTime true)
--   IN_PROGRESS  → DEPLETED     on CHALLENGE_MODE_COMPLETED (onTime false) OR CHALLENGE_MODE_RESET
--   COMPLETED    → IDLE         after reminder fires (or is suppressed)
--   DEPLETED     → IDLE         immediately after state is recorded
--   ANY          → IDLE         on next CHALLENGE_MODE_START (stale-run guard)

local STATE_IDLE        = "IDLE"
local STATE_STARTING    = "STARTING"
local STATE_IN_PROGRESS = "IN_PROGRESS"
local STATE_COMPLETED   = "COMPLETED"
local STATE_DEPLETED    = "DEPLETED"

local runState = STATE_IDLE

-- ──────────────────────────────────────────────
-- Run-level bookkeeping
-- ──────────────────────────────────────────────

-- Level of the keystone for this run. Set authoritatively at COMPLETED via
-- C_ChallengeMode.GetCompletionInfo(), which is always reliable there.
-- A best-effort capture at START via GetSlottedKeystoneInfo() fills the field
-- early but is NOT relied upon as the sole source.
local lastRunLevel = nil

-- true  = WE put our keystone in the socket (C_PartyInfo.IsChallengeModeKeystoneOwner)
-- false = someone else's keystone is slotted
local ownKeyRun = false

-- Guards stale C_Timer.After callbacks.
local runGeneration = 0

-- ──────────────────────────────────────────────
-- Reminder display
-- ──────────────────────────────────────────────

local reminderLabel          = nil
local reminderWatching       = false
local talentReminderWatching = false

local function DismissReminder()
    if not reminderWatching then return end
    reminderWatching = false
    if not talentReminderWatching then
        frame:UnregisterEvent("ZONE_CHANGED_NEW_AREA")
    end
    if reminderLabel and reminderLabel:IsShown() then
        reminderLabel.pulseGroup:Stop()
        reminderLabel.exitGroup:Stop()
        reminderLabel:SetAlpha(1)
        reminderLabel.exitGroup:Play()
    end
end

local function DismissTalentReminder()
    if not talentReminderWatching then return end
    talentReminderWatching = false
    if not reminderWatching then
        frame:UnregisterEvent("ZONE_CHANGED_NEW_AREA")
    end
    if reminderLabel and reminderLabel:IsShown() then
        reminderLabel.pulseGroup:Stop()
        reminderLabel.exitGroup:Stop()
        reminderLabel:SetAlpha(1)
        reminderLabel.exitGroup:Play()
    end
end

local function GetOrCreateLabel()
    if reminderLabel then return reminderLabel end

    reminderLabel = CreateFrame("Frame", "KeyChangeReminderLabel", UIParent)
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

    -- Looping pulse
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

    -- Exit animation
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
        KeyChangeReminder:Get("anchorPoint") or "CENTER",
        UIParent,
        KeyChangeReminder:Get("anchorPoint") or "CENTER",
        KeyChangeReminder:Get("anchorX") or 0,
        KeyChangeReminder:Get("anchorY") or 200
    )
end

local function ApplyPulseSpeed()
    if not reminderLabel then return end
    local speed = KeyChangeReminder:Get("pulseSpeed") or 1.0
    local half = speed / 2
    local anims = { reminderLabel.pulseGroup:GetAnimations() }
    for _, anim in ipairs(anims) do
        anim:SetDuration(half)
    end
end

function KeyChangeReminder:ShowReminder(msg)
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

    print(string.format(FORMAT_SLUG .. "%s", msg))
end

function KeyChangeReminder:HideReminder()
    DismissReminder()
end

function KeyChangeReminder:ShowTalentReminder()
    self:ShowReminder("Switch to your M+ talents!")
    reminderWatching       = false
    talentReminderWatching = true
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
end

function KeyChangeReminder:HideTalentReminder()
    DismissTalentReminder()
end

-- ──────────────────────────────────────────────
-- Keystone API helpers (Midnight 12.0.5+)
-- ──────────────────────────────────────────────

-- Returns true when a Mythic+ run is currently active.
local function IsMythicPlusActive()
    return C_MythicPlus and C_MythicPlus.IsMythicPlusActive and C_MythicPlus.IsMythicPlusActive() == true
end

-- Returns the level of the keystone currently slotted in the font (nil if none).
-- Best-effort only — may return nil at START due to timing. Do NOT treat nil
-- here as authoritative; use GetRunCompletionInfo() at COMPLETED instead.
local function GetSlottedKeystoneLevel()
    if not (C_ChallengeMode and C_ChallengeMode.GetSlottedKeystoneInfo) then
        return nil
    end
    local _, _, level = C_ChallengeMode.GetSlottedKeystoneInfo()
    if type(level) == "number" and level > 0 then return level end
    return nil
end

-- Returns (level, onTime) for the run that just completed.
-- C_ChallengeMode.GetCompletionInfo() is the authoritative post-run source —
-- reliable at CHALLENGE_MODE_COMPLETED, same data BigWigs/Details read.
-- onTime == true  → timed finish; vendor reroll option appears.
-- onTime == false → overtime kill; vendor reroll never appears.
local function GetRunCompletionInfo()
    if not (C_ChallengeMode and C_ChallengeMode.GetCompletionInfo) then
        return nil, nil
    end
    local _, level, _, onTime = C_ChallengeMode.GetCompletionInfo()
    local lvl = (type(level) == "number" and level > 0) and level or nil
    local timed = (onTime == true)
    return lvl, timed
end

-- Returns the level of the keystone in OUR bag (nil if we have none).
local function GetBagKeystoneLevel()
    if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel) then
        return nil
    end
    local level = C_MythicPlus.GetOwnedKeystoneLevel()
    if type(level) == "number" and level > 0 then return level end
    return nil
end

-- Returns the challenge map ID of the keystone in OUR bag (nil if none).
local function GetBagKeystoneChallengeMapID()
    if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneChallengeMapID) then
        return nil
    end
    local id = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    if type(id) == "number" and id > 0 then return id end
    return nil
end

-- Returns the world map ID of the keystone in OUR bag (nil if none).
local function GetBagKeystoneMapID()
    if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneMapID) then
        return nil
    end
    local id = C_MythicPlus.GetOwnedKeystoneMapID()
    if type(id) == "number" and id > 0 then return id end
    return nil
end

-- Returns true if the LOCAL player is the keystone owner for the current run.
local function IsLocalPlayerKeystoneOwner()
    if C_PartyInfo and C_PartyInfo.IsChallengeModeKeystoneOwner then
        return C_PartyInfo.IsChallengeModeKeystoneOwner() == true
    end
    return false
end

-- ──────────────────────────────────────────────
-- Reminder suppression logic
-- ──────────────────────────────────────────────
--
-- AUTO MODE — show "Change your key!" when ALL of:
--   1. Run was completed in time (COMPLETED state, guaranteed by onTime check)
--   2. The keystone was NOT ours
--   3. The run key level >= our current bag key level
--
-- SUPPRESS when ANY of:
--   • Run was not completed in time (depleted / overtime / abandoned)
--   • It was our own keystone
--   • Run level is unknown (fail closed — no reminder on missing data)
--   • Run level < bag level (reroll would downgrade)
--   • We have no key in our bag
--
-- MANUAL MODE:
--   Suppress if run level is unknown OR below the user's configured minKeyLevel.
--
local function ShouldSuppressReminder(capturedLevel)
    local autoMode = KeyChangeReminder:Get("autoMode")
    local runLevel = capturedLevel or lastRunLevel

    if autoMode then
        -- Rule 1: must be a timed completion (guaranteed before this call,
        -- but kept as a safety net in case of unexpected state transitions).
        if runState ~= STATE_COMPLETED then return true end

        -- Rule 2: must be a foreign key run.
        if ownKeyRun then return true end

        -- Rule 3: run level must be known — fail closed, never fail open.
        if not runLevel then return true end

        -- Rule 4: must have a key in bag to reroll.
        local bagLevel = GetBagKeystoneLevel()
        if not bagLevel then return true end

        -- Rule 5: reroll must not downgrade.
        -- bagLevel > runLevel → reroll downgrade → suppress
        -- bagLevel <= runLevel → neutral or upgrade → SHOW
        if bagLevel > runLevel then return true end

        return false  -- SHOW

    else
        -- Manual mode: suppress on unknown level or below threshold.
        if not runLevel then return true end
        local minLevel = KeyChangeReminder:Get("minKeyLevel") or 0
        if minLevel > 0 and runLevel < minLevel then return true end
        return false
    end
end

-- Reset all per-run state back to neutral.
local function ResetRunState()
    runState     = STATE_IDLE
    lastRunLevel = nil
    ownKeyRun    = false
end

-- ──────────────────────────────────────────────
-- Events
-- ──────────────────────────────────────────────

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
frame:RegisterEvent("CHALLENGE_MODE_RESET")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

frame:SetScript("OnEvent", function(self, event, arg1)

    -- ── ADDON_LOADED ────────────────────────────────────────────────────────
    if event == "ADDON_LOADED" and arg1 == "KeyChangeReminder" then
        KeyChangeReminder:InitDB()
        print(FORMAT_SLUG .. "Type |cffffd700/keychange|r for options.")
        self:UnregisterEvent("ADDON_LOADED")

    -- ── CHALLENGE_MODE_START ────────────────────────────────────────────────
    -- Ownership and slotted level are read immediately — both reliable at START.
    -- GetSlottedKeystoneInfo() is a best-effort capture only; the authoritative
    -- level read happens at COMPLETED via GetCompletionInfo().
    --
    -- Grace window (5 s): solely to eat Midnight's spurious CHALLENGE_MODE_RESET
    -- that fires as a side-effect of key consumption.
    elseif event == "CHALLENGE_MODE_START" then
        runGeneration = runGeneration + 1
        local capturedGen = runGeneration

        runState     = STATE_STARTING
        ownKeyRun    = false
        lastRunLevel = nil

        DismissReminder()
        DismissTalentReminder()

        ownKeyRun    = IsLocalPlayerKeystoneOwner()
        lastRunLevel = GetSlottedKeystoneLevel()  -- best-effort; may be nil

        C_Timer.After(5, function()
            if runGeneration ~= capturedGen then return end
            if runState ~= STATE_STARTING   then return end

            if not IsMythicPlusActive() then
                ResetRunState()
                return
            end

            runState = STATE_IN_PROGRESS
        end)

    -- ── CHALLENGE_MODE_COMPLETED ────────────────────────────────────────────
    -- Fires for BOTH timed and overtime (out-of-time) kills.
    -- GetCompletionInfo() is authoritative here for level AND onTime.
    -- onTime == false → overtime kill → vendor never appears → treat as depletion.
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        if runState ~= STATE_IN_PROGRESS then return end

        -- Read authoritative completion data immediately — reliable at this event.
        local completionLevel, onTime = GetRunCompletionInfo()

        -- Overtime kill: CHALLENGE_MODE_COMPLETED fires but the key-change
        -- vendor does NOT appear. Treat identically to a mid-run reset.
        if not onTime then
            runState = STATE_DEPLETED
            ResetRunState()
            return
        end

        -- Authoritative level from GetCompletionInfo(); overrides the
        -- best-effort capture from START (which may have been nil).
        if completionLevel then
            lastRunLevel = completionLevel
        end
        -- If completionLevel is still nil here, ShouldSuppressReminder will
        -- return true (fail closed) — no reminder on unknown data.

        runState = STATE_COMPLETED
        local capturedGen   = runGeneration
        local capturedLevel = lastRunLevel  -- snapshot before async reset races

        C_Timer.After(3, function()
            if runGeneration ~= capturedGen then return end

            if not lastRunLevel then
                lastRunLevel = capturedLevel
            end

            if ShouldSuppressReminder(capturedLevel) then
                ResetRunState()
                return
            end

            KeyChangeReminder:ShowReminder("Change your key!")
            ResetRunState()
        end)

    -- ── CHALLENGE_MODE_RESET ────────────────────────────────────────────────
    -- Genuine mid-run depletion or abandon.
    -- The 5-second grace window in STARTING absorbs the spurious post-START fire.
    elseif event == "CHALLENGE_MODE_RESET" then
        if runState ~= STATE_IN_PROGRESS then return end

        runState = STATE_DEPLETED
        ResetRunState()

    -- ── PLAYER_REGEN_DISABLED ───────────────────────────────────────────────
    elseif event == "PLAYER_REGEN_DISABLED" then
        DismissReminder()
        DismissTalentReminder()

    -- ── PLAYER_ENTERING_WORLD ───────────────────────────────────────────────
    elseif event == "PLAYER_ENTERING_WORLD" then
        if reminderWatching and IsMythicPlusActive() then
            DismissReminder()
        end

        if KeyChangeReminder:Get("talentReminder") then
            C_Timer.After(3, function()
                if IsMythicPlusActive() then
                    KeyChangeReminder:ShowTalentReminder()
                end
            end)
        end

    -- ── ZONE_CHANGED_NEW_AREA ───────────────────────────────────────────────
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if not IsMythicPlusActive() then
            if reminderWatching       then DismissReminder()       end
            if talentReminderWatching then DismissTalentReminder() end
        end

    end
end)

-- ──────────────────────────────────────────────
-- Slash commands
-- ──────────────────────────────────────────────

SLASH_KEYCHANGE1 = "/keychange"
SLASH_KEYCHANGE2 = "/kcr"

SlashCmdList["KEYCHANGE"] = function(msg)
    local cmd = msg and msg:match("^%s*(%S+)") or ""

    if cmd:lower() == "debug" then
        local bagLevel          = GetBagKeystoneLevel()
        local bagChallengeMapID = GetBagKeystoneChallengeMapID()
        local bagMapID          = GetBagKeystoneMapID()
        local slotLevel         = GetSlottedKeystoneLevel()
        local completionLevel, completionOnTime = GetRunCompletionInfo()
        local isOwner           = IsLocalPlayerKeystoneOwner()
        local mpActive          = IsMythicPlusActive()
        local autoMode          = KeyChangeReminder:Get("autoMode")
        local minKeyLevel       = KeyChangeReminder:Get("minKeyLevel") or 0

        print(FORMAT_SLUG .. COLOR_YELLOW .. " Debug State:|r")
        print(COLOR_GRAY .. "  runState                  : |r" .. COLOR_YELLOW .. tostring(runState)           .. "|r")
        print(COLOR_GRAY .. "  runGeneration             : |r" .. COLOR_YELLOW .. tostring(runGeneration)       .. "|r")
        print(COLOR_GRAY .. "  lastRunLevel              : |r" .. COLOR_YELLOW .. tostring(lastRunLevel)        .. "|r")
        print(COLOR_GRAY .. "  ownKeyRun                 : |r" .. COLOR_YELLOW .. tostring(ownKeyRun)           .. "|r")
        print(COLOR_GRAY .. "  IsKeystoneOwner (now)     : |r" .. COLOR_YELLOW .. tostring(isOwner)             .. "|r")
        print(COLOR_GRAY .. "  IsMythicPlusActive (now)  : |r" .. COLOR_YELLOW .. tostring(mpActive)            .. "|r")
        print(COLOR_GRAY .. "  bagLevel (now)            : |r" .. COLOR_YELLOW .. tostring(bagLevel)            .. "|r")
        print(COLOR_GRAY .. "  bagChallengeMapID (now)   : |r" .. COLOR_YELLOW .. tostring(bagChallengeMapID)   .. "|r")
        print(COLOR_GRAY .. "  bagMapID (now)            : |r" .. COLOR_YELLOW .. tostring(bagMapID)            .. "|r")
        print(COLOR_GRAY .. "  slotLevel (now)           : |r" .. COLOR_YELLOW .. tostring(slotLevel)           .. "|r")
        print(COLOR_GRAY .. "  completionLevel (now)     : |r" .. COLOR_YELLOW .. tostring(completionLevel)     .. "|r")
        print(COLOR_GRAY .. "  completionOnTime (now)    : |r" .. COLOR_YELLOW .. tostring(completionOnTime)    .. "|r")
        print(COLOR_GRAY .. "  autoMode                  : |r" .. COLOR_YELLOW .. tostring(autoMode)            .. "|r")
        print(COLOR_GRAY .. "  minKeyLevel               : |r" .. COLOR_YELLOW .. tostring(minKeyLevel)         .. "|r")

        local reason
        if autoMode then
            if runState ~= STATE_COMPLETED then
                reason = "run not COMPLETED (state=" .. runState .. ") — suppress"
            elseif ownKeyRun then
                reason = "own key run — suppress (cannot reroll own key at vendor)"
            elseif not lastRunLevel then
                reason = "lastRunLevel nil — suppress (fail closed, unknown level)"
            elseif not GetBagKeystoneLevel() then
                reason = "no key in bag — suppress (nothing to reroll)"
            elseif GetBagKeystoneLevel() > lastRunLevel then
                reason = "bag(" .. GetBagKeystoneLevel() .. ") > run(" .. lastRunLevel .. ") — suppress (reroll would downgrade)"
            else
                reason = "bag(" .. tostring(GetBagKeystoneLevel()) .. ") <= run(" .. tostring(lastRunLevel) .. ") — SHOW reminder"
            end
        else
            if not lastRunLevel then
                reason = "lastRunLevel nil — suppress (fail closed, unknown level)"
            elseif minKeyLevel > 0 and lastRunLevel < minKeyLevel then
                reason = "run level " .. tostring(lastRunLevel) .. " below minKeyLevel " .. minKeyLevel .. " — suppress"
            else
                reason = "manual mode, threshold not met — SHOW reminder"
            end
        end
        print(COLOR_GRAY .. "  ShouldSuppress?           : |r" .. COLOR_YELLOW .. tostring(reason) .. "|r")

    else
        if KeyChangeReminder.optionsCategory then
            Settings.OpenToCategory(KeyChangeReminder.optionsCategory.ID)
        else
            print(FORMAT_SLUG .. "Options not ready yet.")
        end
    end
end
