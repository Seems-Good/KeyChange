-- KeyChangeReminder.lua (Core.lua)
-- Core logic: events, keystone detection, reminder display

KeyChangeReminder = KeyChangeReminder or {}

local frame = CreateFrame("Frame", "KeyChangeReminderFrame", UIParent)

local VERSION   = "@project-version@"
local TIMESTAMP = "@project-date-iso@"

-- COLOR CODES (Used to color text)
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
--   IDLE          No run in progress. Initial state and post-reset state.
--   STARTING      CHALLENGE_MODE_START fired; waiting 5 s grace window before
--                 trusting a RESET as genuine depletion (Midnight fires a
--                 spurious RESET when the key is consumed from the bag).
--   IN_PROGRESS   Grace window elapsed; run is underway.
--   COMPLETED     CHALLENGE_MODE_COMPLETED fired (timed finish).
--   DEPLETED      CHALLENGE_MODE_RESET fired while IN_PROGRESS.
--
-- Transitions:
--   IDLE         → STARTING   on CHALLENGE_MODE_START
--   STARTING     → IN_PROGRESS  after 5 s timer
--   STARTING     → IDLE       on CHALLENGE_MODE_START (new run interrupted start)
--   IN_PROGRESS  → COMPLETED  on CHALLENGE_MODE_COMPLETED
--   IN_PROGRESS  → DEPLETED   on CHALLENGE_MODE_RESET
--   COMPLETED    → IDLE       after reminder timer fires (or is suppressed)
--   DEPLETED     → IDLE       after reminder timer fires (or is suppressed)
--   ANY          → IDLE       on CHALLENGE_MODE_START (stale-run guard)

local STATE_IDLE        = "IDLE"
local STATE_STARTING    = "STARTING"
local STATE_IN_PROGRESS = "IN_PROGRESS"
local STATE_COMPLETED   = "COMPLETED"
local STATE_DEPLETED    = "DEPLETED"

local runState = STATE_IDLE

-- ──────────────────────────────────────────────
-- Run-level bookkeeping
-- ──────────────────────────────────────────────

-- Level of the socketed key for the current/last run.
-- Set for ALL runs (own key or foreign key).
-- Used by AutoMode comparison (bag level vs run level).
local lastRunLevel = nil

-- Level of OUR bag key at the moment CHALLENGE_MODE_START fired.
-- Only set when we determined the run used OUR key.
-- nil means "foreign key run" for this run.
local currentRunLevel = nil

-- Whether the player owns the key that was socketed for this run.
-- Determined at CHALLENGE_MODE_START; see DetectKeyOwnership().
local ownKeyRun = false

-- Guards against stale C_Timer.After callbacks firing after a new run has
-- started. Incremented on every CHALLENGE_MODE_START; callbacks capture the
-- value at creation time and bail if it has changed by the time they fire.
local runGeneration = 0

-- ──────────────────────────────────────────────
-- Reminder display
-- ──────────────────────────────────────────────

local reminderLabel          = nil
local reminderWatching       = false
local talentReminderWatching = false

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
    reminderWatching      = false
    talentReminderWatching = true
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
end

function KeyChangeReminder:HideTalentReminder()
    DismissTalentReminder()
end

function KeyChangeReminder:CheckAndShowTalentReminder()
    local inInstance, instanceType = IsInInstance()
    local level = C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel
        and C_MythicPlus.GetOwnedKeystoneLevel()
    if inInstance and instanceType == "party"
       and type(level) == "number" and level > 0 then
        self:ShowTalentReminder()
    end
end

-- ──────────────────────────────────────────────
-- Keystone API helpers
-- ──────────────────────────────────────────────

-- Returns the level of the keystone currently socketed in the active challenge.
--
-- Midnight API notes:
--   C_ChallengeMode.GetActiveKeystoneInfo() → (mapID, keystoneLevel, affixes, wasEnergized)
--   keystoneLevel is always a plain number in live Midnight; guard for table just in case.
--   This function is ONLY reliable once the key is socketed (after START fires).
local function GetActiveKeystoneLevel()
    if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
        local _, level = C_ChallengeMode.GetActiveKeystoneInfo()
        -- Defensive: handle if Blizzard ever wraps this in a table
        if type(level) == "table" then
            level = level.level or level[1] or level.keystoneLevel
        end
        if type(level) == "number" and level > 0 then return level end
    end
    return nil
end

