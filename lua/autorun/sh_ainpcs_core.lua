--[[
    AI NPCs — shared core
    Runs on both client and server. Registers network strings, constants,
    weapons, emotions/facial flexes, loose JSON parsing, and shared helpers.
]]

AINPCS = AINPCS or {}
AINPCS.Version = "4.2.0"

AINPCS.NetStrings = {
    "AINPC_SpawnRequest",
    "AINPC_SpawnResult",
    "AINPC_ModelPreview",
    "AINPC_ModelPreviewResponse",
    "AINPC_ChatRequest",
    "AINPC_ChatReply",
    "AINPC_OpenChatUI",
    "AINPC_TTSPlay",
    "AINPC_TTSAudio",
    "AINPC_Toast",
    "AINPC_OpenRouterModels",
    "AINPC_RequestORModels",
    "AINPC_UpdateNPC",
    "AINPC_LocalRelayReq",
    "AINPC_LocalRelayRes",
    "AINPC_LLMRequest",
    "AINPC_LLMReply",
    "AINPC_SetPersona",
}

AINPCS.Defaults = {
    MaxHistoryTurns = 16,
    InteractRange = 140,
    ChatCooldownSeconds = 1.2,
    SpawnCooldownSeconds = 3,
    MaxNPCsPerPlayer = 5,
    -- Hard ceiling on a single provider round-trip.
    RequestTimeout = 60,
}

-- Weapons an AI NPC can spawn with or switch to -------------------------------

AINPCS.WeaponOrder = {
    "none",
    "default",
    "weapon_pistol",
    "weapon_357",
    "weapon_smg1",
    "weapon_shotgun",
    "weapon_ar2",
    "weapon_crossbow",
    "weapon_rpg",
    "weapon_crowbar",
    "weapon_stunstick",
    "weapon_alyxgun",
    "weapon_annabelle",
}

AINPCS.Weapons = {
    ["none"]             = { id = "none",             label = "Unarmed",                        desc = "no weapon" },
    ["default"]          = { id = "default",          label = "Default NPC Weapon",             desc = "class defaultweapon" },
    ["weapon_pistol"]    = { id = "weapon_pistol",    label = "9mm Pistol",                     desc = "a 9mm pistol" },
    ["weapon_357"]       = { id = "weapon_357",       label = ".357 Magnum",                    desc = "a .357 magnum revolver" },
    ["weapon_smg1"]      = { id = "weapon_smg1",      label = "SMG",                            desc = "an SMG" },
    ["weapon_shotgun"]   = { id = "weapon_shotgun",   label = "Shotgun",                        desc = "a shotgun" },
    ["weapon_ar2"]       = { id = "weapon_ar2",       label = "Pulse Rifle (AR2)",              desc = "a Combine pulse rifle (AR2)" },
    ["weapon_crossbow"]  = { id = "weapon_crossbow",  label = "Crossbow",                       desc = "a resistance crossbow" },
    ["weapon_rpg"]       = { id = "weapon_rpg",       label = "RPG Launcher",                   desc = "a rocket launcher" },
    ["weapon_crowbar"]   = { id = "weapon_crowbar",   label = "Crowbar",                        desc = "a crowbar" },
    ["weapon_stunstick"] = { id = "weapon_stunstick", label = "Stunstick",                      desc = "a Civil Protection stunstick" },
    ["weapon_alyxgun"]   = { id = "weapon_alyxgun",   label = "Alyx's Gun",                     desc = "Alyx's automatic pistol" },
    ["weapon_annabelle"] = { id = "weapon_annabelle", label = "Father Grigori's Rifle",         desc = "a lever-action rifle" },
}

-- Human-readable weapon description for any entity weapon class
AINPCS.WeaponNames = {
    weapon_crowbar    = "a crowbar",
    weapon_pistol     = "a pistol",
    weapon_357        = "a .357 magnum",
    weapon_smg1       = "an SMG",
    weapon_ar2        = "a pulse rifle",
    weapon_shotgun    = "a shotgun",
    weapon_crossbow   = "a crossbow",
    weapon_rpg        = "a rocket launcher",
    weapon_frag       = "a grenade",
    weapon_physcannon = "a gravity gun",
    weapon_physgun    = "a physics gun",
    gmod_tool         = "a tool gun",
    gmod_camera       = "a camera",
    weapon_bugbait    = "bugbait",
    weapon_stunstick  = "a stunstick",
    weapon_slam       = "a SLAM explosive",
    weapon_medkit     = "a medkit",
    weapon_fists      = "their fists",
    weapon_alyxgun    = "an automatic pistol",
    weapon_annabelle  = "a rifle",
}

