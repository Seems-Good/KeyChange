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
--   COMPLETED     CHALLENGE_MODE_COMPLETED fired (timed finish).
--   DEPLETED      CHALLENGE_MODE_RESET fired while IN_PROGRESS.
--
-- Transitions:
--   IDLE         → STARTING     on CHALLENGE_MODE_START
--   STARTING     → IN_PROGRESS  after 5-second timer
--   IN_PROGRESS  → COMPLETED    on CHALLENGE_MODE_COMPLETED
--   IN_PROGRESS  → DEPLETED     on CHALLENGE_MODE_RESET
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

-- Level of the keystone socketed for this run. Set at START via
-- C_ChallengeMode.GetSlottedKeystoneInfo(), which is reliable immediately.
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
-- Preferred over IsInInstance()+type checks for M+-specific gating.
-- C_MythicPlus.IsMythicPlusActive() → isMythicPlusActive
local function IsMythicPlusActive()
    return C_MythicPlus and C_MythicPlus.IsMythicPlusActive and C_MythicPlus.IsMythicPlusActive() == true
end

-- Returns the level of the keystone currently slotted in the font (nil if none).
-- No direct C_MythicPlus equivalent exists for the slotted/active level, so
-- C_ChallengeMode.GetSlottedKeystoneInfo() is still the correct call here.
-- Returns: mapChallengeModeID, affixIDs, keystoneLevel
local function GetSlottedKeystoneLevel()
    if not (C_ChallengeMode and C_ChallengeMode.GetSlottedKeystoneInfo) then
        return nil
    end
    local _, _, level = C_ChallengeMode.GetSlottedKeystoneInfo()
    if type(level) == "number" and level > 0 then return level end
    return nil
end

-- Returns the level of the keystone in OUR bag (nil if we have none).
-- C_MythicPlus.GetOwnedKeystoneLevel() → keyStoneLevel
local function GetBagKeystoneLevel()
    if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel) then
        return nil
    end
    local level = C_MythicPlus.GetOwnedKeystoneLevel()
    if type(level) == "number" and level > 0 then return level end
    return nil
end

-- Returns the challenge map ID of the keystone in OUR bag (nil if none).
-- C_MythicPlus.GetOwnedKeystoneChallengeMapID() → challengeMapID
local function GetBagKeystoneChallengeMapID()
    if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneChallengeMapID) then
        return nil
    end
    local id = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    if type(id) == "number" and id > 0 then return id end
    return nil
end

-- Returns the world map ID of the keystone in OUR bag (nil if none).
-- Distinct from ChallengeMapID — used for map lookups.
-- C_MythicPlus.GetOwnedKeystoneMapID() → mapID
local function GetBagKeystoneMapID()
    if not (C_MythicPlus and C_MythicPlus.GetOwnedKeystoneMapID) then
        return nil
    end
    local id = C_MythicPlus.GetOwnedKeystoneMapID()
    if type(id) == "number" and id > 0 then return id end
    return nil
end

-- Returns true if the LOCAL player is the keystone owner for the current run.
-- C_PartyInfo.IsChallengeModeKeystoneOwner() → isKeystoneOwner
-- Canonical API — no bag-presence heuristics needed.
local function IsLocalPlayerKeystoneOwner()
    if C_PartyInfo and C_PartyInfo.IsChallengeModeKeystoneOwner then
        return C_PartyInfo.IsChallengeModeKeystoneOwner() == true
    end
    -- Fallback: assume foreign key (fail safe = show reminder)
    return false
end