-- Returns the map ID of the keystone currently socketed in the active challenge.
local function GetActiveKeystoneMapID()
    if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
        local mapID = C_ChallengeMode.GetActiveKeystoneInfo()
        if type(mapID) == "number" and mapID > 0 then return mapID end
    end
    return nil
end

-- Returns the level of the keystone currently in the player's bag.
--
-- Midnight confirmed: C_MythicPlus.GetOwnedKeystoneLevel() returns a plain
-- number when the player has a key, or nil when they do not.
-- After CHALLENGE_MODE_START the key is in the socket, NOT the bag, so this
-- returns nil for the duration of a run — which is exactly the signal we use
-- to confirm "your key was the one that got socketed".
local function GetBagKeystoneLevel()
    if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel then
        local level = C_MythicPlus.GetOwnedKeystoneLevel()
        if type(level) == "number" and level > 0 then return level end
    end
    return nil
end

-- Returns the map ID of the keystone in the player's bag, or nil.
local function GetBagKeystoneMapID()
    if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneChallengeMapID then
        local mapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
        if type(mapID) == "number" and mapID > 0 then return mapID end
    end
    return nil
end

-- ──────────────────────────────────────────────
-- Own-key detection
-- ──────────────────────────────────────────────
--
-- THE CORRECT WAY in Midnight:
--
-- At the moment CHALLENGE_MODE_START fires the key has just been consumed
-- from the player's bag into the socket. So:
--
--   • If it was YOUR key  → GetBagKeystoneLevel() returns nil (key is gone).
--   • If it was someone else's key → GetBagKeystoneLevel() returns your key's level.
--
-- This is reliable and doesn't depend on map-ID matching (which was the old
-- broken approach: same-dungeon foreign keys share the map ID with your key
-- and would incorrectly be classified as "own key" runs).
--
-- Returns: ownKey (bool), ownKeyLevel (number|nil), socketedLevel (number|nil)
local function DetectKeyOwnership()
    local bagLevelAfterStart = GetBagKeystoneLevel()

    if bagLevelAfterStart == nil then
        -- Your key was consumed — this is YOUR run.
        -- We can't read your old bag level here because it's gone.
        -- Instead, read it from the socket (GetActiveKeystoneLevel).
        local socketedLevel = GetActiveKeystoneLevel()
        return true, socketedLevel, socketedLevel
    else
        -- Your key is still in the bag — someone else's key was socketed.
        -- bagLevelAfterStart = YOUR key level (unchanged, still in bag).
        -- socketedLevel = the foreign key's level.
        local socketedLevel = GetActiveKeystoneLevel()
        return false, bagLevelAfterStart, socketedLevel
    end
end

-- ──────────────────────────────────────────────
-- Reminder suppression logic
-- ──────────────────────────────────────────────
--
-- Returns true when the reminder should be suppressed.
--
-- AUTO MODE:
--   The reroll vendor appears at the end of a foreign-key TIMED run when the
--   bag key level is ≤ the socketed key level. Suppress only when the bag key
--   is strictly HIGHER (rerolling would be a net downgrade) or when no vendor
--   will appear (own-key run, depletion, abandon).
--
--     bag=12, run=12 timed → 12 > 12 false → SHOW   (equal, vendor appears)
--     bag=12, run=15 timed → 12 > 15 false → SHOW   (bag lower, vendor appears)
--     bag=13, run=12 timed → 13 > 12 true  → SUPPRESS (bag higher, no benefit)
--
-- MANUAL (minKeyLevel):
--   Suppress when currentRunLevel (own-key snapshot) is below the threshold.
--   Foreign-key runs (currentRunLevel == nil) are never suppressed here.
local function ShouldSuppressReminder()
    local autoMode = KeyChangeReminder:Get("autoMode")

    if autoMode then
        -- Own-key run: key upgraded/downgraded in-place; no reroll vendor. Always suppress.
        if ownKeyRun then return true end

        -- No socketed-key level recorded → can't make a sound decision; fail open.
        if not lastRunLevel then return false end

        -- Depleted or abandoned: reroll vendor never appears. Suppress.
        if runState == STATE_DEPLETED then return true end

        -- Foreign-key timed run: suppress only if our bag key is strictly higher.
        local bagLevel = GetBagKeystoneLevel()
        if not bagLevel then return true end   -- no key in bag at all; nothing to reroll
        if bagLevel > lastRunLevel then return true end
        return false

    else
        -- Manual threshold: only gates own-key runs.
        local minLevel = KeyChangeReminder:Get("minKeyLevel") or 0
        if minLevel > 0 and currentRunLevel and currentRunLevel < minLevel then
            return true
        end
        return false
    end
