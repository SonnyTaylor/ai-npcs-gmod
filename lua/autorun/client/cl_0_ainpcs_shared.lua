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
    "Your own voice service address. Empty = server default / http://localhost:7171")

-- localhost, not 127.0.0.1: the PowerShell relay binds a HttpListener prefix of
-- "http://localhost:7171/", and HTTP.sys matches prefixes on the Host header. A
-- request to 127.0.0.1 gets "400 Invalid Hostname" from Windows itself, which is
-- indistinguishable from the service being down. hostname works for the Python
-- relay too, so one default covers both backends.
local DEFAULT_RELAY = "http://localhost:7171"

--- Whatever the player/server asked for, before any probing.
function AINPCS.RelayConfiguredBase()
    local url = cvRelay and cvRelay:GetString() or ""
    if url == "" then url = GetGlobalString("AINPCVoiceRelay", "") or "" end
    if url == "" then url = DEFAULT_RELAY end
    return (string.gsub(url, "/+$", ""))
end

--- Effective base: the configured one, unless a probe found the other spelling
--- of the same host working.
function AINPCS.RelayBase()
    return AINPCS._relayBase or AINPCS.RelayConfiguredBase()
end

-- The convar is FCVAR_ARCHIVE, so a stale value from an older build outlives the
-- default. Forget what a probe learned when the player changes it.
cvars.AddChangeCallback("ainpc_voice_relay_url", function()
    AINPCS._relayBase = nil
end)

--- The other spelling of the same loopback host. The PowerShell relay registers
--- its HttpListener for "localhost" only, and HTTP.sys matches prefixes against the
--- Host header, so http://127.0.0.1:7171 is answered by Windows itself with
--- "400 Invalid Hostname" while the service is perfectly healthy. Both spellings
--- mean this machine, so try both and remember which one answered.
local function alternateHost(url)
    if string.find(url, "//localhost", 1, true) then
        return (string.gsub(url, "//localhost", "//127.0.0.1", 1))
    end
    if string.find(url, "//127.0.0.1", 1, true) then
        return (string.gsub(url, "//127%.0%.0%.1", "//localhost", 1))
    end
    if string.find(url, "//[::1]", 1, true) then
        return (string.gsub(url, "//[[]::1[]]", "//localhost", 1))
    end
    return nil
end

AINPCS.RelayAlternateHost = alternateHost

--- Low-level call: callback(code, rawBody). code is a number on an HTTP response
--- and a string when the request never completed.
local function relayCall(base, path, method, body, callback)
    local opts = {
        url = base .. path,
        method = method or "get",
        headers = { ["Accept"] = "application/json" },
        success = function(code, response) callback(code, response or "") end,
        failed = function(err) callback(tostring(err), "") end,
    }

    if body then
        opts.type = "application/json"
        opts.body = body
    end

    HTTP(opts)
end

local function relayGet(path, callback)
    relayCall(AINPCS.RelayBase(), path, "get", nil, function(code, raw)
        callback((code == 200) and AINPCS.SafeJSON(raw) or nil, code, raw)
    end)
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

--- Probes /health on the configured base and, if that fails, on the other
--- spelling of the same host. callback(info, code):
---   info = the health payload, or { unparsed = true } when something answered 200
---          with a body that is not our JSON, or nil when nothing answered at all.
---   code = HTTP status (number) or the transport error (string).
function AINPCS.RelayHealth(callback)
    local primary = AINPCS.RelayConfiguredBase()
    local candidates = { primary }

    local alt = alternateHost(primary)
    if alt and alt ~= primary then candidates[#candidates + 1] = alt end

    AINPCS._relayTried = table.concat(candidates, "  or  ")

    local function attempt(index)
        local base = candidates[index]
        if not base then
            AINPCS._relayBase = nil
            callback(nil, nil, nil)
            return
        end

        relayCall(base, "/health", "get", nil, function(code, raw)
            if code == 200 then
                local parsed = AINPCS.SafeJSON(raw)
                AINPCS._relayBase = base

                if istable(parsed) then
                    callback(parsed, 200, raw)
                else
                    -- Something is answering on this port. Reporting "not running"
                    -- here would be a lie; say reachable-but-unreadable instead.
                    callback({ ok = true, unparsed = true, raw = raw }, 200, raw)
                end
                return
            end

            attempt(index + 1)
        end)
    end

    attempt(1)
end

function AINPCS.RelaySaveKey(key, callback)
    relayCall(AINPCS.RelayBase(), "/config", "post", util.TableToJSON({ key = key }),
        function(code, raw)
            local parsed = AINPCS.SafeJSON(raw)
            callback(code == 200 and istable(parsed), code or 0,
                     istable(parsed) and parsed or { error = tostring(raw) })
        end)
end

-- =============================================================================
-- Diagnostics
--
-- "the panel says the voice service is down but it is running" has exactly three
-- causes -- wrong host spelling, wrong port, or something else squatting on the
-- port -- and they look identical from inside the panel. This prints which one.
-- =============================================================================

concommand.Add("ainpc_voice_diag", function()
    local configured = AINPCS.RelayConfiguredBase()

    MsgC(Color(90, 165, 255), "\n[AI NPCs] voice relay diagnostics\n")
    MsgN("  ainpc_voice_relay_url  = ", string.format("%q", cvRelay and cvRelay:GetString() or ""))
    MsgN("  AINPCVoiceRelay (srv)  = ", string.format("%q", GetGlobalString("AINPCVoiceRelay", "") or ""))
    MsgN("  configured base        = ", configured)
    MsgN("  effective base         = ", AINPCS.RelayBase())

    local candidates = { configured }
    local alt = alternateHost(configured)
    if alt and alt ~= configured then candidates[#candidates + 1] = alt end

    local pending = #candidates
    for _, base in ipairs(candidates) do
        relayCall(base, "/health", "get", nil, function(code, raw)
            if code == 200 then
                MsgN(string.format("  %s  ->  HTTP 200, %d bytes, json=%s",
                    base, #raw, tostring(istable(AINPCS.SafeJSON(raw)))))
                MsgN("      ", string.sub(string.gsub(raw, "%s+", " "), 1, 180))
            elseif type(code) == "number" then
                MsgN(string.format("  %s  ->  HTTP %d  (something answered, but not the relay)", base, code))
            else
                MsgN(string.format("  %s  ->  no response  (%s)", base, tostring(code)))
            end

            pending = pending - 1
            if pending == 0 then
                MsgN("  nothing answering at all? check the relay window is open and the port matches.\n")
            end
        end)
    end
end)

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
