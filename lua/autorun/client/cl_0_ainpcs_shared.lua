--[[
    AI NPCs — client shared state

    Settings, saved-NPC library, 100% in-game Fish Audio client (search, key validation,
    credit check, and direct TTS synthesis + disk cache), hidden DHTML localhost relay
    for Ollama, model cache, and spawn/update helpers.
]]

AINPCS = AINPCS or {}

local providers = include("providers/providers.lua")
local Voices    = include("voices/voices.lua")

AINPCS.Providers = providers
AINPCS.Voices    = AINPCS.Voices or Voices

local SETTINGS_FILE = "ai_npcs_settings.json"
local LIBRARY_FILE  = "ai_npcs_library.json"
local FISH_API      = "https://api.fish.audio"
local FISH_MODEL    = "s2.1-pro-free"

-- =============================================================================
-- Fonts & Palette
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

-- Guided setup lives in cl_ainpcs_setup.lua. This stub only exists so a client
-- running a mixed or stale install (local folder + an older Workshop copy, or a
-- mid-session addon remount) gets a readable message instead of a hard Lua error
-- the moment someone presses a Settings button.
-- The real file overwrites it whenever it loads: the guard means whichever order
-- they arrive in, the real implementation wins.
if not isfunction(AINPCS.OpenSetupWizard) then
    function AINPCS.OpenSetupWizard()
        if AINPCS.PushToast then
            AINPCS.PushToast("Setup wizard unavailable — restart Garry's Mod so the addon's new files load, or paste your key directly in Settings.", "error")
        end
        return nil
    end
end

-- =============================================================================
-- Settings
-- =============================================================================

