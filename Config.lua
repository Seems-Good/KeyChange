-- KeyChangeReminderConfig.lua
-- Default settings and SavedVariables helpers

KeyChangeReminder = KeyChangeReminder or {}

local DEFAULTS = {
    enabled        = true,
    minKeyLevel    = 0,          -- 0 = always remind regardless of key level
    color          = "CYAN",     -- preset name
    anchorPoint    = "CENTER",   -- WoW anchor point
    anchorX        = 0,
    anchorY        = 200,
    fontSize       = 42,
    pulseSpeed     = 1.0,        -- seconds per half-cycle (0.3 = fast, 2.0 = slow)
    talentReminder = false,      -- off by default
}

-- Color presets (label -> hex)
KeyChangeReminder.COLOR_PRESETS = {
    RED    = "ffff3333",
    ORANGE = "ffff9900",
    YELLOW = "ffffff00",
    WHITE  = "ffffffff",
    CYAN   = "ff00ccff",
    GREEN  = "ff00ff88",
}

function KeyChangeReminder:InitDB()
    if not KeyChangeReminderDB then
        KeyChangeReminderDB = {}
    end
    -- Fill in any missing keys from defaults
    for k, v in pairs(DEFAULTS) do
        if KeyChangeReminderDB[k] == nil then
            KeyChangeReminderDB[k] = v
        end
    end
    self.db = KeyChangeReminderDB
end

function KeyChangeReminder:Get(key)
    return self.db and self.db[key]
end

function KeyChangeReminder:Set(key, value)
    if self.db then
        self.db[key] = value
    end
end

function KeyChangeReminder:GetColorHex()
    local preset = self:Get("color") or "CYAN"
    return KeyChangeReminder.COLOR_PRESETS[preset] or KeyChangeReminder.COLOR_PRESETS["CYAN"]
end
