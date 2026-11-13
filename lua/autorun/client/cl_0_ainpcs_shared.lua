--[[
    AI NPCs — client shared state

    Settings, saved-NPC library, voice-service helpers and the model cache. No UI
    here: the panel (cl_ainpcs_panel.lua) reads and writes this.
]]

AINPCS = AINPCS or {}

local providers = include("providers/providers.lua")
local Voices    = include("voices/voices.lua")

AINPCS.Providers = providers
AINPCS.Voices    = AINPCS.Voices or Voices

local SETTINGS_FILE = "ai_npcs_settings.json"
local LIBRARY_FILE  = "ai_npcs_library.json"

-- =============================================================================
-- Fonts
-- =============================================================================

surface.CreateFont("AINPC_Header", { font = "Roboto", size = 22, weight = 700 })
surface.CreateFont("AINPC_Title",  { font = "Roboto", size = 28, weight = 700 })
surface.CreateFont("AINPC_Body",   { font = "Roboto", size = 16, weight = 400 })
surface.CreateFont("AINPC_Small",  { font = "Roboto", size = 13, weight = 400 })
surface.CreateFont("AINPC_Tiny",   { font = "Roboto", size = 11, weight = 400 })

AINPCS.Colors = {
    bg       = Color(20, 20, 24),
    card     = Color(34, 34, 40),
    cardAlt  = Color(29, 29, 34),
    text     = Color(235, 235, 235),
    sub      = Color(160, 160, 170),
    accent   = Color(90, 165, 255),
    good     = Color(90, 200, 120),
    bad      = Color(235, 90, 90),
    warn     = Color(235, 190, 90),
}

-- =============================================================================
-- Settings
-- =============================================================================

local DEFAULTS = {
    provider      = "groq",
    apiKeys       = {},
    hostname      = "",
    model         = "",
    reasoning     = "none",
    freeOnly      = true,
    max_tokens    = 2048,
    temperature   = 1,
    fallbackVoice = "google:en",
    firstRun      = true,
}

local function readJson(name)
    if not file.Exists(name, "DATA") then return nil end
    local raw = file.Read(name, "DATA") or ""
    if raw == "" then return nil end
    local ok, parsed = pcall(util.JSONToTable, raw, true)
    if not ok or not istable(parsed) then return nil end
    return parsed
end

local function writeJson(name, data)
    file.Write(name, util.TableToJSON(data))
end

function AINPCS.LoadSettings()
    local s = table.Copy(DEFAULTS)
    local disk = readJson(SETTINGS_FILE)
    if istable(disk) then
        for k, v in pairs(disk) do
            if s[k] ~= nil or k == "apiKeys" then s[k] = v end
        end
    end
    if not istable(s.apiKeys) then s.apiKeys = {} end
    return s
end

function AINPCS.SaveSettings()
    writeJson(SETTINGS_FILE, AINPCS.Settings)
end

AINPCS.Settings = AINPCS.LoadSettings()

-- =============================================================================
-- NPC library (saved characters)
--   { id, name, description, voiceId, class, reasoning, speak }
-- =============================================================================

function AINPCS.LoadLibrary()
    local disk = readJson(LIBRARY_FILE)
    local out = {}
    if istable(disk) then
        for _, entry in ipairs(disk) do
            if istable(entry) and isstring(entry.name) and entry.name ~= "" then
                table.insert(out, {
                    id          = entry.id or tostring(os.time()) .. math.random(100, 999),
                    name        = entry.name,
                    description = entry.description or "",
                    voiceId     = entry.voiceId or "",
                    class       = entry.class or "npc_citizen",
                    reasoning   = entry.reasoning or "none",
                    speak       = entry.speak ~= false,
                })
            end
        end
    end
    return out
end

function AINPCS.SaveLibrary(library)
    AINPCS.Library = library
    writeJson(LIBRARY_FILE, library)
end

AINPCS.Library = AINPCS.LoadLibrary()

function AINPCS.UpsertLibraryEntry(entry)
    local library = AINPCS.Library
    if not entry.id or entry.id == "" then
        entry.id = tostring(os.time()) .. "-" .. math.random(1000, 9999)
    end

    for i, existing in ipairs(library) do
        if existing.id == entry.id then
            library[i] = entry
            AINPCS.SaveLibrary(library)
            return entry
        end
    end

    table.insert(library, entry)
    AINPCS.SaveLibrary(library)
    return entry
end

function AINPCS.RemoveLibraryEntry(id)
    for i, entry in ipairs(AINPCS.Library) do
        if entry.id == id then
            table.remove(AINPCS.Library, i)
            AINPCS.SaveLibrary(AINPCS.Library)
            return true
        end
    end
    return false
end

