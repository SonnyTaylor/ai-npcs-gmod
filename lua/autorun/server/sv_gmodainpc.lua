--[[
    AI NPCs — server brain & world controller

    Owns NPC state, situational awareness, multi-player transcript & memory,
    weapons, LLM-driven actions (follow, stay, come, wander, attack, stop_attacking,
    flee, switch_weapon, drop_weapon, use, gesture), facial emotions & mouth movement,
    native HL2 voice suppression, and in-game Fish Audio TTS streaming.
]]

local providers = include("providers/providers.lua")
local Voices    = include("voices/voices.lua")

-- Load the OpenRouter provider at boot so its model refresh timer starts immediately.
providers.get("openrouter")

-- =============================================================================
-- Convars
-- =============================================================================

local CV_ENABLED       = CreateConVar("ainpc_enabled",                "1",   FCVAR_ARCHIVE, "Master switch for the AI NPCs addon.")
local CV_ADMIN_ONLY    = CreateConVar("ainpc_admin_only",             "0",   FCVAR_ARCHIVE, "If 1, only admins can spawn AI NPCs.")
local CV_MAX_PER_PLY   = CreateConVar("ainpc_max_per_player",         "5",   FCVAR_ARCHIVE, "Maximum AI NPCs a single player may own at once.")
local CV_COOLDOWN      = CreateConVar("ainpc_cooldown_seconds",       "3",   FCVAR_ARCHIVE, "Cooldown between NPC spawns per player (seconds).")
local CV_CHAT_COOLDOWN = CreateConVar("ainpc_chat_cooldown_seconds",  "1.2", FCVAR_ARCHIVE, "Cooldown between chat messages per player (seconds).")
local CV_PROXIMITY     = CreateConVar("ainpc_proximity_chat",         "1",   FCVAR_ARCHIVE, "If 1, chat messages auto-route to the addressed/nearest AI NPC within range.")
local CV_PROXIMITY_R   = CreateConVar("ainpc_proximity_range",        "350", FCVAR_ARCHIVE, "Max distance (units) for proximity chat auto-routing.")
local CV_INTERACT_R    = CreateConVar("ainpc_interact_range",         "160", FCVAR_ARCHIVE, "Max distance (units) for pressing E to open the chat UI.")
local CV_ALLOWED_TTS   = CreateConVar("ainpc_tts_allowed",            "1",   FCVAR_ARCHIVE, "If 1, AI NPCs may speak out loud via TTS.")
local CV_ALLOW_ACTIONS = CreateConVar("ainpc_allow_actions",          "1",   FCVAR_ARCHIVE, "If 1, AI NPCs can perform physical actions (follow, stay, attack, flee, gestures, etc.).")
local CV_ALLOW_PVP     = CreateConVar("ainpc_allow_pvp",              "1",   FCVAR_ARCHIVE, "If 1, AI NPCs can fight players when provoked or instructed.")
local CV_REACTIVE      = CreateConVar("ainpc_reactive_events",        "1",   FCVAR_ARCHIVE, "If 1, AI NPCs react in-character when attacked or injured.")
local CV_MUTE_HL2      = CreateConVar("ainpc_mute_hl2_voice",         "1",   FCVAR_ARCHIVE, "If 1, suppresses default Half-Life 2 voice lines on AI NPCs so they don't overlap AI speech.")
local CV_OR_REFRESH    = CreateConVar("ainpc_openrouter_autorefresh", "1",   FCVAR_ARCHIVE, "If 1, periodically fetch the current OpenRouter free-model list.")