end

-- Reset all per-run state back to neutral.
local function ResetRunState()
    runState       = STATE_IDLE
    lastRunLevel   = nil
    currentRunLevel = nil
    ownKeyRun      = false
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
    -- Fired when the challenge mode instance begins (key placed, timer not yet
    -- started). The key has already been consumed from the bag at this point.
    elseif event == "CHALLENGE_MODE_START" then
        runGeneration = runGeneration + 1
        local capturedGen = runGeneration

        -- Transition from any state → STARTING
        runState     = STATE_STARTING
        ownKeyRun    = false
        lastRunLevel = nil
        currentRunLevel = nil

        -- Dismiss any leftover reminder from a previous run
        DismissReminder()
        DismissTalentReminder()

        -- Detect whether this run uses our key or a foreign key.
        -- DetectKeyOwnership() checks whether our bag key is still present;
        -- if it's gone, we know it was ours.
        local isOwn, ownLevel, socketedLevel = DetectKeyOwnership()

        ownKeyRun = isOwn
        lastRunLevel = socketedLevel   -- level of the key now in the socket

        if isOwn then
            -- Own-key run: snapshot the level from the socket (bag copy is gone)
            currentRunLevel = ownLevel
        else
            -- Foreign-key run: currentRunLevel stays nil (signals "not our key").
            -- ownLevel here is our bag key level; we'll re-read it at reminder time.
            currentRunLevel = nil
        end

        -- Grace window: Midnight fires a spurious CHALLENGE_MODE_RESET right
        -- after START as part of consuming the key. Don't trust a RESET as
        -- genuine depletion until this timer fires.
        -- Also retry the socketed level if the API wasn't ready yet.
        C_Timer.After(5, function()
            if runGeneration ~= capturedGen then return end  -- superseded by a newer run
            if runState ~= STATE_STARTING then return end    -- already transitioned away

            -- Retry socketed level if it came back nil at START
            if lastRunLevel == nil then
                lastRunLevel = GetActiveKeystoneLevel()
                -- Still nil: leave as nil; ShouldSuppressReminder fails open (shows reminder)
            end

            runState = STATE_IN_PROGRESS
        end)

    -- ── CHALLENGE_MODE_COMPLETED ────────────────────────────────────────────
    -- Fired when all bosses are killed within the time limit (timed run).
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        if runState ~= STATE_IN_PROGRESS then return end

        runState = STATE_COMPLETED
        local capturedGen = runGeneration

        C_Timer.After(3, function()
            if runGeneration ~= capturedGen then return end  -- new run started during timer

            if ShouldSuppressReminder() then
                ResetRunState()
                return
            end

            KeyChangeReminder:ShowReminder("Change your key!")
            ResetRunState()
        end)

    -- ── CHALLENGE_MODE_RESET ────────────────────────────────────────────────
    -- Fired when a key depletes mid-run, OR spuriously right after START
    -- (Midnight key-consumption side effect).
    -- We only act on it if we are IN_PROGRESS; the grace window blocks the
    -- spurious post-START fire.
    elseif event == "CHALLENGE_MODE_RESET" then
        if runState ~= STATE_IN_PROGRESS then return end

        runState = STATE_DEPLETED
        local capturedGen = runGeneration

        C_Timer.After(2, function()
            if runGeneration ~= capturedGen then return end

            if ShouldSuppressReminder() then
                ResetRunState()
                return
            end

            KeyChangeReminder:ShowReminder("Change your key!")
            ResetRunState()
        end)

    -- ── PLAYER_REGEN_DISABLED ───────────────────────────────────────────────
    elseif event == "PLAYER_REGEN_DISABLED" then
        DismissReminder()
        DismissTalentReminder()

    -- ── PLAYER_ENTERING_WORLD ───────────────────────────────────────────────
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Dismiss key-change reminder if the player re-enters an instance
        if reminderWatching then
            local inInstance, instanceType = IsInInstance()
            if inInstance and instanceType == "party" then
                DismissReminder()
            end
        end

        -- Show talent reminder when entering a M+ dungeon
        if KeyChangeReminder:Get("talentReminder") then
            C_Timer.After(3, function()
                local inInstance, instanceType = IsInInstance()
                local level = C_MythicPlus and C_MythicPlus.GetOwnedKeystoneLevel
                    and C_MythicPlus.GetOwnedKeystoneLevel()
                if inInstance and instanceType == "party"
                   and type(level) == "number" and level > 0 then
                    KeyChangeReminder:ShowTalentReminder()
                end
            end)
        end

    -- ── ZONE_CHANGED_NEW_AREA ───────────────────────────────────────────────
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        local inInstance = select(2, IsInInstance()) ~= "none"
        if not inInstance then
            if reminderWatching       then DismissReminder()       end
            if talentReminderWatching then DismissTalentReminder() end
        end

    end  -- end event chain
