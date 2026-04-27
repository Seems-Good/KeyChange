-- KeyChangeReminder.lua (Core.lua)
-- Core logic: events, keystone detection, reminder display

KeyChangeReminder = KeyChangeReminder or {}

local frame = CreateFrame("Frame", "KeyChangeReminderFrame", UIParent)

local VERSION = "@project-version@"
local TIMESTAMP = "@project-date-iso@"

-- COLOR CODES (Used to color text)
local COLOR_YELLOW = "|cffffff00"
local COLOR_GRAY   = "|cff808080"
local COLOR_BLUE   = "|cff00ccff"
local FORMAT_NAME  = COLOR_BLUE .. "KeyChangeReminder[ KCR ]|r" .. COLOR_GRAY .. "-(" .. VERSION .. ")|r"
local FORMAT_SLUG  = COLOR_BLUE .. "[KeyChangeReminder]|r" .. COLOR_GRAY .. "-(" .. VERSION .. ")|r"

-- Tracks whether a run is currently in progress
local runInProgress = false

-- Level of the key that started the run, used for minKeyLevel and Auto mode.
-- Set for ALL runs (own key or foreign key) so Auto mode can compare bag vs run level.
local lastRunLevel = nil

-- Level of OUR key at run start — only set when the active key is ours.
-- Used by the existing minKeyLevel check (non-Auto path).
local currentRunLevel = nil

-- Guards against stale C_Timer.After callbacks firing after a new run has started
local pendingReminderCancelled = false

-- ──────────────────────────────────────────────
-- Reminder display
-- ──────────────────────────────────────────────

local reminderLabel = nil
local reminderWatching = false
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
    -- Only unregister if the talent reminder isn't also relying on this event
    if not talentReminderWatching then
        frame:UnregisterEvent("ZONE_CHANGED_NEW_AREA")
    end
    if reminderLabel and reminderLabel:IsShown() then
        reminderLabel.pulseGroup:Stop()
        -- Quick final fade out
        reminderLabel.exitGroup:Stop()
        reminderLabel:SetAlpha(1)
        reminderLabel.exitGroup:Play()
    end
end

local function DismissTalentReminder()
    if not talentReminderWatching then return end
    talentReminderWatching = false
    -- Only unregister if the key reminder isn't also relying on this event
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
    -- Each animation is half the total cycle duration
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
    -- Override the watch flags: this is a talent reminder, not a key change reminder
    reminderWatching = false
    talentReminderWatching = true
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")  -- ensure zone-out dismiss is active
end

function KeyChangeReminder:HideTalentReminder()
    DismissTalentReminder()
end

-- Called when the checkbox is enabled mid-session so we don't need a re-zone to trigger
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
-- Keystone helpers
-- ──────────────────────────────────────────────

-- Level of the currently active key (inside dungeon).
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
-- Reminder gating logic
-- ──────────────────────────────────────────────