-- =============================================================================
-- Localhost HTTP Relay (via CHTTP or Host Client's hidden DHTML browser)
-- Allows local Ollama / local TTS to work in singleplayer & listen servers
-- without needing -allowlocalhttp.
-- =============================================================================

local chttpFn = nil
local function getCHTTP()
    if chttpFn ~= nil then return chttpFn end
    chttpFn = false
    if util.IsBinaryModuleInstalled and util.IsBinaryModuleInstalled("chttp") then
        local ok = pcall(require, "chttp")
        if ok and isfunction(CHTTP) then chttpFn = CHTTP end
    end
    return chttpFn
end

local LocalRelay = { pending = {}, nextId = 0 }
local RELAY_CHUNK = 28000

local function getListenHost()
    if game.IsDedicated() then return nil end
    if game.SinglePlayer() then
        local p = player.GetHumans()[1]
        return IsValid(p) and p or nil
    end
    for _, p in ipairs(player.GetHumans()) do
        if p.IsListenServerHost and p:IsListenServerHost() then return p end
    end
    return nil
end

local function failRelayJob(id, why)
    local job = LocalRelay.pending[id]
    if not job then return end
    LocalRelay.pending[id] = nil
    timer.Remove("AINPC_LocalRelay_" .. id)
    if job.req.failed then job.req.failed(why) end
end

function AINPCS.HTTP(req)
    if AINPCS.IsLocalURL(req.url) then
        local c = getCHTTP()
        if c then return c(req) end
        local host = getListenHost()
        if IsValid(host) then
            LocalRelay.nextId = (LocalRelay.nextId + 1) % 60000
            local id = LocalRelay.nextId
            local headers = table.Copy(req.headers or {})
            if req.type and not headers["Content-Type"] then
                headers["Content-Type"] = req.type
            end
            local payload = util.Compress(util.TableToJSON({
                url     = req.url,
                method  = string.upper(req.method or "GET"),
                headers = headers,
                body    = req.body,
            }) or "{}")
            LocalRelay.pending[id] = { req = req, host = host, parts = {}, got = 0 }
            local total = math.max(1, math.ceil(#payload / RELAY_CHUNK))
            for i = 1, total do
                local part = string.sub(payload, (i - 1) * RELAY_CHUNK + 1, i * RELAY_CHUNK)
                net.Start("AINPC_LocalRelayReq")
                net.WriteUInt(id, 16)
                net.WriteUInt(i, 8)
                net.WriteUInt(total, 8)
                net.WriteUInt(#part, 16)
                net.WriteData(part, #part)
                net.Send(host)
            end
            timer.Create("AINPC_LocalRelay_" .. id, (req.timeout or 35) + 5, 1, function()
                failRelayJob(id, "Local AI service timed out — is Ollama running?")
            end)
            return true
        end
    end
    return HTTP(req)
end

net.Receive("AINPC_LocalRelayRes", function(_, ply)
    local id = net.ReadUInt(16)
    local job = LocalRelay.pending[id]
    if not job or job.host ~= ply then return end
    local idx   = net.ReadUInt(8)
    local total = net.ReadUInt(8)
    local code  = net.ReadUInt(16)
    local len   = net.ReadUInt(16)
    local data  = net.ReadData(len)
    if total < 1 or idx < 1 or idx > total then return end
    if not job.parts[idx] then
        job.parts[idx] = data
        job.got = job.got + 1
    end
    if job.got < total then return end
    LocalRelay.pending[id] = nil
    timer.Remove("AINPC_LocalRelay_" .. id)
    local body = table.concat(job.parts)
    if code == 0 then
        if job.req.failed then job.req.failed(body) end
    elseif job.req.success then
        job.req.success(code, body, {})
    end
end)

-- =============================================================================
-- State
-- =============================================================================

local NPCs = {}
local ModelQuirks = {} -- ["provider|model"] = { no_temp, no_reasoning, tokens_field }

local NextSpawn   = {}
local NextChat    = {}
local NextUse     = {}
local NextPreview = {}

local NPC_FRIENDLY_NAMES = {
    npc_zombie = "Zombie", npc_fastzombie = "Fast Zombie", npc_poisonzombie = "Poison Zombie",
    npc_zombine = "Zombine", npc_zombie_torso = "Zombie Torso", npc_fastzombie_torso = "Fast Zombie Torso",
    npc_headcrab = "Headcrab", npc_headcrab_fast = "Fast Headcrab", npc_headcrab_black = "Poison Headcrab",
    npc_headcrab_poison = "Poison Headcrab", npc_antlion = "Antlion", npc_antlion_worker = "Antlion Worker",
    npc_antlionguard = "Antlion Guard", npc_combine_s = "Combine Soldier", npc_metropolice = "Metrocop",
    npc_hunter = "Hunter", npc_strider = "Strider", npc_manhack = "Manhack", npc_cscanner = "City Scanner",
    npc_clawscanner = "Shield Scanner", npc_barnacle = "Barnacle", npc_rollermine = "Rollermine",
    npc_turret_floor = "Combine Turret", npc_combinegunship = "Combine Gunship", npc_helicopter = "Combine Helicopter",
    npc_citizen = "Citizen", npc_alyx = "Alyx Vance", npc_barney = "Barney Calhoun", npc_kleiner = "Dr. Kleiner",
    npc_eli = "Eli Vance", npc_mossman = "Dr. Mossman", npc_monk = "Father Grigori", npc_breen = "Dr. Breen",
    npc_vortigaunt = "Vortigaunt", npc_dog = "Dog", npc_gman = "G-Man", npc_crow = "Crow", npc_pigeon = "Pigeon",
    npc_seagull = "Seagull", npc_stalker = "Stalker",
}

local HOSTILE_CLASSES = {
    npc_zombie = true, npc_fastzombie = true, npc_poisonzombie = true, npc_zombine = true,
    npc_zombie_torso = true, npc_fastzombie_torso = true, npc_headcrab = true, npc_headcrab_fast = true,
    npc_headcrab_black = true, npc_headcrab_poison = true, npc_antlion = true, npc_antlion_worker = true,
    npc_antlionguard = true, npc_combine_s = true, npc_metropolice = true, npc_hunter = true,
    npc_strider = true, npc_manhack = true, npc_barnacle = true, npc_rollermine = true,
    npc_turret_floor = true, npc_combinegunship = true, npc_helicopter = true,
}

local function plyKey(ply)
    if not IsValid(ply) then return "_" end
    return ply:SteamID64() or ("ent_" .. ply:EntIndex())
end

local function speakerName(ply)
    if not IsValid(ply) then return nil end
    if ply:IsPlayer() then
        local nick = AINPCS.Trim(ply:Nick() or "")
        nick = string.gsub(nick, "[\r\n\"\\]", "")
        if nick == "" then return "Player" end
        if #nick > 32 then nick = string.sub(nick, 1, 32) end
        return nick
    end
    if ply:GetNWBool("IsAINPC", false) then
        return AINPCS.NPCName(ply)
    end
    local cls = ply:GetClass() or "entity"
    return NPC_FRIENDLY_NAMES[cls] or cls
end

local function describeEntity(ent)
    if not IsValid(ent) then return "something" end
    if ent:IsPlayer() then return speakerName(ent) end
    if ent:GetNWBool("IsAINPC", false) then return AINPCS.NPCName(ent) end
    if ent:IsNPC() or ent:IsNextBot() then
        local cls = ent:GetClass() or ""
        return "a " .. (NPC_FRIENDLY_NAMES[cls] or string.gsub(cls, "^npc_", ""))
    end
    if ent:IsVehicle() then return "a vehicle" end
    local cls = ent:GetClass() or "object"
    if cls == "worldspawn" then return "a fall" end
    if string.find(cls, "^prop_") then
        local mdl = string.match(string.lower(ent:GetModel() or ""), "([^/]+)%.mdl$") or "prop"
        return "a " .. string.gsub(mdl, "_", " ")
    end
    return "a " .. string.gsub(cls, "_", " ")
end

local function meters(units)
    return math.Round((units or 0) * 0.01905, 1)
end

local function timeAgo(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds <= 2 then return "just now" end
    if seconds < 60 then return seconds .. "s ago" end
    return math.floor(seconds / 60) .. "m ago"
end

local function countNPCsOwnedBy(ply)
    local key = plyKey(ply)
    local n = 0
    for _, rec in pairs(NPCs) do
        if IsValid(rec.ent) and rec.ownerKey == key then n = n + 1 end
    end
    return n
end

local function sendToast(ply, text, kind)
    if not IsValid(ply) then return end
    net.Start("AINPC_Toast")
    net.WriteString(text or "")
    net.WriteString(kind or "info")
    net.Send(ply)
end

local function chatAllowed(ply)
    local key = plyKey(ply)
    local now = CurTime()
    if (NextChat[key] or 0) > now then
        sendToast(ply, "Slow down — try again in a moment.", "error")
        return false
    end
    NextChat[key] = now + CV_CHAT_COOLDOWN:GetFloat()
    return true
end

local function setThinking(rec, isThinking)
    if not IsValid(rec.ent) then return end
    rec.thinking = isThinking and true or false
    rec.ent:SetNWBool("AINPCThinking", rec.thinking)
end

local function setMood(rec, mood)
    if not IsValid(rec.ent) then return end
    mood = string.lower(AINPCS.Trim(mood or "neutral"))
    if not AINPCS.Emotions[mood] then mood = "neutral" end
    rec.mood = mood
    rec.moodUntil = (mood ~= "neutral") and (CurTime() + 60) or nil
    rec.ent:SetNWString("AINPCMood", mood)
end

local function setActivityLabel(rec, label)
    if not IsValid(rec.ent) then return end
    rec.activityLabel = label or "idle"
    rec.ent:SetNWString("AINPCActivity", rec.activityLabel)
end

-- =============================================================================
-- Person memory & affinity helpers
-- =============================================================================

local function affinityLabel(score)
    score = score or 0
    if score >= 50 then return "close friend"
    elseif score >= 20 then return "friendly"
    elseif score >= 6 then return "warm"
    elseif score <= -50 then return "sworn enemy"
    elseif score <= -20 then return "hostile"
    elseif score <= -6 then return "annoyed with them"
    end
    return "neutral"
end

local function getPersonRecord(rec, ply)
    if not IsValid(ply) or not ply:IsPlayer() then return nil end
    local k = plyKey(ply)
    rec.people = rec.people or {}
    local p = rec.people[k]
    if not p then
        p = {
            name     = speakerName(ply),
            affinity = (k == rec.ownerKey) and 15 or 0,
            facts    = {},
            lastTalk = 0,
        }
        rec.people[k] = p
    else
        p.name = speakerName(ply)
    end
    return p
end

local function adjustAffinity(rec, ply, delta)
    local p = getPersonRecord(rec, ply)
    if not p then return end
    p.affinity = math.Clamp((p.affinity or 0) + (delta or 0), -100, 100)
end

local function addPersonFact(rec, ply, factText)
    factText = AINPCS.CleanText(factText, 160)
    if factText == "" or #factText < 4 then return end
    if IsValid(ply) and ply:IsPlayer() then
        local p = getPersonRecord(rec, ply)
        if not p then return end
        local low = string.lower(factText)
        for _, f in ipairs(p.facts) do
            if string.lower(f) == low then return end
        end
        table.insert(p.facts, factText)
        while #p.facts > 10 do table.remove(p.facts, 1) end
    else
        rec.notes = rec.notes or {}
        local low = string.lower(factText)
        for _, n in ipairs(rec.notes) do
            if string.lower(n) == low then return end
        end
        table.insert(rec.notes, factText)
        while #rec.notes > 12 do table.remove(rec.notes, 1) end
    end
end

local function addEvent(rec, text, importance)
    if not rec then return end
    text = AINPCS.CleanText(text, 200)
    if text == "" then return end
    rec.events = rec.events or {}
    table.insert(rec.events, { t = CurTime(), text = text, importance = importance or 1 })
    while #rec.events > 14 do table.remove(rec.events, 1) end
end

local function addTranscript(rec, who, text, isSelf, isAddressed)
    if not rec then return end
    text = AINPCS.CleanText(text, 400)
    if text == "" then return end
    rec.transcript = rec.transcript or {}
    table.insert(rec.transcript, {
        t         = CurTime(),
        who       = who or "Someone",
        text      = text,
        self      = isSelf == true,
        addressed = isAddressed == true,
    })
    while #rec.transcript > 24 do table.remove(rec.transcript, 1) end
end

-- =============================================================================
-- Weapons helper
-- =============================================================================

local function resolveWeaponClass(weaponChoice, npcData)
    weaponChoice = AINPCS.Trim(weaponChoice or "none")
    if weaponChoice == "" or weaponChoice == "none" then
        return nil
    end
    if weaponChoice == "default" then
        local cvWep = GetConVar("gmod_npcweapon")
        local cvVal = cvWep and AINPCS.Trim(cvWep:GetString() or "") or ""
        if cvVal ~= "" and cvVal ~= "none" then return cvVal end
        if npcData and istable(npcData.Weapons) and #npcData.Weapons > 0 then
            return npcData.Weapons[1]
        end
        return "weapon_smg1"
    end
    return weaponChoice
end

local function giveNPCWeapon(ent, weaponChoice, npcData)
    if not IsValid(ent) then return end
    local wepClass = resolveWeaponClass(weaponChoice, npcData)

    local active = ent.GetActiveWeapon and ent:GetActiveWeapon()
    if IsValid(active) then
        if wepClass and string.lower(active:GetClass()) == string.lower(wepClass) then
            return
        end
        active:Remove()
    end

    if not wepClass then
        ent:SetNWString("AINPCWeapon", "none")
        return
    end

    if ent.Give then
        pcall(ent.Give, ent, wepClass)
    end
    if ent.SetCurrentWeaponProficiency then
        pcall(ent.SetCurrentWeaponProficiency, ent, WEAPON_PROFICIENCY_VERY_GOOD)
    end
    ent:SetNWString("AINPCWeapon", wepClass)
end

-- =============================================================================
-- NPC lookup / spawn
-- =============================================================================

local function lookupNPCData(class)
    local registry = list.Get("NPC") or {}
    return registry[class]
end

local function findSafeSpawnPos(ply)
    local tr = ply:GetEyeTrace()
    local pos = tr.HitPos + tr.HitNormal * 16

    if bit.band(util.PointContents(pos), CONTENTS_SOLID) ~= 0 or tr.HitSky then
        pos = ply:GetPos() + ply:GetForward() * 80
    end

    local down = util.TraceLine({
        start = pos + Vector(0, 0, 16),
        endpos = pos - Vector(0, 0, 256),
        filter = ply,
        mask = MASK_NPCWORLDSTATIC,
    })
    if down.Hit then pos = down.HitPos + Vector(0, 0, 2) end

    return pos
end

local function cleanupNPC(entIndex)
    local rec = NPCs[entIndex]
    if not rec then return end
    timer.Remove("AINPC_Timeout_" .. entIndex)
    if IsValid(rec.ent) then rec.ent:SetNWBool("IsAINPC", false) end
    NPCs[entIndex] = nil
end

local function cleanupAll()
    for idx, rec in pairs(NPCs) do
        timer.Remove("AINPC_Timeout_" .. idx)
        if IsValid(rec.ent) then rec.ent:Remove() end
    end
    NPCs = {}
end

local function spawnAINPC(ply, data)
    if not CV_ENABLED:GetBool() then
        sendToast(ply, "AI NPCs are disabled on this server.", "error")
        return
    end

    if CV_ADMIN_ONLY:GetBool() and not ply:IsAdmin() then
        sendToast(ply, "Only admins can spawn AI NPCs on this server.", "error")
        return
    end

    local now = CurTime()
    local key = plyKey(ply)
    if (NextSpawn[key] or 0) > now then
        sendToast(ply, string.format("Wait %.1fs before spawning another NPC.", (NextSpawn[key] or 0) - now), "error")
        return
    end

    if countNPCsOwnedBy(ply) >= CV_MAX_PER_PLY:GetInt() then
        sendToast(ply, "You already have the maximum number of AI NPCs spawned.", "error")
        return
    end

    local provider = providers.get(data.provider or "")
    if not provider then
        sendToast(ply, "Unknown provider: " .. tostring(data.provider), "error")
        return
    end

    if provider.id ~= "ollama" and AINPCS.IsBlank(data.apiKey) then
        sendToast(ply, "API key required for " .. provider.label .. ". Open Settings and paste one.", "error")
        return
    end

    local npcData = lookupNPCData(data.class)
    if not npcData then
        sendToast(ply, "Unknown NPC class: " .. tostring(data.class), "error")
        return
    end

    local entClass = npcData.Class or data.class
    local ent = ents.Create(entClass)
    if not IsValid(ent) then
        sendToast(ply, "Failed to create entity of class " .. tostring(entClass), "error")
        return
    end

    local pos = findSafeSpawnPos(ply)
    local yaw = (ply:GetPos() - pos):Angle().y
    ent:SetPos(pos)
    ent:SetAngles(Angle(0, yaw, 0))
    if npcData.Model then ent:SetModel(npcData.Model) end
    if npcData.KeyValues then
        for k, v in pairs(npcData.KeyValues) do ent:SetKeyValue(k, tostring(v)) end
    end
    if npcData.SpawnFlags then
        ent:SetKeyValue("spawnflags", tostring(npcData.SpawnFlags))
    end

    local weaponChoice = data.weapon or "none"
    local wepClass = resolveWeaponClass(weaponChoice, npcData)
    if wepClass then
        ent:SetKeyValue("additionalequipment", wepClass)
    end

    ent:Spawn()
    ent:Activate()

    -- Body override: the browser can hand us any NPC body or playermodel. Apply it
    -- after Spawn() so the class's own model never wins.
    local bodyModel = AINPCS.Trim(data.bodyModel or "")
    if bodyModel ~= "" and AINPCS.IsUsableBodyModel(bodyModel) then
        ent:SetModel(bodyModel)
    end

    if wepClass then
        giveNPCWeapon(ent, weaponChoice, npcData)
    else
        ent:SetNWString("AINPCWeapon", "none")
    end

    -- Friendly toward players by default until provoked or ordered to attack
    if ent.AddEntityRelationship then
        for _, p in ipairs(player.GetAll()) do
            if IsValid(p) then pcall(ent.AddEntityRelationship, ent, p, D_LI, 99) end
        end
    end

    local displayName = AINPCS.Trim(data.name or data.characterName or "")
    if displayName == "" then displayName = AINPCS.Trim(data.libraryName or "") end
    if displayName == "" then
        local n = 0
        for _, other in pairs(NPCs) do
            if IsValid(other.ent) then n = n + 1 end
        end
        displayName = "NPC " .. (n + 1)
    end

    -- Keep the engine name in sync too. Anything that reads Entity:GetName()
    -- (other addons, admin tools, engine messages) then shows the character's
    -- name rather than the spawn class.
    ent:SetName(displayName)

    local modelId = AINPCS.Trim(data.model or "")
    if modelId == "" then
        local order = provider.modelOrder or {}
        modelId = provider.defaultModel or order[1] or ""
    end

    local voiceId = Voices.NormaliseId(data.voiceId or data.ttsVoice or Voices.Default)
    if not Voices.Get(voiceId) then voiceId = Voices.Default end

    local personality = AINPCS.Trim(data.personality or "")
    if personality == "" then
        personality = "a lively character matching your name and appearance"
    end

    ent:SetNWBool("IsAINPC", true)
    ent:SetNWString("AINPCName", displayName)
    ent:SetNWString("AINPCDescription", personality)
    ent:SetNWString("AINPCVoice", voiceId)
    ent:SetNWString("AINPCWeaponChoice", weaponChoice)
    ent:SetNWString("AINPCBodyModel", ent:GetModel() or "")
    ent:SetNWString("AINPCOwnerName", ply:Nick())
    ent:SetNWBool("AINPCThinking", false)
    ent:SetNWString("AINPCMood", "neutral")
    ent:SetNWString("AINPCActivity", "idle")
    ent:SetNWFloat("AINPCSpeakingUntil", 0)

    local rec = {
        ent            = ent,
        npcClass       = data.class,
        npcData        = npcData,
        owner          = ply,
        ownerKey       = key,
        provider       = provider.id,
        apiKey         = data.apiKey or "",
        fishKey        = AINPCS.Trim(data.fishKey or ""),
        hostname       = data.hostname or "",
        model          = modelId,
        max_tokens     = tonumber(data.max_tokens) or 2048,
        temperature    = tonumber(data.temperature),
        reasoning      = data.reasoning or "none",
        enableTTS      = CV_ALLOWED_TTS:GetBool() and (data.enableTTS ~= false),
        voiceId        = voiceId,
        weaponChoice   = weaponChoice,
        name           = displayName,
        personality    = personality,
        mood           = "neutral",
        activityLabel  = "idle",
        goal           = { type = "idle" },
        transcript     = {},
        events         = {},
        people         = {},
        notes          = {},
        recentLines    = {},
        convoPartners  = {},
        attackers      = {},
        thinking       = false,
        nextReactTime  = 0,
    }

    getPersonRecord(rec, ply)
    NPCs[ent:EntIndex()] = rec
    NextSpawn[key] = now + CV_COOLDOWN:GetFloat()

    net.Start("AINPC_SpawnResult")
    net.WriteBool(true)
    net.WriteEntity(ent)
    net.WriteString(displayName)
    net.Send(ply)

    sendToast(ply, displayName .. " spawned. Walk up and press E to talk.", "success")
    AINPCS.DebugPrint("[AI-NPCs] " .. ply:Nick() .. " spawned " .. displayName .. " (" .. entClass .. ") via " .. provider.id)
end

-- =============================================================================
-- Suppress Default Half-Life 2 NPC Voice Chatter
-- =============================================================================

hook.Add("EntityEmitSound", "AINPC_MuteNativeVoice", function(data)
    if not CV_MUTE_HL2:GetBool() then return end
    local ent = data.Entity
    if not IsValid(ent) or not ent:GetNWBool("IsAINPC", false) then return end

    local snd  = string.lower(data.SoundName or "")
    local orig = string.lower(data.OriginalSoundName or "")
    local ch   = data.Channel

    if ch == CHAN_VOICE or ch == CHAN_VOICE2
        or string.find(snd, "^vo/")
        or string.find(snd, "/vo/")
        or string.find(snd, "^sentences/")
        or string.find(orig, "sentence")
        or string.find(orig, "^npc_citizen%.")
        or string.find(orig, "^npc_barney%.")
        or string.find(orig, "^npc_alyx%.")
        or string.find(orig, "^npc_kleiner%.")
        or string.find(orig, "^npc_combine_s%.")
        or string.find(orig, "^npc_metropolice%.") then
        return false
    end
end)

-- =============================================================================
-- Server-side Facial Flex & Mouth Animation + Behavior Engine
-- =============================================================================

local function getFlexId(ent, name)
    ent._ainpcFlexCache = ent._ainpcFlexCache or {}
    local mdl = ent:GetModel() or ""
    if ent._ainpcFlexModel ~= mdl then
        ent._ainpcFlexCache = {}
        ent._ainpcFlexModel = mdl
    end
    local cached = ent._ainpcFlexCache[name]
    if cached == nil then
        cached = (ent.GetFlexIDByName and ent:GetFlexIDByName(name)) or false
        ent._ainpcFlexCache[name] = cached
    end
    return cached or nil
end

-- Drive facial expressions and procedural mouth movement on the server entity
-- so Source's CAI_BaseNPC networked flex state animates in sync with speech,
-- and stop any native HL2 sentences that would fight the mouth flexes.
hook.Add("Think", "AINPC_FaceAndSentenceThink", function()
    local now = CurTime()
    local ft  = FrameTime()

    for _, rec in pairs(NPCs) do
        local ent = rec.ent
        if IsValid(ent) then
            if CV_MUTE_HL2:GetBool() and ent.SentenceStop then
                pcall(ent.SentenceStop, ent)
            end

            if rec.moodUntil and now > rec.moodUntil and rec.mood ~= "neutral" then
                setMood(rec, "neutral")
            end

            if ent.GetFlexNum and ent:GetFlexNum() > 0 then
                rec.faceWeights = rec.faceWeights or {}
                local face = rec.faceWeights
                local targetExpr = AINPCS.Expressions[rec.mood or "neutral"] or {}

                for name, w in pairs(face) do
                    if not targetExpr[name] then
                        face[name] = math.Approach(w, 0, ft * 2.5)
                        if face[name] <= 0.001 then
                            local fid = getFlexId(ent, name)
                            if fid then ent:SetFlexWeight(fid, 0) end
                            face[name] = nil
                        end
                    end
                end
                for name, targetW in pairs(targetExpr) do
                    face[name] = math.Approach(face[name] or 0, targetW, ft * 2.5)
                end

                local speaking = (ent:GetNWFloat("AINPCSpeakingUntil", 0) > now)
                local jaw = 0
                if speaking then
                    local t = now * 12 + ent:EntIndex()
                    jaw = math.Clamp(math.abs(math.sin(t)) * 0.55 + math.abs(math.sin(t * 1.73)) * 0.30, 0, 1)
                end

                for name, w in pairs(face) do
                    local fid = getFlexId(ent, name)
                    if fid then
                        if name == "jaw_drop" then w = math.max(w, jaw) end
                        ent:SetFlexWeight(fid, w)
                    end
                end

                if speaking or rec.wasSpeaking then
                    for _, mf in ipairs(AINPCS.MouthFlexes) do
                        local fid = getFlexId(ent, mf.name)
                        if fid then
                            local baseW = face[mf.name] or 0
                            ent:SetFlexWeight(fid, math.max(baseW, jaw * mf.scale))
                        end
                    end
                    rec.wasSpeaking = speaking
                end
            end
        end
    end
end)

-- NPC Behavior Engine (runs every 0.5s: follow, come, wander, attack, flee)
timer.Create("AINPC_BehaviorEngine", 0.5, 0, function()
    if not CV_ENABLED:GetBool() then return end
    local now = CurTime()

    for _, rec in pairs(NPCs) do
        local ent = rec.ent
        if IsValid(ent) and ent:Health() > 0 then
            local goal = rec.goal or { type = "idle" }

            if goal.type == "attack" then
                local target = goal.target
                if not IsValid(target) or target:Health() <= 0 or (target:IsPlayer() and not target:Alive()) then
                    rec.goal = { type = "idle" }
                    setActivityLabel(rec, "idle")
                else
                    setActivityLabel(rec, "fighting " .. speakerName(target))
                    if ent.AddEntityRelationship then
                        pcall(ent.AddEntityRelationship, ent, target, D_HT, 99)
                    end
                    if ent.SetEnemy then pcall(ent.SetEnemy, ent, target) end
                    if ent.UpdateEnemyMemory then
                        pcall(ent.UpdateEnemyMemory, ent, target, target:GetPos())
                    end
                    local curEnemy = ent.GetEnemy and ent:GetEnemy()
                    if not IsValid(curEnemy) and ent.SetSchedule then
                        local d = ent:GetPos():Distance(target:GetPos())
                        if d > 220 then
                            if ent.SetLastPosition then pcall(ent.SetLastPosition, ent, target:GetPos()) end
                            pcall(ent.SetSchedule, ent, SCHED_TARGET_CHASE)
                        else
                            pcall(ent.SetSchedule, ent, SCHED_RANGE_ATTACK1)
                        end
                    end
                end

            elseif goal.type == "follow" then
                local target = goal.target
                if not IsValid(target) or (target:IsPlayer() and not target:Alive()) then
                    rec.goal = { type = "idle" }
                    setActivityLabel(rec, "idle")
                else
                    setActivityLabel(rec, "following " .. speakerName(target))
                    local curEnemy = ent.GetEnemy and ent:GetEnemy()
                    if not IsValid(curEnemy) then
                        local dist = ent:GetPos():Distance(target:GetPos())
                        if dist > 2200 and not target:TestPVS(ent) then
                            -- Teleport to catch up if left far behind out of sight
                            local behind = target:GetPos() - target:GetForward() * 90 + Vector(0, 0, 8)
                            if bit.band(util.PointContents(behind), CONTENTS_SOLID) == 0 then
                                ent:SetPos(behind)
                            end
                        elseif dist > 165 then
                            local dir = (ent:GetPos() - target:GetPos()):GetNormalized()
                            local dest = target:GetPos() + dir * 95
                            if ent.SetLastPosition then pcall(ent.SetLastPosition, ent, dest) end
                            if ent.SetSchedule then
                                pcall(ent.SetSchedule, ent, dist > 300 and SCHED_FORCED_GO_RUN or SCHED_FORCED_GO)
                            end
                        end
                    end
                end

            elseif goal.type == "come" then
                local target = goal.target
                if not IsValid(target) then
                    rec.goal = { type = "idle" }
                    setActivityLabel(rec, "idle")
                else
                    local dist = ent:GetPos():Distance(target:GetPos())
                    if dist <= 125 then
                        rec.goal = { type = "idle" }
                        setActivityLabel(rec, "idle")
                        if ent.SetSchedule then pcall(ent.SetSchedule, ent, SCHED_IDLE_STAND) end
                    else
                        setActivityLabel(rec, "walking to " .. speakerName(target))
                        local dir = (ent:GetPos() - target:GetPos()):GetNormalized()
                        local dest = target:GetPos() + dir * 85
                        if ent.SetLastPosition then pcall(ent.SetLastPosition, ent, dest) end
                        if ent.SetSchedule then
                            pcall(ent.SetSchedule, ent, dist > 260 and SCHED_FORCED_GO_RUN or SCHED_FORCED_GO)
                        end
                    end
                end

            elseif goal.type == "flee" then
                if now > (goal.untilTime or 0) then
                    rec.goal = { type = "idle" }
                    setActivityLabel(rec, "idle")
                else
                    setActivityLabel(rec, "fleeing")
                    local fromPos = IsValid(goal.from) and goal.from:GetPos() or goal.fromPos
                    if fromPos and ent.SetLastPosition and ent.SetSchedule then
                        local awayDir = (ent:GetPos() - fromPos):GetNormalized()
                        if awayDir:LengthSqr() < 0.01 then awayDir = VectorRand() awayDir.z = 0 awayDir:Normalize() end
                        local dest = ent:GetPos() + awayDir * 500
                        pcall(ent.SetLastPosition, ent, dest)
                        pcall(ent.SetSchedule, ent, SCHED_FORCED_GO_RUN)
                    elseif ent.SetSchedule then
                        pcall(ent.SetSchedule, ent, SCHED_RUN_FROM_ENEMY)
                    end
                end

            elseif goal.type == "wander" then
                setActivityLabel(rec, "wandering")
                if now >= (goal.nextStep or 0) then
                    goal.nextStep = now + math.Rand(5, 10)
                    if ent.SetSchedule then
                        pcall(ent.SetSchedule, ent, SCHED_PATROL_WALK)
                    end
                end

            elseif goal.type == "stay" then
                setActivityLabel(rec, "waiting here")
            else
                local curEnemy = ent.GetEnemy and ent:GetEnemy()
                if IsValid(curEnemy) then
                    setActivityLabel(rec, "fighting " .. describeEntity(curEnemy))
                else
                    setActivityLabel(rec, "idle")
                end
            end
        end
    end
end)

-- =============================================================================
-- Situational Awareness & Prompt Builder
-- =============================================================================

local function relativeDirection(ent, targetPos)
    local yaw = math.NormalizeAngle(ent:WorldToLocalAngles((targetPos - ent:GetPos()):Angle()).y)
    if math.abs(yaw) <= 35 then return "in front of you" end
    if math.abs(yaw) >= 145 then return "behind you" end
    return yaw > 0 and "to your left" or "to your right"
end

local function describeSelfState(rec)
    local ent = rec.ent
    local hp = ent:Health()
    local maxHp = math.max(ent:GetMaxHealth(), hp, 1)
    local parts = { string.format("health %d/%d HP", hp, maxHp) }

    if hp <= maxHp * 0.35 then
        table.insert(parts, "badly wounded")
    elseif hp < maxHp * 0.75 then
        table.insert(parts, "injured")
    end

    if ent:IsOnFire() then
        table.insert(parts, "ON FIRE (burning!)")
    end
    if ent:WaterLevel() >= 2 then
        table.insert(parts, "in deep water")
    end

    local isMoving = (ent.IsMoving and ent:IsMoving()) or (ent:GetVelocity():Length2D() > 25)
    local curEnemy = ent.GetEnemy and ent:GetEnemy()
    if IsValid(curEnemy) then
        table.insert(parts, "in combat against " .. describeEntity(curEnemy))
    elseif rec.activityLabel and rec.activityLabel ~= "idle" then
        table.insert(parts, rec.activityLabel .. (isMoving and " (moving)" or ""))
    elseif isMoving then
        table.insert(parts, "moving")
    else
        table.insert(parts, "standing idle")
    end

    local wep = ent.GetActiveWeapon and ent:GetActiveWeapon()
    local wepDesc = AINPCS.DescribeWeapon(wep)
    if wepDesc then
        table.insert(parts, "holding " .. wepDesc)
    else
        table.insert(parts, "unarmed")
    end

    table.insert(parts, "mood: " .. (rec.mood or "neutral"))
    return table.concat(parts, ", ")
end

local function perceiveWorld(rec)
    local ent = rec.ent
    local myPos = ent:GetPos()
    local eyePos = ent.EyePos and ent:EyePos() or (myPos + Vector(0, 0, 60))
    local out = { players = {}, aiNPCs = {}, creatures = {} }

    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) then
            local d = myPos:Distance(ply:GetPos())
            if d <= 1600 then
                table.insert(out.players, { ent = ply, dist = d })
            end
        end
    end
    table.sort(out.players, function(a, b) return a.dist < b.dist end)

    for _, otherRec in pairs(NPCs) do
        if otherRec ~= rec and IsValid(otherRec.ent) and otherRec.ent:Health() > 0 then
            local d = myPos:Distance(otherRec.ent:GetPos())
            if d <= 1400 then
                table.insert(out.aiNPCs, { rec = otherRec, ent = otherRec.ent, dist = d })
            end
        end
    end
    table.sort(out.aiNPCs, function(a, b) return a.dist < b.dist end)

    for _, e in ipairs(ents.FindInSphere(myPos, 1400)) do
        if IsValid(e) and e ~= ent and (e:IsNPC() or e:IsNextBot()) and not e:GetNWBool("IsAINPC", false) and e:Health() > 0 then
            local d = myPos:Distance(e:GetPos())
            local cls = e:GetClass() or "npc"
            local disp = (ent.Disposition and ent:Disposition(e)) or (HOSTILE_CLASSES[cls] and D_HT or D_NU)
            local hostile = (disp == D_HT or disp == D_FR or HOSTILE_CLASSES[cls] == true)
            table.insert(out.creatures, {
                ent     = e,
                id      = "n" .. e:EntIndex(),
                name    = NPC_FRIENDLY_NAMES[cls] or string.gsub(cls, "^npc_", ""),
                dist    = d,
                hostile = hostile,
                fightingUs = (e.GetEnemy and e:GetEnemy() == ent) or (ent.GetEnemy and ent:GetEnemy() == e),
            })
        end
    end
    table.sort(out.creatures, function(a, b)
        if a.fightingUs ~= b.fightingUs then return a.fightingUs end
        if a.hostile ~= b.hostile then return a.hostile end
        return a.dist < b.dist
    end)

    return out, eyePos
end

local function detectVerbalTic(rec)
    local lines = rec.recentLines or {}
    local counts = {}
    for i = math.max(1, #lines - 4), #lines do
        local firstWord = string.match(lines[i] or "", "^%s*([%a']+)")
        if firstWord and #firstWord > 1 then
            local low = string.lower(firstWord)
            counts[low] = (counts[low] or 0) + 1
            if counts[low] >= 2 then
                return (string.gsub(low, "^%l", string.upper))
            end
        end
    end
    return nil
end

local function buildSystemPrompt(rec)
    local L = {}
    local function add(s) L[#L + 1] = s end

    add(string.format(
        "You are roleplaying as %s, a living character inside a Garry's Mod world.",
        rec.name
    ))
    add("Stay 100% in character at all times. Never say you are an AI, an LLM, a language model, or a prompt.")
    add("")
    add("# Your Character & Personality")
    add("- Name: " .. rec.name)
    add("- Character description: " .. rec.personality)
    add("Play this character faithfully, including their tone, attitude, quirks, loyalty, or temper.")
    add("")
    add("# Speaking Style")
    add("- Keep your spoken replies concise and natural (usually 1-3 sentences) unless asked for a longer story.")
    add("- Do NOT put physical actions in *asterisks* inside \"say\"; put physical actions in the \"actions\" array instead.")
    add("- Do NOT prefix your spoken line with your own name.")
    add("- React naturally to what is happening around you (if you are being shot, on fire, fighting enemies, low on health, or surrounded by multiple players).")
    add("")

    if CV_ALLOW_ACTIONS:GetBool() then
        add("# Available Physical Actions")
        add("You can physically act in the game world by including action objects in \"actions\":")
        add("- {\"do\": \"follow\", \"target\": \"<player or NPC name>\"} — follow someone around")
        add("- {\"do\": \"stay\"} — stop following/moving and wait where you are")
        add("- {\"do\": \"come\", \"target\": \"<player or NPC name>\"} — walk right over to someone")
        add("- {\"do\": \"wander\"} — stroll around and explore nearby")
        add("- {\"do\": \"attack\", \"target\": \"<player name, NPC name, or creature id like n12>\"} — fight/attack a target")
        add("- {\"do\": \"stop_attacking\"} — cease fire, forgive, and stop fighting")
        add("- {\"do\": \"flee\"} — run away from danger or someone threatening you")
        add("- {\"do\": \"switch_weapon\", \"weapon\": \"weapon_smg1|weapon_shotgun|weapon_pistol|weapon_ar2|weapon_357|weapon_crowbar|weapon_rpg\"} — draw or switch weapon")
        add("- {\"do\": \"drop_weapon\"} — drop your weapon on the ground")
        add("- {\"do\": \"use\"} — open a nearby door or press a nearby button")
        add("- {\"do\": \"gesture\", \"name\": \"wave|nod|shake_head|cheer|laugh|cower\"}")
        add("Only include actions when you genuinely decide to do something right now; otherwise use \"actions\": [].")
        add("")
    end

    add("# Memory & Feelings")
    add("- \"remember\": up to 2 short lasting facts worth remembering about a player or event (under 18 words each, first person), or [].")
    add("- \"opinion\": how this interaction changed your feelings toward players, e.g. {\"PlayerName\": 3} or {\"PlayerName\": -8} (-10 to +10), or {}.")
    add("- \"emotion\": your current facial expression: \"neutral\", \"happy\", \"excited\", \"sad\", \"angry\", \"annoyed\", \"scared\", \"surprised\", \"curious\", or \"embarrassed\".")
    add("")
    add("# Output Format")
    add("Reply with ONLY a single valid JSON object in this exact shape:")
    add("{\"thought\": \"short internal thought\", \"say\": \"what you say out loud\", \"actions\": [], \"emotion\": \"neutral\", \"remember\": [], \"opinion\": {}}")

    return table.concat(L, "\n")
end

local function buildSituationContext(rec, speaker, utterance, eventReason)
    local now = CurTime()
    local world, eyePos = perceiveWorld(rec)
    local L = {}
    local function add(s) L[#L + 1] = s end

    add("# Live Situation Report")
    add("Map: " .. game.GetMap())
    add("Your status: " .. describeSelfState(rec))
    add("")

    add("# People Nearby")
    if #world.players == 0 and #world.aiNPCs == 0 then
        add("Nobody is near you right now.")
    else
        for _, info in ipairs(world.players) do
            local ply = info.ent
            local pName = speakerName(ply)
            local bits = {
                tostring(meters(info.dist)) .. "m away",
                relativeDirection(rec.ent, ply:GetPos()),
            }
            if not ply:Alive() then
                table.insert(bits, "DEAD")
            else
                local hpPct = math.Round((ply:Health() / math.max(ply:GetMaxHealth(), 100)) * 100)
                if hpPct < 100 then table.insert(bits, "health " .. hpPct .. "%") end

                local dirToUs = (eyePos - ply:EyePos()):GetNormalized()
                local dot = ply:GetAimVector():Dot(dirToUs)
                if dot > 0.95 then table.insert(bits, "looking at you") end

                local wep = ply:GetActiveWeapon()
                local wepName = AINPCS.DescribeWeapon(wep)
                if wepName then
                    local cls = IsValid(wep) and wep:GetClass() or ""
                    local isTool = (cls == "weapon_physgun" or cls == "gmod_tool" or cls == "gmod_camera")
                    if dot > 0.96 and not isTool then
                        table.insert(bits, "aiming " .. wepName .. " at you")
                    else
                        table.insert(bits, "holding " .. wepName)
                    end
                end

                if ply:InVehicle() then table.insert(bits, "in a vehicle")
                elseif ply:GetMoveType() == MOVETYPE_NOCLIP then table.insert(bits, "flying (noclip)")
                elseif ply:Crouching() then table.insert(bits, "crouching")
                elseif ply:GetVelocity():Length2D() > 220 then table.insert(bits, "running") end
            end

            local atkTime = rec.attackers and rec.attackers[plyKey(ply)]
            if atkTime and (now - atkTime) < 30 then
                table.insert(bits, "attacked you " .. timeAgo(now - atkTime))
            end

            local pMem = getPersonRecord(rec, ply)
            local relStr = pMem and string.format("relationship: %s (%+d)", affinityLabel(pMem.affinity), math.Round(pMem.affinity)) or ""
            if relStr ~= "" then table.insert(bits, relStr) end

            add("- " .. pName .. " (player): " .. table.concat(bits, ", "))
            if pMem and #pMem.facts > 0 then
                add("    Remembered facts about " .. pName .. ": " .. table.concat(pMem.facts, "; "))
            end
        end

        for _, info in ipairs(world.aiNPCs) do
            local oRec = info.rec
            add(string.format("- %s (fellow AI NPC): %sm away, %s, %s",
                oRec.name, tostring(meters(info.dist)), relativeDirection(rec.ent, info.ent:GetPos()), oRec.activityLabel or "idle"))
        end
    end
    add("")

    if #world.creatures > 0 then
        add("# Nearby Creatures / NPCs")
        for i = 1, math.min(#world.creatures, 8) do
            local c = world.creatures[i]
            local tag = c.fightingUs and "FIGHTING YOU" or (c.hostile and "hostile" or "neutral/friendly")
            add(string.format("- %s: %s (%s, %sm away, %s)",
                c.id, c.name, tag, tostring(meters(c.dist)), relativeDirection(rec.ent, c.ent:GetPos())))
        end
        add("")
    end

    if rec.notes and #rec.notes > 0 then
        add("# Your Notes & Memories")
        for i = math.max(1, #rec.notes - 8), #rec.notes do
            add("- " .. rec.notes[i])
        end
        add("")
    end

    local recentEvents = {}
    for _, ev in ipairs(rec.events or {}) do
        if now - ev.t < 240 then table.insert(recentEvents, ev) end
    end
    if #recentEvents > 0 then
        add("# Recent World Events")
        for i = math.max(1, #recentEvents - 7), #recentEvents do
            local ev = recentEvents[i]
            add("- [" .. timeAgo(now - ev.t) .. "] " .. ev.text)
        end
        add("")
    end

    add("# Recent Conversation Transcript (oldest first)")
    local trList = rec.transcript or {}
    if #trList == 0 then
        add("(no messages yet)")
    else
        for i = math.max(1, #trList - 16), #trList do
            local entry = trList[i]
            local label = entry.self and ("You (" .. rec.name .. ")") or (entry.who .. (entry.addressed and " (to you)" or ""))
            local newTag = (i == #trList and not entry.self and utterance ~= nil) and " [NEW]" or ""
            add(string.format("[%s] %s: %s%s", timeAgo(now - entry.t), label, entry.text, newTag))
        end
    end
    add("")

    local tic = detectVerbalTic(rec)
    if tic then
        add("(Note: you have started several recent replies with \"" .. tic .. "\". Do NOT start with that word this time.)")
        add("")
    end

    add("# What Just Happened")
    if utterance and IsValid(speaker) then
        local spkName = speakerName(speaker)
        add(string.format("%s is speaking to you right now: %q", spkName, utterance))
        add("Respond in character as " .. rec.name .. " and choose any appropriate actions.")
    elseif eventReason then
        add(eventReason)
        add("React in character as " .. rec.name .. " and choose any appropriate actions (such as attacking back, fleeing, or calling them out).")
    end
    add("Reply with the JSON object now.")

    return table.concat(L, "\n")
end

-- =============================================================================
-- Action Execution on CAI_BaseNPC
-- =============================================================================

local ACTION_ALIASES = {
    follow_me = "follow", go_with = "follow",
    wait = "stay", stop = "stay", stop_following = "stay", hold = "stay", hold_position = "stay", stay_here = "stay", unfollow = "stay",
    come_here = "come", approach = "come", walk_to = "come", move_to = "come", go_to = "come",
    explore = "wander", roam = "wander", patrol = "wander",
    fight = "attack", shoot = "attack", kill = "attack", engage = "attack", attack_target = "attack",
    cease_fire = "stop_attacking", stop_fighting = "stop_attacking", calm_down = "stop_attacking", calm = "stop_attacking", forgive = "stop_attacking",
    run_away = "flee", take_cover = "flee", escape = "flee", retreat = "flee", run = "flee",
    equip = "switch_weapon", draw_weapon = "switch_weapon", equip_weapon = "switch_weapon", change_weapon = "switch_weapon",
    drop = "drop_weapon", disarm = "drop_weapon", holster = "drop_weapon",
    open_door = "use", press_button = "use", open = "use", press = "use", interact = "use",
    emote = "gesture", animation = "gesture",
}

local function resolveTargetEntity(rec, targetStr, defaultSpeaker)
    local ent = rec.ent
    if not isstring(targetStr) or AINPCS.Trim(targetStr) == "" then
        return defaultSpeaker
    end
    local n = string.lower(AINPCS.Trim(targetStr))
    n = string.gsub(n, "^@", "")
    if n == "me" or n == "speaker" or n == "player" or n == "user" or n == "them" or n == "him" or n == "her" then
        return defaultSpeaker
    end

    -- Creature ID like "n23"
    local entIdx = string.match(n, "^n(%d+)$")
    if entIdx then
        local e = Entity(tonumber(entIdx))
        if IsValid(e) then return e end
    end

    -- Exact or partial match on player name
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) then
            local pName = string.lower(speakerName(ply))
            if pName == n or string.find(pName, n, 1, true) then
                return ply
            end
        end
    end

    -- Match on another AI NPC name
    for _, oRec in pairs(NPCs) do
        if oRec ~= rec and IsValid(oRec.ent) then
            local oName = string.lower(oRec.name or "")
            if oName == n or string.find(oName, n, 1, true) then
                return oRec.ent
            end
        end
    end

    -- Match on nearby creature/NPC class or friendly name
    local myPos = ent:GetPos()
    local bestEnt, bestDist = nil, math.huge
    for _, e in ipairs(ents.FindInSphere(myPos, 1600)) do
        if IsValid(e) and e ~= ent and (e:IsNPC() or e:IsNextBot()) and e:Health() > 0 then
            local cls = string.lower(e:GetClass() or "")
            local fName = string.lower(NPC_FRIENDLY_NAMES[cls] or cls)
            if string.find(fName, n, 1, true) or string.find(cls, n, 1, true) then
                local d = myPos:Distance(e:GetPos())
                if d < bestDist then
                    bestEnt, bestDist = e, d
                end
            end
        end
    end

    return bestEnt or defaultSpeaker
end

local function executeAction(rec, actionObj, defaultSpeaker)
    if not CV_ALLOW_ACTIONS:GetBool() then return end
    local ent = rec.ent
    if not IsValid(ent) or ent:Health() <= 0 then return end

    local kind, targetStr, weaponStr, gestureStr
    if isstring(actionObj) then
        kind, targetStr = string.match(actionObj, "^%s*(%S+)%s*(.-)%s*$")
    elseif istable(actionObj) then
        kind       = actionObj["do"] or actionObj.action or actionObj.type or actionObj.command
        targetStr  = actionObj.target or actionObj.who or actionObj.to
        weaponStr  = actionObj.weapon or actionObj.item
        gestureStr = actionObj.name or actionObj.gesture
    end
    if not isstring(kind) or kind == "" then return end

    kind = string.lower(AINPCS.Trim(kind))
    kind = string.gsub(kind, "[%s%-]+", "_")
    kind = ACTION_ALIASES[kind] or kind

    local targetEnt = resolveTargetEntity(rec, targetStr, defaultSpeaker)

    if kind == "follow" then
        if IsValid(targetEnt) and targetEnt ~= ent then
            rec.goal = { type = "follow", target = targetEnt }
            setActivityLabel(rec, "following " .. speakerName(targetEnt))
            addEvent(rec, "You started following " .. speakerName(targetEnt), 1)
        end

    elseif kind == "stay" then
        rec.goal = { type = "stay", pos = ent:GetPos() }
        setActivityLabel(rec, "waiting here")
        if ent.SetSchedule then pcall(ent.SetSchedule, ent, SCHED_IDLE_STAND) end
        addEvent(rec, "You decided to stay put", 1)

    elseif kind == "come" then
        if IsValid(targetEnt) and targetEnt ~= ent then
            rec.goal = { type = "come", target = targetEnt }
            setActivityLabel(rec, "walking to " .. speakerName(targetEnt))
        end

    elseif kind == "wander" then
        rec.goal = { type = "wander", nextStep = 0 }
        setActivityLabel(rec, "wandering")

    elseif kind == "attack" then
        if not IsValid(targetEnt) or targetEnt == ent then return end
        if targetEnt:IsPlayer() and not CV_ALLOW_PVP:GetBool() then
            addEvent(rec, "You wanted to attack " .. speakerName(targetEnt) .. " but PvP is disabled on this server", 1)
            return
        end

        -- If unarmed, equip default/configured weapon or SMG so the NPC can fight effectively
        local activeWep = ent.GetActiveWeapon and ent:GetActiveWeapon()
        if not IsValid(activeWep) then
            local fallbackWep = (rec.weaponChoice and rec.weaponChoice ~= "none") and rec.weaponChoice or "weapon_smg1"
            giveNPCWeapon(ent, fallbackWep, rec.npcData)
        end
        if isstring(weaponStr) and weaponStr ~= "" then
            giveNPCWeapon(ent, weaponStr, rec.npcData)
        end

        rec.goal = { type = "attack", target = targetEnt }
        setActivityLabel(rec, "fighting " .. speakerName(targetEnt))
        if ent.AddEntityRelationship then
            pcall(ent.AddEntityRelationship, ent, targetEnt, D_HT, 99)
        end
        if ent.SetEnemy then pcall(ent.SetEnemy, ent, targetEnt) end
        if ent.UpdateEnemyMemory then
            pcall(ent.UpdateEnemyMemory, ent, targetEnt, targetEnt:GetPos())
        end
        if ent.SetSchedule then
            pcall(ent.SetSchedule, ent, SCHED_TARGET_CHASE)
        end
        addEvent(rec, "You started attacking " .. describeEntity(targetEnt), 2)

    elseif kind == "stop_attacking" then
        rec.goal = { type = "idle" }
        rec.attackers = {}
        setActivityLabel(rec, "idle")
        if ent.SetEnemy then pcall(ent.SetEnemy, ent, NULL) end
        if ent.ClearEnemyMemory then pcall(ent.ClearEnemyMemory, ent) end
        if ent.AddEntityRelationship then
            for _, ply in ipairs(player.GetAll()) do
                if IsValid(ply) then pcall(ent.AddEntityRelationship, ent, ply, D_LI, 99) end
            end
        end
        if ent.SetSchedule then pcall(ent.SetSchedule, ent, SCHED_IDLE_STAND) end
        addEvent(rec, "You stopped fighting and stood down", 1)

    elseif kind == "flee" then
        local fromEnt = IsValid(targetEnt) and targetEnt or (ent.GetEnemy and ent:GetEnemy()) or defaultSpeaker
        rec.goal = {
            type      = "flee",
            from      = fromEnt,
            fromPos   = IsValid(fromEnt) and fromEnt:GetPos() or ent:GetPos(),
            untilTime = CurTime() + 10,
        }
        setActivityLabel(rec, "fleeing")
        if ent.SetSchedule then pcall(ent.SetSchedule, ent, SCHED_RUN_FROM_ENEMY) end
        addEvent(rec, "You started running away from danger", 2)

    elseif kind == "switch_weapon" then
        local w = weaponStr or targetStr
        if isstring(w) and w ~= "" then
            if not string.find(w, "^weapon_") and w ~= "none" and w ~= "default" then
                w = "weapon_" .. string.lower(w)
            end
            giveNPCWeapon(ent, w, rec.npcData)
            rec.weaponChoice = w
            ent:SetNWString("AINPCWeaponChoice", w)
            addEvent(rec, "You switched your weapon to " .. AINPCS.WeaponLabel(w), 1)
        end

    elseif kind == "drop_weapon" then
        local activeWep = ent.GetActiveWeapon and ent:GetActiveWeapon()
        if IsValid(activeWep) then
            local cls = activeWep:GetClass()
            activeWep:Remove()
            ent:SetNWString("AINPCWeapon", "none")
            local dropped = ents.Create(cls)
            if IsValid(dropped) then
                dropped:SetPos(ent:GetPos() + ent:GetForward() * 28 + Vector(0, 0, 32))
                dropped:Spawn()
            end
            addEvent(rec, "You dropped your weapon", 1)
        end

    elseif kind == "use" then
        for _, e in ipairs(ents.FindInSphere(ent:GetPos(), 160)) do
            if IsValid(e) then
                local cls = e:GetClass() or ""
                if string.find(cls, "door") or string.find(cls, "button") then
                    e:Use(ent, ent, USE_TOGGLE, 1)
                    addEvent(rec, "You used a nearby " .. (string.find(cls, "button") and "button" or "door"), 1)
                    break
                end
            end
        end

    elseif kind == "crouch" then
        if ent.SetSchedule then pcall(ent.SetSchedule, ent, SCHED_TAKE_COVER_FROM_ORIGIN) end

    elseif kind == "stand" then
        if ent.SetSchedule then pcall(ent.SetSchedule, ent, SCHED_IDLE_STAND) end

    elseif kind == "gesture" then
        local g = string.lower(tostring(gestureStr or targetStr or "wave"))
        if g == "cower" and ent.SetSchedule then
            pcall(ent.SetSchedule, ent, SCHED_COWER)
        elseif ent.RestartGesture then
            local actMap = {
                wave       = ACT_GMOD_GESTURE_WAVE,
                nod        = ACT_GMOD_GESTURE_AGREE,
                shake_head = ACT_GMOD_GESTURE_DISAGREE,
                cheer      = ACT_GMOD_TAUNT_CHEER,
                laugh      = ACT_GMOD_TAUNT_LAUGH,
            }
            local act = actMap[g]
            if act then pcall(ent.RestartGesture, ent, act) end
        end
    end
end

-- =============================================================================
-- In-Game Fish Audio & Keyless TTS Pipeline
-- =============================================================================

local FishAudioCache = {}
local FishCacheOrder = {}
local NextStreamId   = 0
local STREAM_CHUNK   = 28000

local function rememberFishAudio(cacheKey, audioBytes, ext)
    if FishAudioCache[cacheKey] then return end
    FishAudioCache[cacheKey] = { data = audioBytes, ext = ext }
    table.insert(FishCacheOrder, cacheKey)
    while #FishCacheOrder > 20 do
        local old = table.remove(FishCacheOrder, 1)
        FishAudioCache[old] = nil
    end
end

local function estimateSpeechDuration(text)
    return math.Clamp(#(text or "") / 13.5, 2.2, 10)
end

local function sendStreamedAudio(ent, audioBytes, ext)
    if not IsValid(ent) or not audioBytes or #audioBytes < 128 then return end

    local listeners = {}
    local pos = ent:GetPos()
    for _, ply in ipairs(player.GetHumans()) do
        if IsValid(ply) and ply:GetPos():Distance(pos) <= 1800 then
            table.insert(listeners, ply)
        end
    end
    if #listeners == 0 then return end

    NextStreamId = (NextStreamId + 1) % 60000
    local streamId = NextStreamId
    local total = math.max(1, math.ceil(#audioBytes / STREAM_CHUNK))

    for i = 1, total do
        local part = string.sub(audioBytes, (i - 1) * STREAM_CHUNK + 1, i * STREAM_CHUNK)
        net.Start("AINPC_TTSAudio")
        net.WriteUInt(streamId, 16)
        net.WriteEntity(ent)
        net.WriteString(ext or "mp3")
        net.WriteUInt(i, 8)
        net.WriteUInt(total, 8)
        net.WriteUInt(#part, 16)
        net.WriteData(part, #part)
        net.Send(listeners)
    end
end

local function playTTS(rec, text)
    if not rec.enableTTS or not CV_ALLOWED_TTS:GetBool() then return end
    if not IsValid(rec.ent) then return end

    text = AINPCS.Truncate(AINPCS.CleanText(text or ""), 500)
    if text == "" then return end

    local voiceId = Voices.NormaliseId(rec.voiceId or Voices.Default)
    if not Voices.Get(voiceId) then voiceId = Voices.Default end

    local dur = estimateSpeechDuration(text)

    -- NB: AINPCSpeakingUntil is set when the audio is actually dispatched, not
    -- here. Setting it at request time made the NPC flap its jaw silently for the
    -- second or two Fish Audio spends synthesising.

    -- If this is a Fish Audio character voice and we have a Fish key, synthesize directly
    -- on the server and stream the MP3 to nearby players (no external .bat relay needed!).
    local fishModelId = Voices.FishModelId(voiceId)
    if fishModelId and rec.fishKey and rec.fishKey ~= "" then
        local cacheKey = fishModelId .. "|" .. text
        local cached = FishAudioCache[cacheKey]
        if cached then
            rec.ent:SetNWFloat("AINPCSpeakingUntil", CurTime() + dur)
            sendStreamedAudio(rec.ent, cached.data, cached.ext)
            return
        end

        local npcEnt = rec.ent
        HTTP({
            url = "https://api.fish.audio/v1/tts",
            method = "post",
            type = "application/json",
            headers = {
                ["Authorization"] = "Bearer " .. rec.fishKey,
                ["Content-Type"]  = "application/json",
                ["model"]         = "s2.1-pro-free",
            },
            body = util.TableToJSON({
                text         = text,
                reference_id = fishModelId,
                format       = "mp3",
                sample_rate  = 44100,
                normalize    = true,
                latency      = "normal",
                prosody      = { speed = 1, volume = 0, normalize_loudness = true },
            }),
            success = function(code, body)
                if not IsValid(npcEnt) then return end
                if code == 200 and body and #body >= 256 then
                    local ext = (string.sub(body, 1, 4) == "RIFF") and "wav" or "mp3"
                    rememberFishAudio(cacheKey, body, ext)
                    npcEnt:SetNWFloat("AINPCSpeakingUntil", CurTime() + dur)
                    sendStreamedAudio(npcEnt, body, ext)
                else
                    AINPCS.DebugPrint("[AI-NPCs][FishTTS] HTTP " .. tostring(code) .. " — falling back to client TTS")
                    npcEnt:SetNWFloat("AINPCSpeakingUntil", CurTime() + dur)
                    net.Start("AINPC_TTSPlay")
                    net.WriteEntity(npcEnt)
                    net.WriteString(voiceId)
                    net.WriteString(text)
                    net.Broadcast()
                end
            end,
            failed = function(err)
                AINPCS.DebugPrint("[AI-NPCs][FishTTS] network error: " .. tostring(err))
                if not IsValid(npcEnt) then return end
                npcEnt:SetNWFloat("AINPCSpeakingUntil", CurTime() + dur)
                net.Start("AINPC_TTSPlay")
                net.WriteEntity(npcEnt)
                net.WriteString(voiceId)
                net.WriteString(text)
                net.Broadcast()
            end,
        })
        return
    end

    rec.ent:SetNWFloat("AINPCSpeakingUntil", CurTime() + dur)
    net.Start("AINPC_TTSPlay")
    net.WriteEntity(rec.ent)
    net.WriteString(voiceId)
    net.WriteString(text)
    net.Broadcast()
end

-- =============================================================================
-- Chat Pipeline & Reply Parser
-- =============================================================================

local function sendChatReply(rec, text, isError, asker, speakerLine, expectsAudio)
    local ent = IsValid(rec.ent) and rec.ent or NULL

    local recipients = {}
    local seen = {}
    local function addRecip(p)
        if IsValid(p) and p:IsPlayer() and not seen[p] then
            seen[p] = true
            table.insert(recipients, p)
        end
    end

    addRecip(asker)
    addRecip(rec.owner)
    if IsValid(ent) then
        local pos = ent:GetPos()
        for _, p in ipairs(player.GetHumans()) do
            if p:GetPos():Distance(pos) <= 650 then
                addRecip(p)
            end
        end
    end
    if #recipients == 0 then return end

    net.Start("AINPC_ChatReply")
    net.WriteEntity(ent)
    net.WriteString(rec.name or "NPC")
    net.WriteString(text or "")
    net.WriteBool(isError == true)
    net.WriteString(IsValid(asker) and speakerName(asker) or "")
    net.WriteString(speakerLine or "")
    -- Clients hold the line back until the voice actually starts, so the text
    -- and the speech arrive together instead of the text racing ahead of TTS.
    net.WriteBool(expectsAudio == true)
    net.Send(recipients)
end

local function extractReply(response)
    if not istable(response) then return nil end
    local choices = response.choices
    if istable(choices) and choices[1] and istable(choices[1].message) then
        local content = choices[1].message.content
        if isstring(content) then return content end
        if istable(content) then
            local parts = {}
            for _, p in ipairs(content) do
                if istable(p) and isstring(p.text) then table.insert(parts, p.text) end
            end
            return table.concat(parts, "")
        end
    end
    if istable(response.message) and isstring(response.message.content) then
        return response.message.content
    end
    return nil
end

local function extractError(response)
    if not istable(response) then return nil end
    local err = response.error
    if isstring(err) then return err end
    if istable(err) then
        if isstring(err.message) then return err.message end
        if err.message ~= nil then return tostring(err.message) end
        if err.code ~= nil then return tostring(err.code) end
        return "provider returned error"
    end
    return nil
end

local function scrubKey(rec, text)
    text = tostring(text or "")
    for _, key in ipairs({ rec.apiKey, rec.fishKey }) do
        if key and #key >= 8 then
            text = string.Replace(text, key, AINPCS.RedactKey(key))
        end
    end
    return text
end

-- Learn parameter quirks when a provider returns a 400 error so the immediate retry succeeds
local function learnModelQuirk(rec, errText)
    local qKey = tostring(rec.provider) .. "|" .. tostring(rec.model)
    ModelQuirks[qKey] = ModelQuirks[qKey] or {}
    local q = ModelQuirks[qKey]
    local low = string.lower(errText or "")
    local changed = false

    if string.find(low, "temperature", 1, true) and not q.no_temp then
        q.no_temp = true
        changed = true
    end
    if (string.find(low, "reasoning", 1, true) or string.find(low, "thinking", 1, true)) and not q.no_reasoning then
        q.no_reasoning = true
        changed = true
    end
    if string.find(low, "max_tokens", 1, true) and string.find(low, "max_completion_tokens", 1, true) then
        local cur = q.tokens_field or (rec.provider == "openai" and "max_completion_tokens" or "max_tokens")
        q.tokens_field = (cur == "max_tokens") and "max_completion_tokens" or "max_tokens"
        changed = true
    end
    return changed, q
end

-- Clean spoken text & extract any fallback [ACTION:...] or *gesture* tags
local function cleanSpokenReply(rec, rawSay)
    local text = tostring(rawSay or "")
    local inlineActions = {}

    -- Extract [ACTION:attack] or [ACTION:follow:Player] tags if model used bracket syntax
    text = string.gsub(text, "%[%s*ACTION%s*:%s*([^%]]+)%]", function(inner)
        local act, arg = string.match(inner, "^([^:]+):?(.*)$")
        if act then
            table.insert(inlineActions, {
                ["do"] = AINPCS.Trim(act),
                target = AINPCS.Trim(arg),
            })
        end
        return ""
    end)

    -- Extract *wave* / *nods* asterisk gestures
    text = string.gsub(text, "%*([^%*]+)%*", function(inner)
        local w = string.lower(AINPCS.Trim(inner))
        for _, g in ipairs({ "wave", "nod", "shake_head", "cheer", "laugh", "cower" }) do
            if string.find(w, g, 1, true) then
                table.insert(inlineActions, { ["do"] = "gesture", name = g })
                break
            end
        end
        return ""
    end)

    text = string.gsub(text, "^" .. string.PatternSafe(rec.name or "NPC") .. "%s*:%s*", "")
    text = string.gsub(text, "^[\"']+(.-)[\"']+$", "%1")
    text = AINPCS.CleanText(text, 480)
    return text, inlineActions
end

local function handleModelReply(rec, rawContent, asker, speakerLine)
    local cleaned = AINPCS.CleanModelText(rawContent)
    local parsed  = AINPCS.ParseJSONLoose(cleaned)

    local say      = ""
    local actions  = {}
    local emotion  = nil
    local remember = {}
    local opinion  = {}

    if istable(parsed) then
        say = parsed.say or parsed.reply or parsed.response or parsed.message or parsed.text or ""
        if not isstring(say) then say = "" end
        actions = parsed.actions or parsed.action or {}
        if isstring(actions) then actions = { actions } end
        if istable(actions) and (actions["do"] or actions.action or actions.type) then
            actions = { actions }
        end
        if not istable(actions) then actions = {} end
        if isstring(parsed.emotion) then emotion = string.lower(parsed.emotion) end
        remember = parsed.remember or parsed.memory or {}
        if isstring(remember) then remember = { remember } end
        if not istable(remember) then remember = {} end
        if istable(parsed.opinion) then opinion = parsed.opinion end
    else
        say = cleaned
    end

    local sayText, extraActions = cleanSpokenReply(rec, say)
    for _, a in ipairs(extraActions) do table.insert(actions, a) end

    if emotion and AINPCS.Emotions[emotion] then
        setMood(rec, emotion)
    end

    -- Execute physical actions
    for i = 1, math.min(#actions, 4) do
        executeAction(rec, actions[i], asker)
    end

    -- Save new memories
    for i = 1, math.min(#remember, 3) do
        local item = remember[i]
        local fact = isstring(item) and item or (istable(item) and (item.fact or item.text))
        if isstring(fact) and fact ~= "" then
            addPersonFact(rec, asker, fact)
        end
    end

    -- Update opinions / affinity toward players
    for whoName, delta in pairs(opinion) do
        local num = tonumber(delta)
        if num and num ~= 0 then
            local targetPly = resolveTargetEntity(rec, tostring(whoName), asker)
            if IsValid(targetPly) and targetPly:IsPlayer() then
                adjustAffinity(rec, targetPly, math.Clamp(num, -15, 15))
            end
        end
    end

    if sayText ~= "" then
        addTranscript(rec, rec.name, sayText, true, false)
        rec.recentLines = rec.recentLines or {}
        table.insert(rec.recentLines, sayText)
        while #rec.recentLines > 6 do table.remove(rec.recentLines, 1) end

        local willSpeak = rec.enableTTS and CV_ALLOWED_TTS:GetBool()
        if willSpeak then
            -- Kick the voice off first so the audio is already in flight by the
            -- time the client decides it is allowed to show the text.
            playTTS(rec, sayText)
        end
        sendChatReply(rec, sayText, false, asker, speakerLine, willSpeak)
    elseif speakerLine and speakerLine ~= "" then
        -- Even if the NPC stayed silent (only did an action), still log the player's line in the UI
        sendChatReply(rec, "*" .. (rec.activityLabel or "nods") .. "*", false, asker, speakerLine, false)
    end
end

local function triggerNPCDeliberation(rec, asker, userText, eventReason)
    if not IsValid(rec.ent) or rec.ent:Health() <= 0 then
        if IsValid(asker) then sendToast(asker, "That NPC is gone.", "error") end
        return
    end

    local provider = providers.get(rec.provider)
    if not provider then
        sendChatReply(rec, "Provider '" .. tostring(rec.provider) .. "' is not available.", true, asker, userText)
        return
    end

    if rec.thinking then
        if IsValid(asker) and userText then
            sendToast(asker, (rec.name or "That NPC") .. " is still thinking — give it a second.", "info")
        end
        return
    end

    if userText and userText ~= "" then
        local who = IsValid(asker) and speakerName(asker) or "Player"
        addTranscript(rec, who, userText, false, true)
        if IsValid(asker) and asker:IsPlayer() then
            local p = getPersonRecord(rec, asker)
            if p then p.lastTalk = CurTime() end
            rec.convoPartners[plyKey(asker)] = CurTime()
        end
    end

    local sysPrompt   = buildSystemPrompt(rec)
    local userContext = buildSituationContext(rec, asker, userText, eventReason)

    rec.messages = {
        { role = "system", content = sysPrompt },
        { role = "user",   content = userContext },
    }
    rec.history = rec.messages

    local qKey = tostring(rec.provider) .. "|" .. tostring(rec.model)
    rec._quirks = ModelQuirks[qKey] or {}

    setThinking(rec, true)

    rec.token = (rec.token or 0) + 1
    local token = rec.token
    local timerName = "AINPC_Timeout_" .. rec.ent:EntIndex()

    local function settle()
        if rec.token ~= token then return false end
        rec.token = token + 1
        timer.Remove(timerName)
        setThinking(rec, false)
        return true
    end

    timer.Create(timerName, AINPCS.Defaults.RequestTimeout, 1, function()
        if not settle() then return end
        AINPCS.DebugPrint("[AI-NPCs] " .. tostring(rec.provider) .. " timed out after " .. AINPCS.Defaults.RequestTimeout .. "s")
        if userText then
            sendChatReply(rec, "(" .. (rec.name or "NPC") .. " didn't answer in time — the provider is slow or unreachable.)", true, asker, userText)
        end
    end)

    local attempt = 0
    local function doRequest()
        attempt = attempt + 1
        local function onResponse(err, response)
            if rec.token ~= token then return end

            if err then
                if not settle() then return end
                err = scrubKey(rec, err)
                AINPCS.DebugPrint("[AI-NPCs] " .. rec.provider .. " error: " .. err)
                if userText then
                    sendChatReply(rec, "(" .. rec.name .. " can't respond right now: " .. err .. ")", true, asker, userText)
                end
                return
            end

            local content = extractReply(response)
            if not content or AINPCS.Trim(AINPCS.CleanModelText(content)) == "" then
                local rawErr = extractError(response) or "empty response"
                -- Auto-learn parameter quirks and retry once if the provider rejected a field
                if attempt == 1 then
                    local learned, newQuirks = learnModelQuirk(rec, rawErr)
                    if learned then
                        rec._quirks = newQuirks
                        AINPCS.DebugPrint("[AI-NPCs] Learned model quirk for " .. qKey .. ", retrying...")
                        doRequest()
                        return
                    elseif content and content ~= "" then
                        -- Model spent all tokens inside <think>: retry once with reasoning off and 2x tokens
                        rec._quirks = table.Copy(rec._quirks or {})
                        rec._quirks.no_reasoning = true
                        rec.max_tokens = math.min((rec.max_tokens or 2048) * 2, 8192)
                        doRequest()
                        return
                    end
                end

                if not settle() then return end
                local errMsg = scrubKey(rec, rawErr)
                AINPCS.DebugPrint("[AI-NPCs] bad response from " .. rec.provider .. ": " .. errMsg)
                if userText then
                    sendChatReply(rec, "(" .. rec.name .. " seems confused: " .. errMsg .. ")", true, asker, userText)
                end
                return
            end

            if not settle() then return end
            handleModelReply(rec, content, asker, userText)
        end

        local ok, requestErr = pcall(provider.request, rec, onResponse)
        if not ok and settle() then
            if userText then
                sendChatReply(rec, "(" .. (rec.name or "NPC") .. " hit an internal error: " .. scrubKey(rec, tostring(requestErr)) .. ")", true, asker, userText)
            end
        end
    end

    doRequest()
end

-- =============================================================================
-- World Event Hooks (Damage, Kills, Gunfire)
-- =============================================================================

hook.Add("EntityTakeDamage", "AINPC_DamageAwareness", function(target, dmg)
    if not CV_ENABLED:GetBool() or not IsValid(target) then return end
    local now = CurTime()
    local attacker = dmg:GetAttacker()
    local inflictor = dmg:GetInflictor()
    local amount = math.Round(dmg:GetDamage() or 0)
    if amount <= 0 then return end

    -- Case 1: An AI NPC took damage!
    local rec = NPCs[target:EntIndex()]
    if rec and IsValid(rec.ent) then
        local wepDesc = nil
        if IsValid(attacker) and (attacker:IsPlayer() or attacker:IsNPC()) and attacker.GetActiveWeapon then
            wepDesc = AINPCS.DescribeWeapon(attacker:GetActiveWeapon())
        elseif IsValid(inflictor) and inflictor ~= attacker then
            wepDesc = AINPCS.DescribeWeapon(inflictor)
        end

        local atkName = IsValid(attacker) and describeEntity(attacker) or "something"
        local msg
        if dmg:IsDamageType(DMG_BURN) or target:IsOnFire() then
            msg = string.format("You are burning / taking fire damage (%d HP lost)!", amount)
        elseif IsValid(attacker) and attacker ~= target then
            msg = string.format("%s attacked you%s for %d damage!",
                atkName, wepDesc and (" with " .. wepDesc) or "", amount)
        else
            msg = string.format("You took %d damage.", amount)
        end

        addEvent(rec, msg, 3)

        if IsValid(attacker) and attacker:IsPlayer() then
            rec.attackers[plyKey(attacker)] = now
            adjustAffinity(rec, attacker, amount >= 20 and -8 or -4)
        end

        -- Reactive in-character response when attacked (throttled per NPC)
        if CV_REACTIVE:GetBool() and not rec.thinking and now >= (rec.nextReactTime or 0) and (target:Health() - amount) > 0 then
            rec.nextReactTime = now + 10
            local reactSpeaker = (IsValid(attacker) and attacker:IsPlayer()) and attacker or rec.owner
            timer.Simple(0.15, function()
                if IsValid(rec.ent) and rec.ent:Health() > 0 and not rec.thinking then
                    triggerNPCDeliberation(rec, reactSpeaker, nil, msg)
                end
            end)
        end
        return
    end

    -- Case 2: A player or NPC near an AI NPC was attacked
    if (target:IsPlayer() or target:IsNPC()) and IsValid(attacker) and attacker ~= target then
        local tPos = target:GetPos()
        for _, oRec in pairs(NPCs) do
            if IsValid(oRec.ent) and oRec.ent ~= attacker and oRec.ent:GetPos():Distance(tPos) <= 900 then
                if now >= (oRec.nextWitnessHurt or 0) then
                    oRec.nextWitnessHurt = now + 5
                    addEvent(oRec, string.format("%s attacked %s nearby.", describeEntity(attacker), describeEntity(target)), 2)
                end
            end
        end
    end
end)

hook.Add("OnNPCKilled", "AINPC_KillAwareness", function(npc, attacker, inflictor)
    if not IsValid(npc) then return end
    local deadIdx = npc:EntIndex()

    if NPCs[deadIdx] then
        cleanupNPC(deadIdx)
        return
    end

    local pos = npc:GetPos()
    local victimDesc = describeEntity(npc)
    local killerDesc = IsValid(attacker) and describeEntity(attacker) or "something"

    for _, rec in pairs(NPCs) do
        if IsValid(rec.ent) then
            if attacker == rec.ent then
                addEvent(rec, "You killed " .. victimDesc .. "!", 2)
                if rec.goal and rec.goal.type == "attack" and rec.goal.target == npc then
                    rec.goal = { type = "idle" }
                    setActivityLabel(rec, "idle")
                end
            elseif rec.ent:GetPos():Distance(pos) <= 1200 then
                addEvent(rec, killerDesc .. " killed " .. victimDesc .. " nearby.", 1)
            end
        end
    end
end)

hook.Add("PlayerDeath", "AINPC_PlayerDeathAwareness", function(victim, inflictor, attacker)
    if not IsValid(victim) then return end
    local pos = victim:GetPos()
    local vName = speakerName(victim)
    local killerDesc = (IsValid(attacker) and attacker ~= victim) and describeEntity(attacker) or nil

    for _, rec in pairs(NPCs) do
        if IsValid(rec.ent) and rec.ent:GetPos():Distance(pos) <= 1400 then
            if attacker == rec.ent then
                addEvent(rec, "You killed " .. vName .. "!", 3)
                if rec.goal and rec.goal.type == "attack" and rec.goal.target == victim then
                    rec.goal = { type = "idle" }
                    setActivityLabel(rec, "idle")
                end
            else
                addEvent(rec, killerDesc and (vName .. " was killed by " .. killerDesc .. " nearby.") or (vName .. " died nearby."), 2)
            end
        end
    end
end)

hook.Add("EntityFireBullets", "AINPC_GunfireAwareness", function(shooter, bulletData)
    if not IsValid(shooter) then return end
    local now = CurTime()
    local pos = shooter:GetPos()
    for _, rec in pairs(NPCs) do
        if IsValid(rec.ent) and rec.ent ~= shooter and now >= (rec.nextGunfireEvent or 0) then
            local d = rec.ent:GetPos():Distance(pos)
            if d <= 1200 then
                rec.nextGunfireEvent = now + 12
                addEvent(rec, "You hear gunshots nearby (" .. describeEntity(shooter) .. " is shooting).", 1)
            end
        end
    end
end)

-- =============================================================================
-- Smart Proximity & Addressed NPC Lookup
-- =============================================================================

local function findBestNPCForSpeech(ply, text, maxRange)
    maxRange = maxRange or CV_PROXIMITY_R:GetFloat()
    local eye = ply:EyePos()
    local aim = ply:GetAimVector()
    local key = plyKey(ply)
    local lowText = " " .. string.lower(text or "") .. " "

    local candidates = {}
    for _, rec in pairs(NPCs) do
        if IsValid(rec.ent) and rec.ent:Health() > 0 then
            local d = rec.ent:GetPos():Distance(eye)
            if d <= maxRange then
                table.insert(candidates, { rec = rec, dist = d })
            end
        end
    end
    if #candidates == 0 then return nil end

    -- 1. Mentioned by name
    for _, c in ipairs(candidates) do
        local nameLow = string.lower(c.rec.name or "")
        if nameLow ~= "" and string.find(lowText, "[^%w]" .. string.PatternSafe(nameLow) .. "[^%w]") then
            return c.rec
        end
    end

    -- 2. Player is looking directly at the NPC
    local bestLook, bestDot = nil, 0.90
    for _, c in ipairs(candidates) do
        local headPos = c.rec.ent:GetPos() + Vector(0, 0, 60)
        local dot = aim:Dot((headPos - eye):GetNormalized())
        if dot > bestDot then
            bestLook, bestDot = c.rec, dot
        end
    end
    if bestLook then return bestLook end

    -- 3. Active conversation partner within last 45s
    local bestPartner, bestTime = nil, 0
    for _, c in ipairs(candidates) do
        local t = c.rec.convoPartners and c.rec.convoPartners[key]
        if t and (CurTime() - t) < 45 and t > bestTime then
            bestPartner, bestTime = c.rec, t
        end
    end
    if bestPartner then return bestPartner end

    -- 4. Nearest owned or nearest overall
    table.sort(candidates, function(a, b)
        local aOwn = (a.rec.ownerKey == key)
        local bOwn = (b.rec.ownerKey == key)
        if aOwn ~= bOwn then return aOwn end
        return a.dist < b.dist
    end)
    return candidates[1].rec
end

-- =============================================================================
-- Net Receivers
-- =============================================================================

net.Receive("AINPC_SpawnRequest", function(len, ply)
    if not IsValid(ply) then return end
    local ok, data = pcall(net.ReadTable)
    if not ok or not istable(data) then
        sendToast(ply, "Malformed spawn request.", "error")
        return
    end
    spawnAINPC(ply, data)
end)

net.Receive("AINPC_ModelPreview", function(len, ply)
    if not IsValid(ply) then return end

    local previewKey = plyKey(ply)
    local now = CurTime()
    if (NextPreview[previewKey] or 0) > now then return end
    NextPreview[previewKey] = now + 0.5

    local class = net.ReadString()
    local data = lookupNPCData(class)
    local model = (data and data.Model) or ""

    if model == "" and data and data.Class then
        local temp = ents.Create(data.Class)
        if IsValid(temp) then
            temp:Spawn()
            model = temp:GetModel() or ""
            temp:Remove()
        end
    end

    net.Start("AINPC_ModelPreviewResponse")
    net.WriteString(model)
    net.Send(ply)
end)

net.Receive("AINPC_ChatRequest", function(len, ply)
    if not IsValid(ply) then return end

    local targetEnt = net.ReadEntity()
    local msg       = AINPCS.Trim(net.ReadString() or "")

    if msg == "" then return end
    if #msg > 500 then msg = string.sub(msg, 1, 500) end

    if not chatAllowed(ply) then return end

    local rec
    if IsValid(targetEnt) and NPCs[targetEnt:EntIndex()] then
        rec = NPCs[targetEnt:EntIndex()]
    else
        rec = findBestNPCForSpeech(ply, msg, CV_INTERACT_R:GetFloat() * 2)
    end

    if not rec then
        sendToast(ply, "No AI NPC nearby. Spawn one from the C menu → AI NPCs.", "error")
        return
    end

    triggerNPCDeliberation(rec, ply, msg, nil)
end)

-- Live NPC update / quick action receiver (Edit live NPC, Follow, Stay, Calm, Clear Memory, Despawn)
net.Receive("AINPC_UpdateNPC", function(len, ply)
    if not IsValid(ply) then return end
    local ent = net.ReadEntity()
    local ok, data = pcall(net.ReadTable)
    if not ok or not istable(data) or not IsValid(ent) then return end

    local rec = NPCs[ent:EntIndex()]
    if not rec then
        sendToast(ply, "That AI NPC no longer exists.", "error")
        return
    end

    local isOwnerOrAdmin = (rec.ownerKey == plyKey(ply)) or ply:IsAdmin()
    local op = tostring(data.op or "")

    if op == "action" then
        local act = tostring(data.action or "")
        executeAction(rec, { ["do"] = act, target = speakerName(ply) }, ply)
        sendToast(ply, rec.name .. ": " .. (rec.activityLabel or act), "info")
        return
    end

    if not isOwnerOrAdmin then
        sendToast(ply, "Only the NPC's owner or an admin can modify this NPC.", "error")
        return
    end

    if op == "clear_memory" then
        rec.transcript    = {}
        rec.events        = {}
        rec.people        = {}
        rec.notes         = {}
        rec.recentLines   = {}
        rec.convoPartners = {}
        rec.attackers     = {}
        setMood(rec, "neutral")
        sendToast(ply, "Cleared " .. rec.name .. "'s conversation memory.", "success")
        return
    elseif op == "despawn" then
        local name = rec.name
        ent:Remove()
        sendToast(ply, name .. " removed.", "info")
        return
    elseif op == "edit" then
        if isstring(data.name) and AINPCS.Trim(data.name) ~= "" then
            rec.name = AINPCS.Trim(data.name)
            ent:SetNWString("AINPCName", rec.name)
        end
        if isstring(data.personality) and AINPCS.Trim(data.personality) ~= "" then
            rec.personality = AINPCS.Trim(data.personality)
            ent:SetNWString("AINPCDescription", rec.personality)
        end
        if isstring(data.voiceId) and data.voiceId ~= "" then
            local vId = Voices.NormaliseId(data.voiceId)
            if Voices.Get(vId) then
                rec.voiceId = vId
                ent:SetNWString("AINPCVoice", vId)
            end
        end
        if isstring(data.fishKey) and data.fishKey ~= "" then
            rec.fishKey = AINPCS.Trim(data.fishKey)
        end
        if isstring(data.weapon) then
            rec.weaponChoice = data.weapon
            ent:SetNWString("AINPCWeaponChoice", data.weapon)
            giveNPCWeapon(ent, data.weapon, rec.npcData)
        end
        if data.enableTTS ~= nil then
            rec.enableTTS = CV_ALLOWED_TTS:GetBool() and (data.enableTTS == true)
        end
        sendToast(ply, "Updated " .. rec.name .. ".", "success")
    end
end)

-- =============================================================================
-- Chat command + proximity auto-route
-- =============================================================================

local function stripCommand(text)
    for _, prefix in ipairs({ "/say ", "/ainpc ", "!say ", "!ainpc ", "!ai " }) do
        if string.sub(text, 1, #prefix):lower() == prefix then
            return AINPCS.Trim(string.sub(text, #prefix + 1)), true
        end
    end
    for _, bare in ipairs({ "/say", "/ainpc", "!say", "!ainpc", "!ai" }) do
        if text:lower() == bare then
            return "", true
        end
    end
    return text, false
end

hook.Add("PlayerSay", "AINPC_ChatHandler", function(ply, text)
    if not CV_ENABLED:GetBool() then return end

    local msg, isCommand = stripCommand(text)
    local anyNPCs = next(NPCs) ~= nil

    if isCommand then
        if not anyNPCs then
            sendToast(ply, "No AI NPC spawned. Press C → AI NPCs to create one.", "error")
            return ""
        end
        if msg == "" then
            sendToast(ply, "Usage: /say <message>", "info")
            return ""
        end

        local rec = findBestNPCForSpeech(ply, msg, 99999)
        if not rec then
            sendToast(ply, "No AI NPC nearby.", "error")
            return ""
        end
        if not chatAllowed(ply) then return "" end
        triggerNPCDeliberation(rec, ply, msg, nil)
        return ""
    end

    -- Ignore slash/bang commands meant for other addons
    local firstChar = string.sub(AINPCS.Trim(text), 1, 1)
    if firstChar == "/" or firstChar == "!" or firstChar == "." or firstChar == "@" then
        return
    end

    -- Proximity auto-route: regular chat within range talks to addressed/nearest NPC
    if CV_PROXIMITY:GetBool() and anyNPCs then
        local rec = findBestNPCForSpeech(ply, text, CV_PROXIMITY_R:GetFloat())
        if rec and chatAllowed(ply) then
            triggerNPCDeliberation(rec, ply, text, nil)
        end
    end
end)

-- =============================================================================
-- E-to-talk: detect use-key on an AI NPC and open the chat UI client-side.
-- =============================================================================

hook.Add("KeyPress", "AINPC_UseToTalk", function(ply, button)
    if button ~= IN_USE then return end
    if not IsValid(ply) then return end

    local k = plyKey(ply)
    local now = CurTime()
    if (NextUse[k] or 0) > now then return end
    NextUse[k] = now + 0.5

    local tr = ply:GetEyeTrace()
    local ent = tr.Entity
    if not IsValid(ent) then return end
    if not ent:GetNWBool("IsAINPC", false) then return end
    if ply:EyePos():Distance(ent:GetPos()) > CV_INTERACT_R:GetFloat() then return end

    if CV_MUTE_HL2:GetBool() and ent.SentenceStop then
        pcall(ent.SentenceStop, ent)
    end

    net.Start("AINPC_OpenChatUI")
    net.WriteEntity(ent)
    net.Send(ply)
end)

-- =============================================================================
-- Housekeeping
-- =============================================================================

hook.Add("EntityRemoved", "AINPC_EntRemoved", function(ent)
    if not IsValid(ent) then return end
    local idx = ent:EntIndex()
    if NPCs[idx] then cleanupNPC(idx) end
end)

hook.Add("PlayerDisconnected", "AINPC_PlayerLeft", function(ply)
    local key = plyKey(ply)
    NextSpawn[key] = nil
    NextChat[key] = nil
    NextUse[key] = nil
    for _, rec in pairs(NPCs) do
        if rec.ownerKey == key and IsValid(rec.ent) then
            rec.ent:Remove()
        end
    end
    for id, job in pairs(LocalRelay.pending) do
        if job.host == ply then failRelayJob(id, "host disconnected") end
    end
end)

hook.Add("OnCleanup", "AINPC_Cleanup", function(name)
    if name ~= "npcs" then return end
    cleanupAll()
end)

hook.Add("PostCleanupMap", "AINPC_MapCleanup", cleanupAll)

AINPCS.DebugPrint("[AI-NPCs] server loaded, version " .. AINPCS.Version)
