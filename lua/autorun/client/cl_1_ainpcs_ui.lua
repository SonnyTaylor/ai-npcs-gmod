--[[
    AI NPCs — UI gate  (Phase 0)

    The interface has two implementations behind one entry point:

      classic  cl_ainpcs_panel.lua     always available, frozen at v3.1
      mantle   cl_ainpcs_mantle*.lua   only when Mantle is installed

    Mantle is a separate Workshop addon (3126986993) and Workshop does not install
    dependencies, so we can never assume it exists — an existing subscriber who
    never hears about Mantle must keep a working C menu. Everything Mantle-shaped
    is therefore reached through this file, and the classic panel stays the
    compatibility path and the rollback.

    Nothing here touches Derma or the network; it is capability detection plus a
    palette so both interfaces describe "success" and "error" the same way.
]]

AINPCS    = AINPCS or {}
AINPCS.UI = AINPCS.UI or {}

local ui = AINPCS.UI

-- =============================================================================
-- Capability detection
--
-- Check the pieces we actually call rather than a version string: Mantle has
-- renamed colour keys between releases, and `istable(Mantle)` alone would pass
-- on a half-loaded or conflicting install (a second copy that lost the
-- vgui.Register race still leaves a Mantle table behind).
-- =============================================================================

ui.hasMantle = istable(Mantle)
    and istable(Mantle.color)
    and istable(Mantle.ui)
    and istable(Mantle.func)
    and isfunction(Mantle.func.w)
    and isfunction(Mantle.func.h)

-- RNDX is a client-only global created by Mantle's autorun (it returns the table
-- from modules/rndx.lua). It is the drawing layer used for HUD restyling.
ui.hasRNDX = ui.hasMantle and istable(RNDX) and isfunction(RNDX.Rect)

local cvMode = CreateClientConVar("ainpc_ui", "0", true, false,
    "AI NPCs interface: 0 = auto (Mantle when installed), 1 = classic Derma, 2 = force Mantle")

local cvSfx = CreateClientConVar("ainpc_ui_sfx", "1", true, false,
    "Click sounds in the AI NPCs interface")

--- 0 auto, 1 classic, 2 force Mantle. Read every call: the convar is live.
function ui.mode()
    return cvMode:GetInt()
end

--- True when the Mantle interface should be used.
function ui.useMantle()
    local mode = ui.mode()
    if mode == 1 then return false end
    if mode == 2 then return ui.hasMantle end
    return ui.hasMantle
end

--- True when the player asked for Mantle but it is not installed. Used once at
--- startup to explain why the UI looks like the screenshots' older sibling.
function ui.wantsMantleButCannot()
    return ui.mode() == 2 and not ui.hasMantle
end

-- =============================================================================
-- Palette
--
-- Two layers on purpose:
--   * structure and accents come from Mantle, so mantle_theme / mantle_smooth
--     work without us doing anything;
--   * semantics stay fixed, because "red means the key is rejected" must not
--     become green when someone picks the moss theme.
-- =============================================================================

ui.sem = {
    ok     = Color(90, 200, 120),
    bad    = Color(235, 90, 90),
    warn   = Color(235, 190, 90),
    speech = Color(255, 210, 120),   -- AI NPC dialogue
    you    = Color(130, 200, 255),   -- player lines in the chat window
}

local FALLBACK_COLORS = {
    theme         = Color(90, 165, 255),
    text          = Color(235, 235, 235),
    gray          = Color(150, 150, 160),
    text_muted    = Color(160, 160, 170),
    focus_panel   = Color(40, 40, 46),
    hover_overlay = Color(255, 255, 255, 12),
    icon          = Color(235, 235, 235),
}

--- Mantle colour by key, with a sane fallback so a Mantle rename cannot blank
--- the interface out.
function ui.col(key)
    if ui.hasMantle and Mantle.color[key] then return Mantle.color[key] end
    return FALLBACK_COLORS[key] or color_white
end

--- Mantle panel colour by alpha index (1..3), used for cards/sections.
function ui.panel(index)
    index = math.Clamp(index or 1, 1, 3)
    if ui.hasMantle and istable(Mantle.color.panel_alpha) and Mantle.color.panel_alpha[index] then
        return Mantle.color.panel_alpha[index]
    end
    return Color(34, 34, 40, 240)
end

-- =============================================================================
-- Small shared helpers
-- =============================================================================

--- Click feedback for committing actions only (save, spawn, open, delete).
--- Never on hover, and never in the same frame as a TTS line.
function ui.click(path)
    if not cvSfx:GetBool() then return end
    if not (ui.hasMantle and isfunction(Mantle.func.sound)) then return end
    Mantle.func.sound(path)
end

--- Screen-relative size with a hard clamp, so a 1280x720 client never gets a
--- window taller than its viewport. These stay plain pixels when Mantle is
--- absent — the classic panel has its own fixed layout.
function ui.w(px)
    if not ui.hasMantle then return px end
    return math.min(Mantle.func.w(px), ScrW() - 40)
end

function ui.h(px)
    if not ui.hasMantle then return px end
    return math.min(Mantle.func.h(px), ScrH() - 40)
end
