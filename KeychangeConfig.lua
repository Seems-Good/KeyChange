-- KeyChangeConfig.lua
-- Default settings and SavedVariables helpers

KeyChange = KeyChange or {}

local DEFAULTS = {
    enabled       = true,
    minKeyLevel   = 0,          -- 0 = always remind regardless of key level
    color         = "CYAN",     -- preset name
    anchorPoint   = "CENTER",   -- WoW anchor point
    anchorX       = 0,
    anchorY       = 200,
    fontSize      = 42,
    pulseSpeed    = 1.0,        -- seconds per half-cycle (0.3 = fast, 2.0 = slow)
}

-- Color presets (label -> hex)
KeyChange.COLOR_PRESETS = {
    RED    = "ffff3333",
    ORANGE = "ffff9900",
    YELLOW = "ffffff00",
    WHITE  = "ffffffff",
    CYAN   = "ff00ccff",
    GREEN  = "ff00ff88",
}

function KeyChange:InitDB()
    if not KeyChangeDB then
        KeyChangeDB = {}
    end
    -- Fill in any missing keys from defaults
    for k, v in pairs(DEFAULTS) do
        if KeyChangeDB[k] == nil then
            KeyChangeDB[k] = v
        end
    end
    self.db = KeyChangeDB
end

function KeyChange:Get(key)
    return self.db and self.db[key]
end

function KeyChange:Set(key, value)
    if self.db then
        self.db[key] = value
    end
end

function KeyChange:GetColorHex()
    local preset = self:Get("color") or "CYAN"
    return KeyChange.COLOR_PRESETS[preset] or KeyChange.COLOR_PRESETS["CYAN"]
end