function AINPCS.WeaponLabel(id)
    if not id or id == "" then return "Unarmed" end
    local w = AINPCS.Weapons[id]
    return (w and w.label) or id
end

function AINPCS.DescribeWeapon(wepEnt)
    if not IsValid(wepEnt) then return nil end
    local cls = string.lower(wepEnt:GetClass() or "")
    if AINPCS.WeaponNames[cls] then return AINPCS.WeaponNames[cls] end
    local printName = wepEnt.GetPrintName and wepEnt:GetPrintName() or wepEnt.PrintName
    if isstring(printName) and printName ~= "" and not string.find(printName, "^#") then
        return printName
    end
    return string.gsub(cls, "^weapon_", "a ")
end

-- Emotions & Source Engine facial flexes (GM:MouthMoveAnimation + FACS) -------

AINPCS.Emotions = {
    neutral = true, happy = true, excited = true, sad = true, angry = true,
    annoyed = true, scared = true, surprised = true, curious = true, embarrassed = true,
}

-- Mouth flexes from GM:MouthMoveAnimation
AINPCS.MouthFlexes = {
    { name = "jaw_drop",         scale = 1.0 },
    { name = "left_part",        scale = 0.7 },
    { name = "right_part",       scale = 0.7 },
    { name = "left_mouth_drop",  scale = 0.6 },
    { name = "right_mouth_drop", scale = 0.6 },
}

-- Emotional facial flex maps
AINPCS.Expressions = {
    happy       = { smile = 0.8, right_cheek_raiser = 0.5, left_cheek_raiser = 0.5, right_corner_puller = 0.6, left_corner_puller = 0.6 },
    excited     = { smile = 1.0, right_cheek_raiser = 0.6, left_cheek_raiser = 0.6, right_outer_raiser = 0.5, left_outer_raiser = 0.5 },
    sad         = { right_inner_raiser = 0.8, left_inner_raiser = 0.8, right_corner_depressor = 0.7, left_corner_depressor = 0.7 },
    angry       = { right_lowerer = 1.0, left_lowerer = 1.0, right_lid_tightener = 0.6, left_lid_tightener = 0.6, presser = 0.4 },
    annoyed     = { right_lowerer = 0.5, left_lowerer = 0.5, right_corner_depressor = 0.3, left_corner_depressor = 0.3 },
    scared      = { right_inner_raiser = 0.9, left_inner_raiser = 0.9, right_outer_raiser = 0.7, left_outer_raiser = 0.7,
                    right_lid_raiser = 0.8, left_lid_raiser = 0.8, right_stretcher = 0.5, left_stretcher = 0.5 },
    surprised   = { right_inner_raiser = 1.0, left_inner_raiser = 1.0, right_outer_raiser = 1.0, left_outer_raiser = 1.0,
                    right_lid_raiser = 0.7, left_lid_raiser = 0.7, jaw_drop = 0.35 },
    curious     = { right_outer_raiser = 0.6, left_inner_raiser = 0.3 },
    embarrassed = { smile = 0.3, right_inner_raiser = 0.4, left_inner_raiser = 0.4 },
}

if SERVER then
    AddCSLuaFile("autorun/sh_ainpcs_core.lua")
    AddCSLuaFile("autorun/sh_ainpcs_debug.lua")
    AddCSLuaFile("autorun/client/cl_0_ainpcs_shared.lua")
    AddCSLuaFile("autorun/client/cl_1_ainpcs_ui.lua")
    AddCSLuaFile("autorun/client/cl_2_ainpcs_open.lua")
    AddCSLuaFile("autorun/client/cl_ainpcs_browsers.lua")
    AddCSLuaFile("autorun/client/cl_ainpcs_setup.lua")
    AddCSLuaFile("autorun/client/cl_ainpcs_llm.lua")
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

-- String & URL helpers --------------------------------------------------------

function AINPCS.Trim(str)
    if not str then return "" end
    return (string.gsub(tostring(str), "^%s*(.-)%s*$", "%1"))
end

function AINPCS.IsBlank(str)
    return not str or AINPCS.Trim(str) == ""
end

function AINPCS.Truncate(str, limit)
    if not str then return "" end
    str = tostring(str)
    if #str <= limit then return str end
    return string.sub(str, 1, limit - 1) .. "…"
end

