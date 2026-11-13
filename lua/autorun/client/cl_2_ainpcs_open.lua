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

function AINPCS.Open()
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