-- Returns true if the reminder should be suppressed based on the current
-- minKeyLevel / Auto settings. Called from both COMPLETED and RESET timers.
--
-- Auto mode:  suppress when our bag key is strictly lower than the key that
--             was just run. This handles the "we ran someone else's key and
--             ours is too low to be worth changing" case. When it IS our own
--             key the bag level will always equal or exceed lastRunLevel after
--             a timed run (it goes up), so Auto never suppresses own-key
--             completions. For depletes of our own key, lastRunLevel == the
--             pre-run level and the bag key will be lower, which WOULD suppress
--             — but depletes arrive via CHALLENGE_MODE_RESET where currentRunLevel
--             is non-nil (own key), so we fall through to the minKeyLevel path
--             instead of the Auto path, leaving depletion reminders unaffected.
--
-- minKeyLevel mode (manual): suppress when currentRunLevel (own-key snapshot)
--             is below the configured threshold. Foreign-key runs have
--             currentRunLevel == nil and are never suppressed by this path.
local function ShouldSuppressReminder()
    local autoMode = KeyChangeReminder:Get("autoMode")

    if autoMode then
        -- Auto mode only applies to foreign-key runs. After completing your own
        -- key it upgrades automatically in your bag — the reroll vendor does not
        -- appear for own-key completions, so there is nothing to remind about.
        if currentRunLevel ~= nil then return true end   -- own key: always suppress

        -- Foreign key: only remind if our bag key is at or below the run level,
        -- meaning we could actually benefit from a reroll at the vendor.
        -- If our key is already higher than what we just ran, suppressing is correct
        -- because rerolling would be a downgrade.
        local bagLevel = GetBagKeystoneLevel()
        if not bagLevel then return true end              -- no key in bag
        if lastRunLevel and bagLevel > lastRunLevel then return true end
        return false
    else
        -- Manual threshold: only applies to our own key runs.
        local minLevel = KeyChangeReminder:Get("minKeyLevel") or 0
        if minLevel > 0 and currentRunLevel and currentRunLevel < minLevel then
            return true
        end
        return false
    end
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

    if event == "ADDON_LOADED" and arg1 == "KeyChangeReminder" then
        KeyChangeReminder:InitDB()
        print(FORMAT_SLUG .. "Type |cffffd700/keychange|r for options.")
        self:UnregisterEvent("ADDON_LOADED")  -- no longer needed after this point

    elseif event == "CHALLENGE_MODE_START" then
        -- Cancel any pending "change your key" reminder from the previous run.
        -- C_Timer.After callbacks cannot be cancelled natively, so we use a flag.
        -- This prevents a stale timer (from COMPLETED or RESET) firing once we're
        -- already inside the next dungeon.
        pendingReminderCancelled = true
        -- A new run is starting — dismiss any reminder currently on screen
        DismissReminder()
        -- Also dismiss the talent reminder; the run has begun
        DismissTalentReminder()

        -- Snapshot the bag key level for ALL runs (own or foreign).
        -- Auto mode needs this to compare bag level after the run completes.
        lastRunLevel = GetBagKeystoneLevel()

        -- Determine if this is our key or someone else's.
        -- currentRunLevel is only set for own-key runs; used by the manual
        -- minKeyLevel path and to distinguish own-key depletes in RESET.
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
            currentRunLevel = lastRunLevel   -- own key: use the same snapshot
        else
            currentRunLevel = nil            -- foreign key
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
        pendingReminderCancelled = false
        C_Timer.After(3, function()
            if pendingReminderCancelled then return end
            if ShouldSuppressReminder() then
                currentRunLevel = nil
                lastRunLevel = nil
                return
            end
            KeyChangeReminder:ShowReminder("Change your key!")
            currentRunLevel = nil
            lastRunLevel = nil
        end)

    elseif event == "CHALLENGE_MODE_RESET" then
        -- CHALLENGE_MODE_RESET fires both when a key is consumed at the START
        -- of a run AND when it depletes. Only remind if a run was actually in progress.
        if runInProgress then
            runInProgress = false
            pendingReminderCancelled = false
            C_Timer.After(2, function()
                if pendingReminderCancelled then return end
                if ShouldSuppressReminder() then
                    currentRunLevel = nil
                    lastRunLevel = nil
                    return
                end
                KeyChangeReminder:ShowReminder("Change your key!")
                currentRunLevel = nil
                lastRunLevel = nil
            end)
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entered combat — hide any visible reminder so it doesn't clutter the screen mid-pull
        DismissReminder()
        DismissTalentReminder()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- If a "change your key" reminder is showing and the player zones into an
        -- instance (e.g. walks back into a completed dungeon), dismiss it immediately.
        -- The reminder is only actionable at the keystone table in the outside world.
        if reminderWatching then
            local inInstance, instanceType = IsInInstance()
            if inInstance and instanceType == "party" then
                DismissReminder()
            end
        end

        -- Show talent reminder when entering a M+ dungeon.
        -- Delay slightly to let the instance type settle after zone-in.
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

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        local inInstance = select(2, IsInInstance()) ~= "none"
        if not inInstance then
            if reminderWatching then
                DismissReminder()
            end
            if talentReminderWatching then
                DismissTalentReminder()
            end
        end

    end  -- end if/elseif event chain
end)

-- ──────────────────────────────────────────────
-- Slash commands
-- ──────────────────────────────────────────────

SLASH_KEYCHANGE1 = "/keychange"
SLASH_KEYCHANGE2 = "/kcr"

SlashCmdList["KEYCHANGE"] = function()
    if KeyChangeReminder.optionsCategory then
        Settings.OpenToCategory(KeyChangeReminder.optionsCategory.ID)
    else
        print(FORMAT_SLUG .. "Options not ready yet.")
    end
end