function AINPCS.CleanText(str, maxLen)
    if not isstring(str) then return "" end
    str = string.gsub(str, "[%c]+", " ")
    str = string.gsub(str, "%s+", " ")
    str = AINPCS.Trim(str)
    if maxLen and #str > maxLen then
        str = AINPCS.Trim(string.sub(str, 1, maxLen))
    end
    return str
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

function AINPCS.IsLocalURL(url)
    local host = string.lower(string.match(url or "", "^https?://([^/:]+)") or "")
    return host == "localhost"
        or string.match(host, "^127%.") ~= nil
        or string.match(host, "^10%.") ~= nil
        or string.match(host, "^192%.168%.") ~= nil
        or string.match(host, "^172%.1[6-9]%.") ~= nil
        or string.match(host, "^172%.2%d%.") ~= nil
        or string.match(host, "^172%.3[01]%.") ~= nil
        or host == "0.0.0.0"
        or host == "[::1]"
end

-- Single source of truth for an AI NPC's display name ----------------------
--
-- The networked AINPCName is authoritative; SetName() is kept in sync so any
-- addon or engine path that reads Entity:GetName() shows the character's name
-- instead of the spawn class. Never fall back to the NPC class name here: that
-- is exactly how "Citizen" ends up where "Rick Sanchez" should be.
function AINPCS.NPCName(ent)
    if not IsValid(ent) then return "NPC" end

    local nw = ent.GetNWString and ent:GetNWString("AINPCName", "") or ""
    if isstring(nw) and AINPCS.Trim(nw) ~= "" then return AINPCS.Trim(nw) end

    local eng = ent.GetName and ent:GetName() or ""
    if isstring(eng) and AINPCS.Trim(eng) ~= "" then return AINPCS.Trim(eng) end

    return "NPC"
end

--- Is this a model path an AI NPC body can actually use?
---
--- Deliberately a shape check, not util.IsValidModel: that call returns false for
--- addon models that have not been mounted yet at the moment we ask, which made
--- whole lists of perfectly good bodies vanish from the browser.
function AINPCS.IsUsableBodyModel(model)
    if not isstring(model) or model == "" then return false end
    if not string.find(string.lower(model), "%.mdl$") then return false end
    if string.find(model, " ") then return false end
    return true
end

-- Provider response handling (shared so a client-side request parses the same
-- way a server-side one does).