-- ──────────────────────────────────────────────
-- Reminder suppression logic
-- ──────────────────────────────────────────────
--
-- AUTO MODE — show "Change your key!" when ALL of:
--   1. Run was completed in time (COMPLETED, not DEPLETED)
--   2. The keystone was NOT ours (we can only reroll at the vendor on a
--      foreign key completion — the vendor never lets you reroll your own)
--   3. The run key level >= our current bag key level
--      (equal  → vendor reroll is neutral,  safe to offer)
--      (higher → vendor reroll upgrades us, safe to offer)
--      (lower  → vendor reroll would downgrade our key, suppress)
--
-- SUPPRESS when ANY of:
--   • Run was not completed in time (depleted / abandoned / no timed finish)
--   • It was our own keystone (vendor cannot reroll the owner's key)
--   • Run level < bag level (reroll would downgrade)
--   • We have no key in our bag (nothing to reroll)
--
-- MANUAL MODE:
--   Suppress if the run key level is below the user's configured minKeyLevel.
--   Foreign vs. own does not matter in manual mode (user manages intent).
--
local function ShouldSuppressReminder(capturedLevel)
    local autoMode = KeyChangeReminder:Get("autoMode")

    if autoMode then
        -- Rule 1: must be a timed completion.
        -- (STATE_DEPLETED is handled before this call; kept as safety net.)
        if runState ~= STATE_COMPLETED then return true end

        -- Rule 2: must be a foreign key run.
        if ownKeyRun then
            return true  -- cannot reroll our own key at the vendor
        end

        -- Rule 3: run level must be >= our bag key level.
        local bagLevel = GetBagKeystoneLevel()
        if not bagLevel then
            return true  -- no key in bag — nothing to reroll
        end

        -- Use the captured snapshot; fall back to the module-level value.
        local runLevel = capturedLevel or lastRunLevel
        if not runLevel then
            -- Could not read run level; fail open (show reminder).
            return false
        end

        -- bagLevel > runLevel → reroll would downgrade → suppress
        -- bagLevel <= runLevel → reroll is neutral or an upgrade → SHOW
        if bagLevel > runLevel then return true end

        return false  -- SHOW

    else
        -- Manual mode: only gate on the user's minKeyLevel threshold.
        local runLevel = capturedLevel or lastRunLevel
        local minLevel = KeyChangeReminder:Get("minKeyLevel") or 0
        if minLevel > 0 and runLevel and runLevel < minLevel then
            return true
        end
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
    -- Fired when the keystone is socketed and the challenge begins.
    --
    -- Ownership: C_PartyInfo.IsChallengeModeKeystoneOwner() is reliable
    -- immediately at START — no deferred detection needed.
    --
    -- Slotted level: C_ChallengeMode.GetSlottedKeystoneInfo() is reliable
    -- immediately at START.
    --
    -- Grace window (5 s): kept solely to eat Midnight's spurious
    -- CHALLENGE_MODE_RESET that fires as a side-effect of key consumption.
    -- We do NOT use it for ownership detection anymore.
    elseif event == "CHALLENGE_MODE_START" then
        runGeneration = runGeneration + 1
        local capturedGen = runGeneration

        -- Transition from any state → STARTING (handles stale runs automatically).
        runState     = STATE_STARTING
        ownKeyRun    = false
        lastRunLevel = nil

        -- Dismiss any leftover reminder from a previous run.
        DismissReminder()
        DismissTalentReminder()

        -- Record ownership immediately — API is reliable at START.
        ownKeyRun = IsLocalPlayerKeystoneOwner()

        -- Record run key level immediately from the slotted keystone info.
        lastRunLevel = GetSlottedKeystoneLevel()

        -- 5-second grace window: only purpose is to eat the spurious
        -- CHALLENGE_MODE_RESET Midnight fires right after key consumption.
        -- Ownership and level are already finalized above.
        C_Timer.After(5, function()
            if runGeneration ~= capturedGen then return end  -- superseded by newer run
            if runState ~= STATE_STARTING   then return end  -- already transitioned

            -- Sanity check: if M+ is no longer active (e.g. group disbanded in
            -- the first 5 seconds before the grace window elapsed), reset cleanly
            -- instead of transitioning to IN_PROGRESS on a dead run.
            if not IsMythicPlusActive() then
                ResetRunState()
                return
            end

            runState = STATE_IN_PROGRESS
        end)

    -- ── CHALLENGE_MODE_COMPLETED ────────────────────────────────────────────
    -- Fired when all bosses are killed within the time limit (timed finish).
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        if runState ~= STATE_IN_PROGRESS then return end

        -- Attempt a last-chance level capture here, while the key may still
        -- be briefly queryable. This fills the gap if GetSlottedKeystoneInfo()
        -- returned nil at START (e.g. timing edge cases).
        if not lastRunLevel then
            lastRunLevel = GetSlottedKeystoneLevel()
        end

        runState = STATE_COMPLETED
        local capturedGen   = runGeneration
        local capturedLevel = lastRunLevel  -- snapshot before async reset races

        -- Small delay so post-run UI settles before we evaluate + show.
        C_Timer.After(3, function()
            if runGeneration ~= capturedGen then return end

            -- Restore snapshot in case lastRunLevel was cleared by a race
            -- (e.g. a stray CHALLENGE_MODE_RESET firing before this timer).
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
    -- Fired on genuine key depletion mid-run OR spuriously right after START
    -- (Midnight's key-consumption artifact).
    --
    -- The 5-second grace window in STARTING blocks the spurious post-START
    -- fire. Only a RESET while IN_PROGRESS is treated as a real depletion.
    elseif event == "CHALLENGE_MODE_RESET" then
        if runState ~= STATE_IN_PROGRESS then return end

        -- Genuine depletion/abandon — vendor never appears, always suppress.
        runState = STATE_DEPLETED
        ResetRunState()

    -- ── PLAYER_REGEN_DISABLED ───────────────────────────────────────────────
    elseif event == "PLAYER_REGEN_DISABLED" then
        DismissReminder()
        DismissTalentReminder()

    -- ── PLAYER_ENTERING_WORLD ───────────────────────────────────────────────
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Dismiss the key-change reminder if we've zoned into an M+ instance
        -- mid-reminder (e.g. accepted a queue while the banner was still up).
        if reminderWatching and IsMythicPlusActive() then
            DismissReminder()
        end

        -- Talent reminder: fire after a short delay so the M+ API has settled
        -- post-load. IsMythicPlusActive() is the clean gate — no need to check
        -- instance type + bag key presence separately.
        if KeyChangeReminder:Get("talentReminder") then
            C_Timer.After(3, function()
                if IsMythicPlusActive() then
                    KeyChangeReminder:ShowTalentReminder()
                end
            end)
        end

    -- ── ZONE_CHANGED_NEW_AREA ───────────────────────────────────────────────
    -- Dismiss reminders when leaving an M+ instance entirely.
    -- IsMythicPlusActive() is false once the player is out of an active run,
    -- which is exactly the condition we want — more precise than IsInInstance().
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
        local isOwner           = IsLocalPlayerKeystoneOwner()
        local mpActive          = IsMythicPlusActive()
        local autoMode          = KeyChangeReminder:Get("autoMode")
        local minKeyLevel       = KeyChangeReminder:Get("minKeyLevel") or 0

        print(FORMAT_SLUG .. COLOR_YELLOW .. " Debug State:|r")
        print(COLOR_GRAY .. "  runState                : |r" .. COLOR_YELLOW .. tostring(runState)          .. "|r")
        print(COLOR_GRAY .. "  runGeneration           : |r" .. COLOR_YELLOW .. tostring(runGeneration)      .. "|r")
        print(COLOR_GRAY .. "  lastRunLevel            : |r" .. COLOR_YELLOW .. tostring(lastRunLevel)       .. "|r")
        print(COLOR_GRAY .. "  ownKeyRun               : |r" .. COLOR_YELLOW .. tostring(ownKeyRun)          .. "|r")
        print(COLOR_GRAY .. "  IsKeystoneOwner (now)   : |r" .. COLOR_YELLOW .. tostring(isOwner)            .. "|r")
        print(COLOR_GRAY .. "  IsMythicPlusActive (now): |r" .. COLOR_YELLOW .. tostring(mpActive)           .. "|r")
        print(COLOR_GRAY .. "  bagLevel (now)          : |r" .. COLOR_YELLOW .. tostring(bagLevel)           .. "|r")
        print(COLOR_GRAY .. "  bagChallengeMapID (now) : |r" .. COLOR_YELLOW .. tostring(bagChallengeMapID)  .. "|r")
        print(COLOR_GRAY .. "  bagMapID (now)          : |r" .. COLOR_YELLOW .. tostring(bagMapID)           .. "|r")
        print(COLOR_GRAY .. "  slotLevel (now)         : |r" .. COLOR_YELLOW .. tostring(slotLevel)          .. "|r")
        print(COLOR_GRAY .. "  autoMode                : |r" .. COLOR_YELLOW .. tostring(autoMode)           .. "|r")
        print(COLOR_GRAY .. "  minKeyLevel             : |r" .. COLOR_YELLOW .. tostring(minKeyLevel)        .. "|r")

        -- Explain what would happen if we evaluated right now.
        local reason
        if autoMode then
            if runState ~= STATE_COMPLETED then
                reason = "run not COMPLETED (state=" .. runState .. ") — suppress"
            elseif ownKeyRun then
                reason = "own key run — suppress (cannot reroll own key at vendor)"
            elseif not bagLevel then
                reason = "no key in bag — suppress (nothing to reroll)"
            elseif not lastRunLevel then
                reason = "lastRunLevel nil — SHOW (fail open)"
            elseif bagLevel > lastRunLevel then
                reason = "bag(" .. bagLevel .. ") > run(" .. lastRunLevel .. ") — suppress (reroll would downgrade)"
            else
                reason = "bag(" .. tostring(bagLevel) .. ") <= run(" .. tostring(lastRunLevel) .. ") — SHOW reminder"
            end
        else
            if minKeyLevel > 0 and lastRunLevel and lastRunLevel < minKeyLevel then
                reason = "run level " .. tostring(lastRunLevel) .. " below minKeyLevel " .. minKeyLevel .. " — suppress"
            else
                reason = "manual mode, threshold not met — SHOW reminder"
            end
        end
        print(COLOR_GRAY .. "  ShouldSuppress?       : |r" .. COLOR_YELLOW .. tostring(reason) .. "|r")

    else
        if KeyChangeReminder.optionsCategory then
            Settings.OpenToCategory(KeyChangeReminder.optionsCategory.ID)
        else
            print(FORMAT_SLUG .. "Options not ready yet.")
        end
    end
end
