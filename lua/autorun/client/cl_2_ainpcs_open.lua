--[[
    AI NPCs — panel entry point  (Phase 0)

    One `AINPCS.Open()` for every caller (concommand, C-menu icon, desktop icon),
    which routes to whichever interface this client can run.

    Keeping the route here rather than inside either panel means the classic file
    stays a pure view and can be deleted in a later release without hunting for
    entry points.
]]

AINPCS = AINPCS or {}

local UI = AINPCS.UI or {}

--- Has the player got a usable AI provider yet?
--- Ollama needs no key; every other provider does.
function AINPCS.HasUsableAIKey()
    local S = AINPCS.Settings
    if not istable(S) then return false end
    if (S.provider or "") == "ollama" then return true end
    local keys = istable(S.apiKeys) and S.apiKeys or {}
    return AINPCS.Trim(keys[S.provider or ""] or "") ~= ""
end

--- Should the panel hand over to the guided setup instead of opening?
function AINPCS.NeedsSetup()
    local S = AINPCS.Settings
    if not istable(S) then return false end
    if not S.firstRun then return false end
    return not AINPCS.HasUsableAIKey()
end

function AINPCS.Open()
    -- First install (or first install since this version): walk them through
    -- getting a key instead of dropping them on a settings page with a blank
    -- field and no idea where the key comes from.
    --
    -- If the wizard returns nil it is the placeholder from cl_0 (a stale or
    -- half-mounted install), so fall through to the panel rather than leaving the
    -- player with nothing at all.
    if AINPCS.NeedsSetup() and isfunction(AINPCS.OpenSetupWizard) then
        local opened = AINPCS.OpenSetupWizard()
        if opened ~= nil then return opened end
    end

    if UI.useMantle and UI.useMantle() and isfunction(AINPCS.OpenMantle) then
        return AINPCS.OpenMantle()
    end

    if not isfunction(AINPCS.OpenClassic) then
        -- Should not happen: cl_ainpcs_panel.lua always defines it. Chicken out
        -- loudly rather than silently opening nothing.
        AINPCS.PushToast("Interface unavailable — reinstall the addon.", "error")
        return nil
    end

    return AINPCS.OpenClassic()
end

concommand.Add("ainpc_open", function() AINPCS.Open() end)

list.Set("DesktopWindows", "ai_npcs_menu", {
    title = "AI NPCs",
    icon  = "materials/gptlogo/ChatGPT_logo.svg.png",
    init  = function() AINPCS.Open() end,
})