local DEFAULTS = {
    provider      = "groq",
    apiKeys       = {},
    fishKey       = "",
    pinnedVoices  = {},
    hostname      = "",
    model         = "",
    reasoning     = "none",
    freeOnly      = true,
    max_tokens    = 2048,
    temperature   = 1,
    fallbackVoice = "google:en",
    firstRun      = true,
    -- What every NPC on this server is told about you, in your own words.
    persona       = { name = "", about = "" },
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
            if s[k] ~= nil or k == "apiKeys" or k == "pinnedVoices" then
                s[k] = v
            end
        end
    end
    if not istable(s.apiKeys) then s.apiKeys = {} end
    if not istable(s.persona) then s.persona = { name = "", about = "" } end
    if not istable(s.pinnedVoices) or #s.pinnedVoices == 0 then
        s.pinnedVoices = table.Copy(Voices.StarterFish or {})
    end
    for _, pv in ipairs(s.pinnedVoices) do
        if istable(pv) and isstring(pv.name) and isstring(pv.label) then
            Voices.Register("fish:" .. pv.name, pv.label)
        end
    end
    -- Clean up legacy relay status files if present
    for _, legacyFile in ipairs({ "ainpc_relay_status.json", "ainpc_relay_voices.json", "ainpc_relay_command.json" }) do
        if file.Exists(legacyFile, "DATA") then
            pcall(file.Delete, legacyFile)
        end
    end
    return s
end

function AINPCS.SaveSettings()
    writeJson(SETTINGS_FILE, AINPCS.Settings)
end

AINPCS.Settings = AINPCS.LoadSettings()

--- True when this client is the machine running the game server
--- (singleplayer, or the host of a listen server).
---
--- Used to decide who holds the keys: when you host, the server is your own PC,
--- so it can make the requests and the key never travels anywhere. When you join
--- someone else's server, generation is moved to this client and the server is
--- never told your key.
function AINPCS.IsListenHost()
    if game and game.SinglePlayer and game.SinglePlayer() then return true end
    local ply = LocalPlayer()
    if not IsValid(ply) then return false end
    if ply.IsListenServerHost then
        local ok, isHost = pcall(ply.IsListenServerHost, ply)
        if ok then return isHost and true or false end
    end
    return false
end

-- =============================================================================
-- AI provider key validation (client-side convenience check)
--
-- A key is only "valid" if the provider itself says so, and a models listing is
-- the cheapest authenticated endpoint every supported provider has. OpenRouter's
-- model list is public, so it uses /key instead, which is auth-only.
-- =============================================================================

local KEY_ENDPOINTS = {
    groq       = { url = "https://api.groq.com/openai/v1/models" },
    openrouter = { url = "https://openrouter.ai/api/v1/key" },
    openai     = { url = "https://api.openai.com/v1/models" },
    deepseek   = { url = "https://api.deepseek.com/models" },
}

--- Where the player goes to create a key, and what to call it.
function AINPCS.ProviderSignup(providerId)
    local p = providers.get(providerId)
    if not p then return nil end
    return {
        id      = p.id,
        label   = p.label,
        note    = p.note or "",
        keyUrl  = p.getKeyUrl or "",
        local_  = (p.id == "ollama"),
        free    = (p.id == "groq" or p.id == "openrouter" or p.id == "ollama"),
    }
end

--- Test an API key against the provider. callback(ok, message)
--- Ollama is local and needs no key, so it reports "skipped" rather than failing.
function AINPCS.TestProviderKey(providerId, key, callback)
    callback = callback or function() end
    key = AINPCS.Trim(key or "")

    local endpoint = KEY_ENDPOINTS[providerId]
    if not endpoint then
        if providerId == "ollama" then
            callback(true, "Local model server — no key needed. It is tested when an NPC first speaks.")
        else
            callback(true, "No key test available for this provider; saved anyway.")
        end
        return
    end

    if key == "" then
        callback(false, "Paste a key first.")
        return
    end

    HTTP({
        url = endpoint.url,
        method = "get",
        headers = {
            ["Authorization"] = "Bearer " .. key,
            ["Accept"]        = "application/json",
        },
        success = function(code, body)
            if code == 200 then
                callback(true, "Key accepted.")
            elseif code == 401 or code == 403 then
                callback(false, "That key was rejected (HTTP " .. tostring(code) .. "). Copy it again from the provider's page.")
            elseif code == 429 then
                callback(true, "Key is valid but you are rate limited right now (HTTP 429).")
            else
                local parsed = AINPCS.SafeJSON(body)
                local detail = (istable(parsed) and (parsed.message or parsed.error)) or ("HTTP " .. tostring(code))
                if istable(detail) then detail = "provider rejected the request" end
                callback(false, tostring(detail))
            end
        end,
        failed = function(err)
            callback(false, "Could not reach the provider: " .. tostring(err))
        end,
    })
end

-- =============================================================================
-- NPC Library (saved characters)
--   { id, name, description, voiceId, class, weapon, reasoning, speak }
-- =============================================================================

function AINPCS.LoadLibrary()
    local disk = readJson(LIBRARY_FILE)
    local out = {}
    if istable(disk) then
        for _, entry in ipairs(disk) do
            if istable(entry) and isstring(entry.name) and entry.name ~= "" then
                local vId = Voices.NormaliseId(entry.voiceId or "")
                table.insert(out, {
                    id          = entry.id or tostring(os.time()) .. math.random(100, 999),
                    name        = entry.name,
                    description = entry.description or "",
                    voiceId     = vId,
                    voiceLabel  = entry.voiceLabel or "",
                    class       = entry.class or "npc_citizen",
                    bodyModel   = entry.bodyModel or "",
                    weapon      = entry.weapon or "none",
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
    entry.voiceId = Voices.NormaliseId(entry.voiceId or "")
    entry.weapon  = entry.weapon or "none"
    entry.bodyModel = entry.bodyModel or ""

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
-- 100% In-Game Fish Audio Service (No external relay / .bat required!)
-- =============================================================================

local cachedCredits = nil
local creditsFetchedAt = 0

--- 1234 -> "1.2k", 1234567 -> "1.2m"
function AINPCS.FormatCount(n)
    n = tonumber(n) or 0
    if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
    if n >= 10000 then return string.format("%.0fk", n / 1000) end
    if n >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n))
end

--- Collapse a voice title down to a comparison key so the dozens of
--- "Rick Sanchez (Text To Speech)" / "rick sanchez TTS" clones count as one.
local function dedupeKey(label)
    local l = string.lower(tostring(label or ""))
    l = string.gsub(l, "%b()", " ")            -- (anything)
    l = string.gsub(l, "%b[]", " ")            -- [anything]
    l = string.gsub(l, "text%s*to%s*speech", " ")
    l = string.gsub(l, "%f[%a]tts%f[%A]", " ")
    l = string.gsub(l, "%f[%a]ai%f[%A]", " ")
    l = string.gsub(l, "%f[%a]voice%s*model%f[%A]", " ")
    l = string.gsub(l, "%f[%a]vc%s*model%f[%A]", " ")
    l = string.gsub(l, "%f[%a]voice%f[%A]", " ")
    l = string.gsub(l, "%f[%a]v%d%f[%A]", " ")
    l = string.gsub(l, "[^%w%s]", " ")
    l = string.gsub(l, "%s+", " ")
    return AINPCS.Trim(l)
end
AINPCS.VoiceDedupeKey = dedupeKey

--- Turn a raw Fish Audio /model item into the small shape the browser uses.
--- Returns nil for anything that cannot actually speak (untrained, non-TTS,
--- taken down) or that we cannot reference.
local function normaliseModel(m)
    if not istable(m) then return nil end
    local id = m._id
    if not isstring(id) or id == "" then return nil end
    if not string.match(id, "^[A-Za-z0-9_%-]+$") then return nil end
    if m.state and m.state ~= "trained" then return nil end
    if m.type and m.type ~= "tts" then return nil end
    if m.dmca_taken_down == true then return nil end

    local label = AINPCS.Trim(tostring(m.title or id))
    if label == "" then label = id end
    if #label > 64 then label = string.sub(label, 1, 63) .. "…" end

    -- Free, pre-rendered preview. Playing this costs no credits.
    local sample = nil
    if istable(m.samples) then
        for _, s in ipairs(m.samples) do
            if istable(s) and isstring(s.audio) and s.audio ~= "" then
                sample = s.audio
                break
            end
        end
    end

    local langs = {}
    if istable(m.languages) then
        for _, lg in ipairs(m.languages) do
            if isstring(lg) then langs[#langs + 1] = lg end
        end
    end

    return {
        id      = id,
        label   = label,
        key     = dedupeKey(label),
        uses    = tonumber(m.task_count) or 0,
        likes   = tonumber(m.like_count) or 0,
        marks   = tonumber(m.mark_count) or 0,
        langs   = langs,
        sample  = sample,
        cover   = m.cover_image,
        desc    = AINPCS.Trim(tostring(m.description or "")),
    }
end
AINPCS.NormaliseFishModel = normaliseModel

--- Fetch one page of the Fish Audio voice library, deduped and popularity sorted.
--- opts = { query, page, sortBy = "task_count"|"score"|"created_at", language, limit }
--- callback(voices, err)  -- voices is always a table (possibly empty)
function AINPCS.FishListVoices(opts, callback)
    opts = opts or {}
    callback = callback or function() end

    local query = AINPCS.Trim(opts.query or "")
    local page  = math.max(1, tonumber(opts.page) or 1)
    local sortBy = opts.sortBy or "task_count"
    local lang  = AINPCS.Trim(opts.language or "")
    local limit = math.Clamp(tonumber(opts.limit) or 50, 1, 100)

    local params = {
        "page_size=" .. limit,
        "page_number=" .. page,
        "sort_by=" .. Voices.Encode(sortBy),
    }
    if query ~= "" then params[#params + 1] = "title=" .. Voices.Encode(query) end
    if lang ~= "" then params[#params + 1] = "language=" .. Voices.Encode(lang) end

    local headers = { ["Accept"] = "application/json" }
    local key = AINPCS.Trim(AINPCS.Settings.fishKey or "")
    if key ~= "" then headers["Authorization"] = "Bearer " .. key end

    HTTP({
        url = FISH_API .. "/model?" .. table.concat(params, "&"),
        method = "get",
        headers = headers,
        success = function(code, raw)
            local parsed = AINPCS.SafeJSON(raw)
            if code ~= 200 or not istable(parsed) then
                local msg = (istable(parsed) and (parsed.message or parsed.error)) or ("HTTP " .. tostring(code))
                callback({}, tostring(msg))
                return
            end

            local items = parsed.items or {}
            local out, seenKeys = {}, {}

            for _, m in ipairs(items) do
                local v = normaliseModel(m)
                if v then
                    -- Dedupe on the collapsed title: keep the most-used upload of
                    -- the same character, drop the clones/duplicates entirely.
                    if v.key ~= "" and seenKeys[v.key] then
                        local prev = seenKeys[v.key]
                        if v.uses > prev.uses then
                            for i, existing in ipairs(out) do
                                if existing == prev then out[i] = v break end
                            end
                            seenKeys[v.key] = v
                        end
                    else
                        if v.key ~= "" then seenKeys[v.key] = v end
                        out[#out + 1] = v
                    end
                end
            end

            -- Sorting: prefer popularity, then likes, then a stable title order.
            if sortBy == "task_count" or sortBy == "score" then
                table.sort(out, function(a, b)
                    if a.uses ~= b.uses then return a.uses > b.uses end
                    if a.likes ~= b.likes then return a.likes > b.likes end
                    return string.lower(a.label) < string.lower(b.label)
                end)
            elseif sortBy == "created_at" then
                table.sort(out, function(a, b) return a.label < b.label end)
            end

            callback(out, nil, parsed)
        end,
        failed = function(err)
            callback({}, tostring(err))
        end,
    })
end

--- Look up a single Fish model (used when the user pastes a 32-hex id).
function AINPCS.FishGetVoice(modelId, callback)
    modelId = AINPCS.Trim(modelId or "")
    if modelId == "" then callback(nil, "no id") return end

    local headers = { ["Accept"] = "application/json" }
    local key = AINPCS.Trim(AINPCS.Settings.fishKey or "")
    if key ~= "" then headers["Authorization"] = "Bearer " .. key end

    HTTP({
        url = FISH_API .. "/model/" .. Voices.Encode(modelId),
        method = "get",
        headers = headers,
        success = function(code, raw)
            if code ~= 200 then callback(nil, "HTTP " .. tostring(code)) return end
            local v = normaliseModel(AINPCS.SafeJSON(raw))
            if not v then callback(nil, "model not found or not usable") return end
            callback(v, nil)
        end,
        failed = function(err) callback(nil, tostring(err)) end,
    })
end

--- Free preview playback (pre-rendered samples cost no credits).
local sampleChannel = nil

function AINPCS.StopSample()
    if IsValid(sampleChannel) then pcall(sampleChannel.Stop, sampleChannel) end
    sampleChannel = nil
end

function AINPCS.PlaySampleURL(url, volume)
    if not isstring(url) or url == "" then return false end
    AINPCS.StopSample()

    sound.PlayURL(url, "mono noplay", function(snd, errId, errName)
        if not IsValid(snd) then
            AINPCS.DebugPrint("[AI-NPCs] sample failed " .. tostring(errId) .. " " .. tostring(errName))
            return
        end
        snd:SetVolume(math.Clamp(volume or 0.7, 0, 1))
        snd:Play()
        sampleChannel = snd
    end)

    return true
end

function AINPCS.IsVoicePinned(modelId)
    if not modelId or modelId == "" then return false end
    for _, p in ipairs(AINPCS.Settings.pinnedVoices or {}) do
        if p.name == modelId then return true end
    end
    return false
end

function AINPCS.TogglePinVoice(modelId, label)
    if not modelId or modelId == "" then return false end
    AINPCS.Settings.pinnedVoices = AINPCS.Settings.pinnedVoices or {}
    for i, p in ipairs(AINPCS.Settings.pinnedVoices) do
        if p.name == modelId then
            table.remove(AINPCS.Settings.pinnedVoices, i)
            AINPCS.SaveSettings()
            return false
        end
    end
    table.insert(AINPCS.Settings.pinnedVoices, 1, { name = modelId, label = label or modelId })
    Voices.Register("fish:" .. modelId, label or modelId)
    AINPCS.SaveSettings()
    return true
end

-- Check Fish Audio status & account credit directly over HTTPS
function AINPCS.RelayHealth(callback)
    local key = AINPCS.Trim(AINPCS.Settings.fishKey or "")
    if key == "" then
        callback({
            ok      = true,
            key_set = false,
            builtin = true,
            presets = #(AINPCS.Settings.pinnedVoices or {}),
        }, 200)
        return
    end

    if cachedCredits ~= nil and (RealTime() - creditsFetchedAt) < 45 then
        callback({
            ok      = true,
            key_set = true,
            credits = cachedCredits,
            builtin = true,
            presets = #(AINPCS.Settings.pinnedVoices or {}),
        }, 200)
        return
    end

    HTTP({
        url = FISH_API .. "/wallet/self/api-credit",
        method = "get",
        headers = {
            ["Authorization"] = "Bearer " .. key,
            ["Accept"]        = "application/json",
        },
        success = function(code, raw)
            local parsed = AINPCS.SafeJSON(raw)
            if code == 200 and istable(parsed) then
                cachedCredits = tonumber(parsed.credit)
                creditsFetchedAt = RealTime()
                callback({
                    ok      = true,
                    key_set = true,
                    credits = cachedCredits,
                    builtin = true,
                    presets = #(AINPCS.Settings.pinnedVoices or {}),
                }, 200)
            elseif code == 401 or code == 403 then
                callback({
                    ok           = true,
                    key_set      = false,
                    key_rejected = true,
                    builtin      = true,
                }, code)
            else
                callback({
                    ok      = true,
                    key_set = true,
                    credits = cachedCredits,
                    builtin = true,
                }, code)
            end
        end,
        failed = function(err)
            callback({
                ok      = true,
                key_set = true,
                credits = cachedCredits,
                builtin = true,
                net_err = tostring(err),
            }, tostring(err))
        end,
    })
end

-- Validate and save the player's Fish Audio API key directly in-game
function AINPCS.RelaySaveKey(key, callback)
    key = AINPCS.Trim(key or "")
    if key == "" then
        AINPCS.Settings.fishKey = ""
        cachedCredits = nil
        creditsFetchedAt = 0
        AINPCS.SaveSettings()
        if callback then callback(true, 200, { cleared = true }) end
        return
    end

    HTTP({
        url = FISH_API .. "/wallet/self/api-credit",
        method = "get",
        headers = {
            ["Authorization"] = "Bearer " .. key,
            ["Accept"]        = "application/json",
        },
        success = function(code, raw)
            local parsed = AINPCS.SafeJSON(raw)
            if code == 200 and istable(parsed) then
                AINPCS.Settings.fishKey = key
                cachedCredits = tonumber(parsed.credit)
                creditsFetchedAt = RealTime()
                AINPCS.SaveSettings()
                if callback then callback(true, 200, parsed) end
            else
                local errMsg = (istable(parsed) and (parsed.message or parsed.error)) or ("HTTP " .. tostring(code))
                if callback then callback(false, code, { error = "Fish Audio rejected the key (" .. tostring(errMsg) .. ")" }) end
            end
        end,
        failed = function(err)
            if callback then callback(false, 0, { error = "Could not reach api.fish.audio: " .. tostring(err) }) end
        end,
    })
end

-- Search built-in voices, pinned Fish presets, and live Fish Audio catalog directly from GMod
function AINPCS.RelayVoices(query, callback)
    local q = AINPCS.Trim(query or "")
    local qLow = string.lower(q)
    local out = {}
    local seen = {}

    local function addEntry(voiceId, name, label, source, isPinned)
        if not voiceId or seen[voiceId] then return end
        seen[voiceId] = true
        table.insert(out, {
            id     = voiceId,
            name   = name or voiceId,
            label  = label or name or voiceId,
            source = source or "Fish Audio",
            pinned = isPinned == true,
        })
    end

    -- 1. Pinned / Starter Fish Audio character voices matching query
    for _, p in ipairs(AINPCS.Settings.pinnedVoices or {}) do
        if isstring(p.name) and isstring(p.label) then
            if qLow == "" or string.find(string.lower(p.label), qLow, 1, true) or string.find(string.lower(p.name), qLow, 1, true) then
                Voices.Register("fish:" .. p.name, p.label)
                addEntry("fish:" .. p.name, p.name, p.label, "Fish Audio (Pinned)", true)
            end
        end
    end

    -- 2. Built-in keyless voices (Google TTS + Microsoft SAPI4) matching query
    for _, v in ipairs(Voices.list or {}) do
        if v.engine == "google" or v.engine == "sapi4" then
            if qLow == "" or string.find(string.lower(v.label), qLow, 1, true) or string.find(string.lower(v.id), qLow, 1, true) then
                local src = (v.engine == "google") and "Built-in (Free)" or "Retro SAPI4 (Free)"
                addEntry(v.id, v.id, v.label, src, false)
            end
        end
    end

    -- If no search query, return pinned Fish voices + built-in voices immediately,
    -- and if the user has a Fish key, also fetch top trending Fish voices in the background.
    if q == "" then
        callback(out)
        return
    end

    local headers = { ["Accept"] = "application/json" }
    local key = AINPCS.Trim(AINPCS.Settings.fishKey or "")
    if key ~= "" then
        headers["Authorization"] = "Bearer " .. key
    end

    -- Direct 32-hex Fish Audio model ID lookup
    if string.match(q, "^[0-9a-fA-F]+$") and #q >= 24 then
        HTTP({
            url = FISH_API .. "/model/" .. Voices.Encode(q),
            method = "get",
            headers = headers,
            success = function(code, raw)
                local m = (code == 200) and AINPCS.SafeJSON(raw) or nil
                if istable(m) and isstring(m._id) then
                    local title = AINPCS.Trim(tostring(m.title or m._id))
                    if #title > 60 then title = string.sub(title, 1, 60) end
                    Voices.Register("fish:" .. m._id, title)
                    table.insert(out, 1, {
                        id     = "fish:" .. m._id,
                        name   = m._id,
                        label  = title,
                        source = "Fish Audio (ID)",
                        pinned = AINPCS.IsVoicePinned(m._id),
                    })
                end
                callback(out)
            end,
            failed = function() callback(out) end,
        })
        return
    end

    -- Live title search across Fish Audio's model catalog
    HTTP({
        url = FISH_API .. "/model?page_size=50&page_number=1&title=" .. Voices.Encode(q),
        method = "get",
        headers = headers,
        success = function(code, raw)
            local parsed = (code == 200) and AINPCS.SafeJSON(raw) or nil
            if istable(parsed) and istable(parsed.items) then
                local remote = {}
                for _, m in ipairs(parsed.items) do
                    if istable(m) and isstring(m._id) and m._id ~= "" then
                        local stateOk = (not m.state) or (m.state == "trained")
                        local typeOk  = (not m.type) or (m.type == "tts")
                        if stateOk and typeOk then
                            local title = AINPCS.Trim(tostring(m.title or m._id))
                            if #title > 60 then title = string.sub(title, 1, 60) end
                            Voices.Register("fish:" .. m._id, title)
                            table.insert(remote, {
                                name  = m._id,
                                label = title,
                            })
                        end
                    end
                end
                table.sort(remote, function(a, b)
                    local aStarts = string.sub(string.lower(a.label), 1, #qLow) == qLow
                    local bStarts = string.sub(string.lower(b.label), 1, #qLow) == qLow
                    if aStarts ~= bStarts then return aStarts end
                    return string.lower(a.label) < string.lower(b.label)
                end)
                for _, r in ipairs(remote) do
                    addEntry("fish:" .. r.name, r.name, r.label, "Fish Audio", AINPCS.IsVoicePinned(r.name))
                end
            end
            callback(out)
        end,
        failed = function()
            callback(out)
        end,
    })
end

-- Direct client-side Fish Audio TTS synthesis + disk cache (data/ainpc_tts/)
function AINPCS.FishSynthesize(modelId, text, callback)
    text = AINPCS.CleanText(text or "", 400)
    if text == "" or not modelId or modelId == "" then
        if callback then callback(nil, "empty text or voice") end
        return
    end

    if not file.IsDir("ainpc_tts", "DATA") then
        file.CreateDir("ainpc_tts")
    end

    local hash = util.CRC(modelId .. "|" .. text)
    local mp3Path = "ainpc_tts/fish_" .. hash .. ".mp3"
    local wavPath = "ainpc_tts/fish_" .. hash .. ".wav"

    if file.Exists(mp3Path, "DATA") and (file.Size(mp3Path, "DATA") or 0) > 256 then
        if callback then callback("data/" .. mp3Path, nil) end
        return
    end
    if file.Exists(wavPath, "DATA") and (file.Size(wavPath, "DATA") or 0) > 256 then
        if callback then callback("data/" .. wavPath, nil) end
        return
    end

    local key = AINPCS.Trim(AINPCS.Settings.fishKey or "")
    if key == "" then
        if callback then callback(nil, "No Fish Audio API key set. Paste your Fish Audio key in Settings.") end
        return
    end

    HTTP({
        url = FISH_API .. "/v1/tts",
        method = "post",
        type = "application/json",
        headers = {
            ["Authorization"] = "Bearer " .. key,
            ["Content-Type"]  = "application/json",
            ["model"]         = FISH_MODEL,
        },
        body = util.TableToJSON({
            text         = text,
            reference_id = modelId,
            format       = "mp3",
            sample_rate  = 44100,
            normalize    = true,
            latency      = "normal",
            prosody      = { speed = 1, volume = 0, normalize_loudness = true },
        }),
        success = function(code, body)
            if code == 200 and body and #body > 256 then
                local isWav = (string.sub(body, 1, 4) == "RIFF")
                local relPath = isWav and wavPath or mp3Path
                file.Write(relPath, body)
                if callback then callback("data/" .. relPath, nil) end
            else
                local parsed = AINPCS.SafeJSON(body)
                local msg = (istable(parsed) and (parsed.message or parsed.error)) or ("HTTP " .. tostring(code))
                if callback then callback(nil, tostring(msg)) end
            end
        end,
        failed = function(err)
            if callback then callback(nil, tostring(err)) end
        end,
    })
end

-- =============================================================================
-- Hidden DHTML Localhost Relay (for local Ollama without -allowlocalhttp)
-- =============================================================================

local dhtmlPanels = {}
local incomingRelay = {}
local RELAY_CHUNK = 28000

local RELAY_JS = [[
(function(){
  var id = %d, q = %s;
  var opts = { method: q.method || "GET", headers: q.headers || {} };
  if (q.body !== undefined && q.body !== null && opts.method !== "GET") opts.body = q.body;
  fetch(q.url, opts).then(function(r){
    return r.arrayBuffer().then(function(b){
      var u = new Uint8Array(b), s = "", i;
      for (i = 0; i < u.length; i += 32768) s += String.fromCharCode.apply(null, u.subarray(i, i + 32768));
      ainpc.done(id, r.status, btoa(s));
    });
  }).catch(function(e){ ainpc.fail(id, String(e)); });
})();
]]

local function sendRelayReply(id, statusCode, body)
    body = body or ""
    local total = math.max(1, math.ceil(#body / RELAY_CHUNK))
    for i = 1, total do
        local part = string.sub(body, (i - 1) * RELAY_CHUNK + 1, i * RELAY_CHUNK)
        net.Start("AINPC_LocalRelayRes")
        net.WriteUInt(id, 16)
        net.WriteUInt(i, 8)
        net.WriteUInt(total, 8)
        net.WriteUInt(statusCode, 16)
        net.WriteUInt(#part, 16)
        net.WriteData(part, #part)
        net.SendToServer()
    end
end

local function getRelayPanel(origin)
    local p = dhtmlPanels[origin]
    if p and IsValid(p.html) then return p end

    p = { queue = {}, ready = false }
    dhtmlPanels[origin] = p

    local html = vgui.Create("DHTML")
    p.html = html
    html:SetSize(16, 16)
    html:SetPos(-32, -32)
    html:SetPaintedManually(true)
    html:SetMouseInputEnabled(false)
    html:SetKeyboardInputEnabled(false)

    html:AddFunction("ainpc", "done", function(id, status, b64)
        local decoded = util.Base64Decode(b64 or "") or ""
        sendRelayReply(tonumber(id) or 0, math.Clamp(tonumber(status) or 0, 1, 65535), decoded)
    end)
    html:AddFunction("ainpc", "fail", function(id, err)
        sendRelayReply(tonumber(id) or 0, 0, "Local request failed (" .. tostring(err) .. ")")
    end)

    html.OnDocumentReady = function()
        p.ready = true
        for _, job in ipairs(p.queue) do
            html:RunJavascript(string.format(RELAY_JS, job.id, util.TableToJSON(job.q) or "{}"))
        end
        p.queue = {}
    end

    html:OpenURL(origin .. "/")

    timer.Simple(10, function()
        if dhtmlPanels[origin] ~= p or p.ready then return end
        for _, job in ipairs(p.queue) do
            sendRelayReply(job.id, 0, "Could not reach " .. origin .. " — is Ollama running?")
        end
        if IsValid(p.html) then p.html:Remove() end
        dhtmlPanels[origin] = nil
    end)

    return p
end

net.Receive("AINPC_LocalRelayReq", function()
    local id    = net.ReadUInt(16)
    local idx   = net.ReadUInt(8)
    local total = net.ReadUInt(8)
    local len   = net.ReadUInt(16)
    local data  = net.ReadData(len)

    local buf = incomingRelay[id]
    if not buf or buf.total ~= total then
        buf = { parts = {}, got = 0, total = total }
        incomingRelay[id] = buf
    end
    if not buf.parts[idx] then
        buf.parts[idx] = data
        buf.got = buf.got + 1
    end
    if buf.got < buf.total then return end
    incomingRelay[id] = nil

    local raw = util.Decompress(table.concat(buf.parts)) or ""
    local q = AINPCS.SafeJSON(raw)
    if not istable(q) or not isstring(q.url) or not AINPCS.IsLocalURL(q.url) then
        sendRelayReply(id, 0, "Invalid local relay request")
        return
    end

    local origin = string.match(q.url, "^(https?://[^/]+)")
    if not origin then
        sendRelayReply(id, 0, "Malformed local URL")
        return
    end

    local p = getRelayPanel(origin)
    if p.ready then
        p.html:RunJavascript(string.format(RELAY_JS, id, util.TableToJSON(q) or "{}"))
    else
        table.insert(p.queue, { id = id, q = q })
    end
end)

-- =============================================================================
-- Diagnostics command
-- =============================================================================

concommand.Add("ainpc_voice_diag", function()
    MsgC(Color(90, 165, 255), "\n[AI NPCs] In-game Fish Audio diagnostics\n")
    local key = AINPCS.Trim(AINPCS.Settings.fishKey or "")
    MsgN("  Fish API Key set  = ", tostring(key ~= ""), " (", AINPCS.RedactKey(key), ")")
    MsgN("  Pinned voices     = ", tostring(#(AINPCS.Settings.pinnedVoices or {})))
    MsgN("  Fallback voice    = ", tostring(AINPCS.Settings.fallbackVoice))
    AINPCS.RelayHealth(function(info, code)
        MsgN("  Fish API status   = HTTP ", tostring(code), " | credit=", tostring(info and info.credits))
    end)
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
-- Spawning & Live NPC Management
-- =============================================================================

-- config = { name, description, voiceId, class, weapon, reasoning, speak }
function AINPCS.Spawn(config)
    local settings = AINPCS.Settings
    local provider = providers.get(settings.provider)
    if not provider then
        AINPCS.PushToast("Unknown provider: " .. tostring(settings.provider), "error")
        return
    end

    local key = AINPCS.Trim(settings.apiKeys[settings.provider] or "")
    if provider.id ~= "ollama" and key == "" then
        AINPCS.PushToast("No API key set for " .. provider.label .. ". Open Settings and paste one.", "error")
        return
    end

    net.Start("AINPC_SpawnRequest")
    net.WriteTable({
        provider    = settings.provider,
        -- Keys are only handed over when this client *is* the server. On someone
        -- else's server the model call is made here instead (cl_ainpcs_llm.lua),
        -- and character voices fall back to whatever key the host configured.
        apiKey      = AINPCS.IsListenHost() and key or "",
        fishKey     = AINPCS.IsListenHost() and AINPCS.Trim(settings.fishKey or "") or "",
        hostname    = settings.hostname or "",
        class       = config.class or "npc_citizen",
        bodyModel   = config.bodyModel or "",
        weapon      = config.weapon or "none",
        personality = config.description or "",
        name        = AINPCS.Trim(config.name or ""),
        libraryName = AINPCS.Trim(config.libraryName or ""),
        -- The saved character's id doubles as its memory profile, so the same
        -- character remembers you across sessions and map changes.
        profileId   = AINPCS.Trim(config.id or config.profileId or ""),
        model       = settings.model or "",
        max_tokens  = settings.max_tokens or 2048,
        temperature = settings.temperature,
        reasoning   = config.reasoning or settings.reasoning,
        enableTTS   = config.speak ~= false,
        voiceId     = Voices.NormaliseId(config.voiceId or settings.fallbackVoice),
    })
    net.SendToServer()
end

--- Tell the server how every AI NPC should think of you. Stored per player on
--- the server in data/ai_npc/personas.json and shown in every NPC's prompt.
function AINPCS.SavePersona(name, about)
    local S = AINPCS.Settings
    S.persona = S.persona or {}
    S.persona.name  = AINPCS.Trim(name or "")
    S.persona.about = AINPCS.Trim(about or "")
    AINPCS.SaveSettings()

    net.Start("AINPC_SetPersona")
    net.WriteString(S.persona.name)
    net.WriteString(S.persona.about)
    net.SendToServer()
end

--- Push the saved persona at the server (called on connect, since the server
--- does not read client data files).
function AINPCS.PushPersona()
    local p = AINPCS.Settings and AINPCS.Settings.persona
    if not istable(p) then return end
    if AINPCS.Trim(p.name or "") == "" and AINPCS.Trim(p.about or "") == "" then return end
    AINPCS.SavePersona(p.name, p.about)
end

hook.Add("InitPostEntity", "AINPC_PushPersona", function()
    timer.Simple(4, function()
        if IsValid(LocalPlayer()) then AINPCS.PushPersona() end
    end)
end)

function AINPCS.CommandNPC(ent, actionName)
    if not IsValid(ent) then return end
    net.Start("AINPC_UpdateNPC")
    net.WriteEntity(ent)
    net.WriteTable({ op = "action", action = actionName })
    net.SendToServer()
end

function AINPCS.ClearNPCMemory(ent)
    if not IsValid(ent) then return end
    local idx = ent:EntIndex()
    if AINPCS.ChatHistory then AINPCS.ChatHistory[idx] = {} end
    if AINPCS.LastChat then AINPCS.LastChat[idx] = nil end
    net.Start("AINPC_UpdateNPC")
    net.WriteEntity(ent)
    net.WriteTable({ op = "clear_memory" })
    net.SendToServer()
end

function AINPCS.UpdateLiveNPC(ent, fields)
    if not IsValid(ent) or not istable(fields) then return end
    local payload = table.Copy(fields)
    payload.op = "edit"
    payload.fishKey = AINPCS.Trim(AINPCS.Settings.fishKey or "")
    net.Start("AINPC_UpdateNPC")
    net.WriteEntity(ent)
    net.WriteTable(payload)
    net.SendToServer()
end
