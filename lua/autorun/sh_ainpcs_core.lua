--[[
    AI NPCs — shared core
    Runs on both client and server. Registers network strings, constants,
    shared helpers, and ships provider files + client files to the client.
]]

AINPCS = AINPCS or {}
AINPCS.Version = "4.0.0"

AINPCS.NetStrings = {
    "AINPC_SpawnRequest",
    "AINPC_SpawnResult",
    "AINPC_ModelPreview",
    "AINPC_ModelPreviewResponse",
    "AINPC_ChatRequest",
    "AINPC_ChatReply",
    "AINPC_OpenChatUI",
    "AINPC_TTSPlay",
    "AINPC_Toast",
    "AINPC_OpenRouterModels",
    "AINPC_RequestORModels",
}

AINPCS.Defaults = {
    MaxHistoryTurns = 16,
    InteractRange = 140,
    ChatCooldownSeconds = 1.5,
    SpawnCooldownSeconds = 5,
    MaxNPCsPerPlayer = 3,
    -- Hard ceiling on a single provider round-trip. Without this the NPC sits on
    -- "thinking..." forever when a provider never answers.
    RequestTimeout = 60,
}

if SERVER then
    AddCSLuaFile("autorun/sh_ainpcs_core.lua")
    AddCSLuaFile("autorun/sh_ainpcs_debug.lua")
    AddCSLuaFile("autorun/client/cl_0_ainpcs_shared.lua")
    AddCSLuaFile("autorun/client/cl_1_ainpcs_ui.lua")
    AddCSLuaFile("autorun/client/cl_2_ainpcs_open.lua")
    AddCSLuaFile("autorun/client/cl_ainpcs_mantle_panel.lua")
    AddCSLuaFile("autorun/client/cl_ainpcs_panel.lua")
    AddCSLuaFile("autorun/client/cl_ainpcs_interact.lua")
    AddCSLuaFile("autorun/client/cl_ainpcs_hud.lua")
    AddCSLuaFile("providers/providers.lua")
    AddCSLuaFile("providers/openai.lua")
    AddCSLuaFile("providers/groq.lua")
    AddCSLuaFile("providers/openrouter.lua")
    AddCSLuaFile("providers/ollama.lua")
    AddCSLuaFile("providers/deepseek.lua")
    AddCSLuaFile("voices/voices.lua")

    for _, name in ipairs(AINPCS.NetStrings) do
        util.AddNetworkString(name)
    end
end

-- String helpers -----------------------------------------------------------

function AINPCS.Trim(str)
    if not str then return "" end
    return (string.gsub(str, "^%s*(.-)%s*$", "%1"))
end

function AINPCS.IsBlank(str)
    return not str or AINPCS.Trim(str) == ""
end

function AINPCS.Truncate(str, limit)
    if not str then return "" end
    if #str <= limit then return str end
    return string.sub(str, 1, limit - 1) .. "…"
end

-- Sanitise a URL fragment so we never leak keys into logs or chat.
function AINPCS.RedactKey(str)
    if not str or str == "" then return "<empty>" end
    if #str <= 8 then return "<redacted>" end
    return string.sub(str, 1, 4) .. "…" .. string.sub(str, -4)
end

-- Accepts "host", "host:port", "http://host", "https://host/", etc. and
-- returns a normalised "scheme://host[:port]" with no trailing slash.
function AINPCS.NormaliseHostname(raw, defaultScheme)
    raw = AINPCS.Trim(raw or "")
    if raw == "" then return "" end

    local scheme, rest = string.match(raw, "^(https?)://(.*)$")
    if not scheme then
        scheme = defaultScheme or "http"
        rest = raw
    end

    rest = string.gsub(rest, "/+$", "")
    return scheme .. "://" .. rest
end

-- Strict JSON parse that swallows nil gracefully.
--
-- ignoreLimits is essential: util.JSONToTable bails out at 15,000 keys by default,
-- and provider payloads blow past that (OpenRouter's /v1/models is ~29k keys today).
-- Without it the OpenRouter free-model refresh silently failed on every attempt.
function AINPCS.SafeJSON(body)
    if not body or body == "" then return nil end
    local ok, tbl = pcall(util.JSONToTable, body, true)
    if not ok then return nil end
    return tbl
end

-- History trimming — keeps the system prompt plus the last N turns.
function AINPCS.TrimHistory(history, maxTurns)
    if not history or #history <= 1 then return history end
    maxTurns = maxTurns or AINPCS.Defaults.MaxHistoryTurns
    local maxMessages = maxTurns * 2

    if #history - 1 <= maxMessages then return history end

    local trimmed = { history[1] }
    local start = #history - maxMessages + 1
    if start < 2 then start = 2 end
    for i = start, #history do
        table.insert(trimmed, history[i])
    end
    return trimmed
end

return AINPCS