end)

-- ──────────────────────────────────────────────
-- Slash commands
-- ──────────────────────────────────────────────

SLASH_KEYCHANGE1 = "/keychange"
SLASH_KEYCHANGE2 = "/kcr"

SlashCmdList["KEYCHANGE"] = function(msg)
    local cmd = msg and msg:match("^%s*(%S+)") or ""

    if cmd:lower() == "debug" then
        local bagLevel    = GetBagKeystoneLevel()
        local bagMapID    = GetBagKeystoneMapID()
        local activeLevel = GetActiveKeystoneLevel()
        local activeMapID = GetActiveKeystoneMapID()
        local autoMode    = KeyChangeReminder:Get("autoMode")
        local minKeyLevel = KeyChangeReminder:Get("minKeyLevel") or 0

        print(FORMAT_SLUG .. COLOR_YELLOW .. " Debug State:|r")
        print(COLOR_GRAY .. "  runState          : |r" .. COLOR_YELLOW .. tostring(runState)          .. "|r")
        print(COLOR_GRAY .. "  runGeneration     : |r" .. COLOR_YELLOW .. tostring(runGeneration)     .. "|r")
        print(COLOR_GRAY .. "  lastRunLevel      : |r" .. COLOR_YELLOW .. tostring(lastRunLevel)      .. "|r")
        print(COLOR_GRAY .. "  currentRunLevel   : |r" .. COLOR_YELLOW .. tostring(currentRunLevel)   .. "|r")
        print(COLOR_GRAY .. "  ownKeyRun         : |r" .. COLOR_YELLOW .. tostring(ownKeyRun)         .. "|r")
        print(COLOR_GRAY .. "  bagLevel (now)    : |r" .. COLOR_YELLOW .. tostring(bagLevel)          .. "|r")
        print(COLOR_GRAY .. "  bagMapID (now)    : |r" .. COLOR_YELLOW .. tostring(bagMapID)          .. "|r")
        print(COLOR_GRAY .. "  activeLevel (now) : |r" .. COLOR_YELLOW .. tostring(activeLevel)       .. "|r")
        print(COLOR_GRAY .. "  activeMapID (now) : |r" .. COLOR_YELLOW .. tostring(activeMapID)       .. "|r")
        print(COLOR_GRAY .. "  autoMode          : |r" .. COLOR_YELLOW .. tostring(autoMode)          .. "|r")
        print(COLOR_GRAY .. "  minKeyLevel       : |r" .. COLOR_YELLOW .. tostring(minKeyLevel)       .. "|r")

        local reason = "unknown"
        if autoMode then
            if ownKeyRun then
                reason = "own key run — always suppress"
            elseif not lastRunLevel then
                reason = "lastRunLevel is nil — showing reminder (fail open)"
            elseif runState == STATE_DEPLETED then
                reason = "run depleted/abandoned — suppress (no vendor)"
            elseif not bagLevel then
                reason = "no key in bag — suppress (nothing to reroll)"
            elseif bagLevel > lastRunLevel then
                reason = "bag (" .. bagLevel .. ") > run (" .. lastRunLevel .. ") — suppress (reroll would downgrade)"
            else
                reason = "bag (" .. tostring(bagLevel) .. ") <= run (" .. tostring(lastRunLevel) .. ") — SHOW reminder"
            end
        else
            if minKeyLevel > 0 and currentRunLevel and currentRunLevel < minKeyLevel then
                reason = "own key " .. tostring(currentRunLevel) .. " below minKeyLevel " .. minKeyLevel .. " — suppress"
            else
                reason = "manual mode, no suppression threshold met — SHOW reminder"
            end
        end
        print(COLOR_GRAY .. "  ShouldSuppress?   : |r" .. COLOR_YELLOW .. reason .. "|r")

    else
        if KeyChangeReminder.optionsCategory then
            Settings.OpenToCategory(KeyChangeReminder.optionsCategory.ID)
        else
            print(FORMAT_SLUG .. "Options not ready yet.")
        end
    end
end