-- =============================================================================
-- Voice service (local relay) helpers
-- =============================================================================

local cvRelay = CreateClientConVar("ainpc_voice_relay_url", "", true, false,
    "Your own voice service address. Empty = server default / 127.0.0.1:7171")

function AINPCS.RelayBase()
    local url = cvRelay and cvRelay:GetString() or ""
    if url == "" then url = GetGlobalString("AINPCVoiceRelay", "") or "" end
    if url == "" then url = "http://127.0.0.1:7171" end
    return (string.gsub(url, "/+$", ""))
end

local function relayGet(path, callback)
    HTTP({
        url = AINPCS.RelayBase() .. path,
        method = "get",
        headers = { ["Accept"] = "application/json" },
        success = function(code, body)
            callback((code == 200) and AINPCS.SafeJSON(body or "") or nil, code)
        end,
        failed = function(err) callback(nil, tostring(err)) end,
    })
end

function AINPCS.RelayVoices(query, callback)
    local path = "/voices?limit=40"
    if query and query ~= "" then path = "/voices?q=" .. Voices.Encode(query) .. "&limit=20" end
    relayGet(path, function(body, code)
        if istable(body) and istable(body.voices) then
            for _, v in ipairs(body.voices) do
                if isstring(v.name) and isstring(v.label) then
                    Voices.Register("relay:" .. v.name, v.label)
                end
            end
            callback(body.voices)
        else
            callback({}, code)
        end
    end)
end

function AINPCS.RelayHealth(callback)
    relayGet("/health", function(body) callback(istable(body) and body or nil) end)
end

function AINPCS.RelaySaveKey(key, callback)
    HTTP({
        url = AINPCS.RelayBase() .. "/config",
        method = "post",
        type = "application/json",
        headers = { ["Accept"] = "application/json" },
        body = util.TableToJSON({ key = key }),
        success = function(code, body)
            callback(code == 200 and istable(AINPCS.SafeJSON(body or "")), code,
                     AINPCS.SafeJSON(body or ""))
        end,
        failed = function(err) callback(false, 0, { error = tostring(err) }) end,
    })
end

-- =============================================================================
-- Model cache
-- =============================================================================

AINPCS.LiveOpenRouter = nil

local orBuffer = { chunks = {}, expect = 0 }

net.Receive("AINPC_OpenRouterModels", function()
    local idx   = net.ReadUInt(8)
    local total = net.ReadUInt(8)
    local size  = net.ReadUInt(20)
    local slice = net.ReadData(size)

    if idx == 1 then orBuffer = { chunks = {}, expect = total } end
    orBuffer.chunks[idx] = slice
    if idx ~= total then return end

    local payload = table.concat(orBuffer.chunks)
    orBuffer = { chunks = {}, expect = 0 }

    local parsed = AINPCS.SafeJSON(payload)
    if istable(parsed) and istable(parsed.order) and istable(parsed.models) then
        AINPCS.LiveOpenRouter = parsed
        if AINPCS.OnModelsChanged then AINPCS.OnModelsChanged() end
    end
end)

function AINPCS.RequestModels()
    net.Start("AINPC_RequestORModels")
    net.SendToServer()
end

-- Returns order (array), models (map), provider module
function AINPCS.ModelList(providerId)
    if providerId == "openrouter" and AINPCS.LiveOpenRouter then
        return AINPCS.LiveOpenRouter.order, AINPCS.LiveOpenRouter.models
    end
    local p = providers.get(providerId)
    if not p then return {}, {} end
    return p.modelOrder or {}, p.models or {}
end

-- =============================================================================
-- Spawning
-- =============================================================================

-- config = { name, description, voiceId, class, reasoning, speak }
function AINPCS.Spawn(config)
    local settings = AINPCS.Settings
    local provider = providers.get(settings.provider)
    if not provider then
        AINPCS.PushToast("Unknown provider: " .. tostring(settings.provider), "error")
        return
    end

    local key = AINPCS.Trim(settings.apiKeys[settings.provider] or "")
    if provider.id ~= "ollama" and key == "" then
        AINPCS.PushToast("No API key set. Open Settings and paste one.", "error")
        return
    end

    net.Start("AINPC_SpawnRequest")
    net.WriteTable({
        provider    = settings.provider,
        apiKey      = key,
        hostname    = settings.hostname or "",
        class       = config.class or "npc_citizen",
        personality = config.description or "",
        name        = config.name or "NPC",
        model       = settings.model or "",
        max_tokens  = settings.max_tokens or 2048,
        temperature = settings.temperature,
        reasoning   = config.reasoning or settings.reasoning,
        enableTTS   = config.speak ~= false,
        voiceId     = config.voiceId or settings.fallbackVoice,
    })
    net.SendToServer()
end
