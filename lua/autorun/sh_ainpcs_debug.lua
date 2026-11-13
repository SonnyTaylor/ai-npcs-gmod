if SERVER then
    AddCSLuaFile()
end

AINPCS = AINPCS or {}

-- Own switch instead of leaning on `developer`, so an admin can watch the
-- addon's prompts and replies without turning on every other file's debug spam.
local CV_DEBUG
do
    local help = "AI NPCs: 1 = print prompts, replies and requests to the console. 2 = also print full request payloads."
    local existing = GetConVar and GetConVar("ainpc_debug")
    if existing then
        CV_DEBUG = existing                  -- the server already replicated one
    elseif SERVER then
        CV_DEBUG = CreateConVar("ainpc_debug", "0", FCVAR_ARCHIVE, help, 0, 2)
    else
        CV_DEBUG = CreateClientConVar("ainpc_debug", "0", true, false, help, 0, 2)
    end
end

local function isDeveloperEnabled()
    local conVar = GetConVar and GetConVar("developer")
    if not conVar then return false end
    return conVar:GetInt() == 1
end

local function debugLevel()
    return CV_DEBUG and CV_DEBUG:GetInt() or 0
end

function AINPCS.IsDeveloperEnabled()
    return isDeveloperEnabled()
end

--- Verbose payloads (full JSON bodies) need level 2.
function AINPCS.IsDebugVerbose()
    return debugLevel() >= 2
end

function AINPCS.DebugPrint(...)
    if debugLevel() == 0 and not isDeveloperEnabled() then return end
    print(...)
end

function AINPCS.DebugPrintTable(tbl, indent)
    if debugLevel() == 0 and not isDeveloperEnabled() then return end
    if indent ~= nil then
        PrintTable(tbl, indent)
    else
        PrintTable(tbl)
    end
end

--- Level-2-only output, for things that are too noisy at level 1.
function AINPCS.DebugPrintVerbose(...)
    if not AINPCS.IsDebugVerbose() then return end
    print(...)
end