--- Pull the assistant text out of an OpenAI-compatible, Ollama or Anthropic reply.
function AINPCS.ExtractReplyContent(response)
    if not istable(response) then return nil end

    local choices = response.choices
    if istable(choices) and istable(choices[1]) and istable(choices[1].message) then
        local content = choices[1].message.content
        if isstring(content) then return content end
        if istable(content) then
            local parts = {}
            for _, p in ipairs(content) do
                if istable(p) and isstring(p.text) then parts[#parts + 1] = p.text end
            end
            return table.concat(parts, "")
        end
    end

    -- Ollama / OpenAI-compatible non-choices shape
    if istable(response.message) and isstring(response.message.content) then
        return response.message.content
    end

    -- Anthropic messages API
    if istable(response.content) then
        local parts = {}
        for _, block in ipairs(response.content) do
            if istable(block) and block.type == "text" and isstring(block.text) then
                parts[#parts + 1] = block.text
            end
        end
        if #parts > 0 then return table.concat(parts, "") end
    end

    return nil
end

--- Human-readable error text from a provider's error payload.
function AINPCS.ExtractProviderError(response)
    if not istable(response) then return nil end
    local err = response.error
    if isstring(err) then return err end
    if istable(err) then
        if isstring(err.message) then return err.message end
        if err.message ~= nil then return tostring(err.message) end
        if err.code ~= nil then return tostring(err.code) end
        return "provider returned an error"
    end
    if isstring(response.message) then return response.message end
    if isstring(response.detail) then return response.detail end
    return nil
end

--- Turn whatever the model actually emitted into something safe to say out loud.
---
--- The common failure is a reply that *should* have been JSON but was truncated,
--- wrapped in a code fence, or missing a brace, so ParseJSONLoose returns nil. The
--- old fallback spoke the raw text, which is how models end up reading their own
--- {"thought": "..."} scaffolding aloud. This strips that first.
function AINPCS.CleanSpokenText(raw)
    if not isstring(raw) or raw == "" then return "" end

    local text = AINPCS.CleanModelText(raw)
    local looksJSON = string.find(text, "^%s*{") ~= nil
    local hasSayKey = string.find(text, "[\"']say[\"']%s*:") ~= nil

    if looksJSON or hasSayKey then
        -- Prefer the spoken field. Truncated replies are common, so an
        -- unterminated value is accepted as well as a properly closed one.
        local sayField =
            string.match(text, "[\"']say[\"']%s*:%s*[\"'](.-)[\"']%s*[,}]") or
            string.match(text, "[\"']say[\"']%s*:%s*[\"'](.-)$") or
            string.match(text, "[\"']say[\"']%s*:%s*[\"']([^\"']*)")

        if isstring(sayField) and AINPCS.Trim(sayField) ~= "" then
            text = sayField
        elseif looksJSON then
            -- Shell and actions but nothing to say: stay silent rather than read
            -- the scaffolding out loud.
            return ""
        else
            -- "say": null, or a broken value inside otherwise ordinary text.
            text = string.gsub(text, "[\"']say[\"']%s*:%-?[%w%.]+", " ")
        end
    end

    text = string.gsub(text, "<[^>]->", " ")
    text = AINPCS.CleanText(text, 480)

    if text == "" or text == "{" or text == "}" or text == "[]"
        or text == "null" or text == "nil" then
        return ""
    end

    return text
end

-- Strict JSON parse that swallows nil gracefully (with ignoreLimits = true).
function AINPCS.SafeJSON(body)
    if not body or body == "" then return nil end
    local ok, tbl = pcall(util.JSONToTable, body, true)
    if not ok then return nil end
    return tbl
end

-- Strip <think>...</think> blocks and markdown code fences some models emit.
function AINPCS.CleanModelText(text)
    if not isstring(text) then return "" end
    text = string.gsub(text, "<think>.-</think>", "")
    text = string.gsub(text, "<thinking>.-</thinking>", "")
    text = string.gsub(text, "^%s*<think>.*$", "")
    text = string.gsub(text, "```[%w_-]*", "")
    return AINPCS.Trim(text)
end

-- Extract the first balanced {...} JSON object from model output and decode it.
function AINPCS.ParseJSONLoose(text)
    if not isstring(text) then return nil end
    text = AINPCS.CleanModelText(text)
    local start = string.find(text, "{", 1, true)
    if not start then return nil end

    local depth, inString, escaped = 0, false, false
    local finish
    for i = start, #text do
        local c = string.sub(text, i, i)
        if inString then
            if escaped then escaped = false
            elseif c == "\\" then escaped = true
            elseif c == "\"" then inString = false end
        else
            if c == "\"" then inString = true
            elseif c == "{" then depth = depth + 1
            elseif c == "}" then
                depth = depth - 1
                if depth == 0 then finish = i break end
            end
        end
    end

    local candidate = string.sub(text, start, finish or #text)
    if not finish and depth > 0 then
        candidate = candidate .. string.rep("}", math.max(depth, 1))
    end

    local tbl = AINPCS.SafeJSON(candidate)
    if istable(tbl) then return tbl end

    -- Common LLM JSON repairs: trailing commas, smart quotes
    candidate = string.gsub(candidate, ",%s*([}%]])", "%1")
    candidate = string.gsub(candidate, "\226\128\156", "\"")
    candidate = string.gsub(candidate, "\226\128\157", "\"")
    tbl = AINPCS.SafeJSON(candidate)
    if istable(tbl) then return tbl end
    return nil
end

-- Jaccard word similarity (0..1) to prevent repetitive NPC lines.
function AINPCS.LineSimilarity(a, b)
    local sa, na = {}, 0
    for w in string.gmatch(string.lower(tostring(a or "")), "[%w']+") do
        if not sa[w] then sa[w] = true na = na + 1 end
    end
    local sb, nb = {}, 0
    for w in string.gmatch(string.lower(tostring(b or "")), "[%w']+") do
        if not sb[w] then sb[w] = true nb = nb + 1 end
    end
    if na == 0 or nb == 0 then return 0 end
    local common = 0
    for w in pairs(sa) do if sb[w] then common = common + 1 end end
    return common / (na + nb - common)
end

-- History trimming — keeps the system prompt plus the last N turns,
-- always starting on a "user" message so strict providers never fail.
function AINPCS.TrimHistory(history, maxTurns)
    if not history or #history <= 1 then return history end
    maxTurns = maxTurns or AINPCS.Defaults.MaxHistoryTurns
    local maxMessages = maxTurns * 2

    if #history - 1 <= maxMessages then return history end

    local trimmed = { history[1] }
    local start = #history - maxMessages + 1
    if start < 2 then start = 2 end
    while start <= #history and history[start] and history[start].role == "assistant" do
        start = start + 1
    end
    for i = start, #history do
        table.insert(trimmed, history[i])
    end
    return trimmed
end

return AINPCS
