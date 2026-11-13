--[[
    AI NPCs — server

    Owns NPC state, chat routing, provider requests, and enforces the
    admin / cooldown / per-player limits. All player input is validated
    server-side. API keys never leave this file except inside HTTP requests.
]]

local providers = include("providers/providers.lua")
local Voices    = include("voices/voices.lua")

-- Load the OpenRouter provider at boot. It registers the model-request net receiver
-- and schedules the daily free-model refresh; lazy loading meant the refresh never
-- ran until someone happened to spawn an OpenRouter NPC.
providers.get("openrouter")

-- =============================================================================
-- Convars
-- =============================================================================

local CV_ENABLED       = CreateConVar("ainpc_enabled",               "1", FCVAR_ARCHIVE, "Master switch for the AI NPCs addon.")
local CV_ADMIN_ONLY    = CreateConVar("ainpc_admin_only",            "0", FCVAR_ARCHIVE, "If 1, only admins can spawn AI NPCs.")
local CV_MAX_PER_PLY   = CreateConVar("ainpc_max_per_player",        "3", FCVAR_ARCHIVE, "Maximum AI NPCs a single player may own at once.")
local CV_COOLDOWN      = CreateConVar("ainpc_cooldown_seconds",      "5", FCVAR_ARCHIVE, "Cooldown between NPC spawns per player (seconds).")
local CV_CHAT_COOLDOWN = CreateConVar("ainpc_chat_cooldown_seconds", "1.5", FCVAR_ARCHIVE, "Cooldown between chat messages per player (seconds).")
local CV_PROXIMITY     = CreateConVar("ainpc_proximity_chat",        "1", FCVAR_ARCHIVE, "If 1, chat messages auto-route to the nearest AI NPC within range.")
local CV_PROXIMITY_R   = CreateConVar("ainpc_proximity_range",       "250", FCVAR_ARCHIVE, "Max distance (units) for proximity chat auto-routing.")
local CV_INTERACT_R    = CreateConVar("ainpc_interact_range",        "140", FCVAR_ARCHIVE, "Max distance (units) for pressing E to open the chat UI.")
local CV_ALLOWED_TTS   = CreateConVar("ainpc_tts_allowed",           "1", FCVAR_ARCHIVE, "If 1, clients may enable TTS playback.")
local CV_VOICE_RELAY   = CreateConVar("ainpc_voice_relay",           "",  FCVAR_ARCHIVE, "Base URL of the optional voice relay that serves cloned voices (e.g. http://localhost:7171).")
local CV_OR_REFRESH    = CreateConVar("ainpc_openrouter_autorefresh", "1", FCVAR_ARCHIVE, "If 1, periodically fetch the current OpenRouter free-model list.")

-- Publish the relay address to clients so the "test voice" button can hit the same host.
local function applyRelay(value)
    Voices.SetRelay(value)
    SetGlobalString("AINPCVoiceRelay", Voices.relay or "")
end
applyRelay(CV_VOICE_RELAY:GetString())
if cvars and cvars.AddChangeCallback then
    cvars.AddChangeCallback("ainpc_voice_relay", function(_, _, newValue) applyRelay(newValue) end, "AINPC_RelayChanged")
end

-- =============================================================================
-- State
-- =============================================================================

-- NPCs[entIndex] = {
--   ent, owner, personality, provider, model, apiKey, hostname,
--   max_tokens, temperature, reasoning, enableTTS, history, name, thinking
-- }
local NPCs = {}

-- per-player cooldown tracking, keyed by SteamID64 so reconnects reset
local NextSpawn = {}
local NextChat  = {}
local NextUse   = {}
local NextPreview = {}

local function plyKey(ply)
    if not IsValid(ply) then return "_" end
    return ply:SteamID64() or ("ent_" .. ply:EntIndex())
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

-- Shared by every input path (chat window, /say, proximity auto-route). The net path
-- used to be the only one that respected the cooldown, so /say spam burned quota.
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

    -- If we hit the skybox, drop one in front of the player instead.
    if bit.band(util.PointContents(pos), CONTENTS_SOLID) ~= 0 or tr.HitSky then
        pos = ply:GetPos() + ply:GetForward() * 80
    end

    -- Ground-snap so NPCs don't float.
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
    hook.Remove("OnNPCKilled", "AINPC_Death_" .. entIndex)
    if IsValid(rec.ent) then rec.ent:SetNWBool("IsAINPC", false) end
    NPCs[entIndex] = nil
end

local function cleanupAll()
    for idx, rec in pairs(NPCs) do
        hook.Remove("OnNPCKilled", "AINPC_Death_" .. idx)
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
        sendToast(ply, "API key required for " .. provider.label .. ". Click the 'Get Key' button in the panel.", "error")
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
    ent:SetPos(pos)
    ent:SetAngles(Angle(0, math.random(0, 360), 0))
    if npcData.Model then ent:SetModel(npcData.Model) end
    if npcData.KeyValues then
        for k, v in pairs(npcData.KeyValues) do ent:SetKeyValue(k, tostring(v)) end
    end
    if npcData.SpawnFlags then
        ent:SetKeyValue("spawnflags", tostring(npcData.SpawnFlags))
    end
    ent:Spawn()
    ent:Activate()

    local displayName = AINPCS.Trim(data.name or "")
    if displayName == "" then displayName = "NPC" end

    -- An empty model id would earn a 400 from every provider.
    local modelId = AINPCS.Trim(data.model or "")
    if modelId == "" then
        local order = provider.modelOrder or {}
        modelId = order[1] or ""
    end

    -- Voice ids are validated so a tampered spawn request can't inject a url.
    local voiceId = data.voiceId or data.ttsVoice or Voices.Default
    if not Voices.Get(voiceId) then voiceId = Voices.Default end

    ent:SetNWBool("IsAINPC", true)
    ent:SetNWString("AINPCName", displayName)
    ent:SetNWString("AINPCOwnerName", ply:Nick())
    ent:SetNWBool("AINPCThinking", false)

    local personality = AINPCS.Trim(data.personality or "")
    if personality == "" then
        personality = "a friendly generic NPC with no particular background"
    end

    local systemPrompt = table.concat({
        "You are roleplaying as a non-player character inside Garry's Mod.",
        "Stay fully in character at all times. Do not break the fourth wall.",
        "Keep responses short (1-3 sentences) unless the player asks for more.",
        "Your character: " .. personality,
        "Your name is: " .. displayName,
        "Respond naturally to what the player says.",
    }, "\n")

    local rec = {
        ent         = ent,
        owner       = ply,
        ownerKey    = key,
        provider    = provider.id,
        apiKey      = data.apiKey or "",
        hostname    = data.hostname or "",
        model       = modelId,
        max_tokens  = tonumber(data.max_tokens) or 2048,
        temperature = tonumber(data.temperature),
        reasoning   = data.reasoning,
        enableTTS   = CV_ALLOWED_TTS:GetBool() and (data.enableTTS == true),
        voiceId     = voiceId,
        name        = displayName,
        personality = personality,
        basePrompt  = systemPrompt,
        history     = {
            { role = "system", content = systemPrompt },
        },
        thinking    = false,
    }

    NPCs[ent:EntIndex()] = rec

    hook.Add("OnNPCKilled", "AINPC_Death_" .. ent:EntIndex(), function(deadNPC)
        if deadNPC == ent then cleanupNPC(ent:EntIndex()) end
    end)

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
-- Chat pipeline
-- =============================================================================

-- Replies go to whoever asked AND the owner. Sending only to rec.owner meant a
-- second player's E-conversation got no answer, while the owner received replies to
-- a conversation they never had. NULL is written when the NPC died mid-request so
-- the player still hears about it.
local function sendChatReply(rec, text, isError, asker)
    local ent = IsValid(rec.ent) and rec.ent or NULL

    local recipients = {}
    if IsValid(asker) then table.insert(recipients, asker) end
    if IsValid(rec.owner) and rec.owner ~= asker then table.insert(recipients, rec.owner) end
    if #recipients == 0 then return end

    net.Start("AINPC_ChatReply")
    net.WriteEntity(ent)
    net.WriteString(rec.name or "NPC")
    net.WriteString(text or "")
    net.WriteBool(isError == true)
    net.Send(recipients)
end

-- Voice lines are broadcast as text + voice id. Clients build identical urls from
-- the shared registry, chunk the line to the engine's limit and stream it from the
-- NPC's head, so everyone hears the same voice regardless of who has what key.
local function playTTS(rec, text)
    if not rec.enableTTS then return end
    if not IsValid(rec.ent) then return end

    local voiceId = rec.voiceId or Voices.Default
    if not Voices.Get(voiceId) then voiceId = Voices.Default end

    text = AINPCS.Truncate(text or "", 600)
    if AINPCS.Trim(text) == "" then return end

    net.Start("AINPC_TTSPlay")
    net.WriteEntity(rec.ent)
    net.WriteString(voiceId)
    net.WriteString(text)
    net.Broadcast()
end

local function extractReply(response)
    if not istable(response) then return nil end
    local choices = response.choices
    if istable(choices) and choices[1] and istable(choices[1].message) then
        return choices[1].message.content
    end
    -- Ollama non-OpenAI-compat fallback
    if istable(response.message) and response.message.content then
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

-- Never let a provider echo the user's key back into chat or the console.
local function scrubKey(rec, text)
    text = text or ""
    local key = rec.apiKey
    if key and #key >= 8 then
        text = string.Replace(text, key, AINPCS.RedactKey(key))
    end
    return text
end

-- If a request failed or timed out, drop the unanswered user turn so the model
-- doesn't accumulate dangling prompts that degrade the next reply.
local function dropPendingUserTurn(rec, text)
    local last = rec.history[#rec.history]
    if last and last.role == "user" and last.content == text then
        table.remove(rec.history)
    end
end

--- A player's nickname is account data, not dialogue. The old code prefixed it
--- into the message body ("[salami nipples]: hi"), so models read the name as part
--- of what the player said and answered things like "did you just say salami
--- nipples?". Keep it out of the content, sanitise it, and tell the model what it
--- is instead.
local function speakerName(ply)
    if not IsValid(ply) then return nil end

    local nick = AINPCS.Trim(ply:Nick() or "")
    nick = string.gsub(nick, "[\r\n\"\\]", "")
    if nick == "" then return "player" end
    if #nick > 32 then nick = string.sub(nick, 1, 32) end

    return nick
end

local function sendMessageToNPC(rec, role, text, asker)
    if not IsValid(rec.ent) then
        if IsValid(asker) then sendToast(asker, "That NPC is gone.", "error") end
        return
    end

    local provider = providers.get(rec.provider)
    if not provider then
        sendChatReply(rec, "Provider '" .. tostring(rec.provider) .. "' is not available.", true, asker)
        return
    end

    -- One in-flight request per NPC: concurrent asks would interleave the history.
    if rec.thinking then
        if IsValid(asker) then
            sendToast(asker, (rec.name or "That NPC") .. " is still thinking — give it a second.", "info")
        end
        return
    end

    -- Refresh who is speaking in the system prompt rather than inside the
    -- utterance. The base prompt is stored at spawn so the line can be replaced
    -- each turn instead of accumulating.
    if role == "user" and rec.history[1] and rec.history[1].role == "system" then
        local who  = speakerName(asker)
        local base = rec.basePrompt

        -- base is nil only for an NPC spawned before this field existed; skip the
        -- line rather than concatenating nil.
        if base then
            if who then
                rec.history[1].content = base ..
                    "\n\nYou are talking to a player whose account name is \"" .. who ..
                    "\". That is a name, not something they said: do not repeat it, quote it " ..
                    "or react to it as if it were part of the conversation."
            else
                rec.history[1].content = base
            end
        end
    end

    table.insert(rec.history, { role = role, content = text })
    rec.history = AINPCS.TrimHistory(rec.history, AINPCS.Defaults.MaxHistoryTurns)

    setThinking(rec, true)

    -- Token guards against late callbacks: bumping it invalidates every older closure,
    -- including the timeout timer's.
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
        dropPendingUserTurn(rec, text)
        AINPCS.DebugPrint("[AI-NPCs] " .. tostring(rec.provider) .. " timed out after " .. AINPCS.Defaults.RequestTimeout .. "s")
        sendChatReply(rec, "(" .. (rec.name or "NPC") .. " didn't answer in time — the provider is slow or unreachable.)", true, asker)
    end)

    local function onResponse(err, response)
        if not settle() then return end   -- timed out or superseded

        if err then
            err = scrubKey(rec, err)
            dropPendingUserTurn(rec, text)
            AINPCS.DebugPrint("[AI-NPCs] " .. rec.provider .. " error: " .. err)
            sendChatReply(rec, "(" .. rec.name .. " can't respond right now: " .. err .. ")", true, asker)
            return
        end

        local content = extractReply(response)
        if not content then
            local errMsg = scrubKey(rec, extractError(response) or "no choices returned")
            dropPendingUserTurn(rec, text)
            AINPCS.DebugPrint("[AI-NPCs] bad response from " .. rec.provider .. ": " .. errMsg)
            sendChatReply(rec, "(" .. rec.name .. " seems confused: " .. errMsg .. ")", true, asker)
            return
        end

        content = AINPCS.Trim(content)
        table.insert(rec.history, { role = "assistant", content = content })
        sendChatReply(rec, content, false, asker)
        playTTS(rec, content)
    end

    -- A provider module can throw (bad hostname, malformed table). Don't leave the
    -- NPC stuck on "thinking..." because of it.
    local ok, requestErr = pcall(provider.request, rec, onResponse)
    if not ok and settle() then
        dropPendingUserTurn(rec, text)
        sendChatReply(rec, "(" .. (rec.name or "NPC") .. " hit an internal error: " .. scrubKey(rec, tostring(requestErr)) .. ")", true, asker)
    end
end

-- Find the nearest AI NPC within range that belongs (preferentially) to the player.
local function findNearestNPCForPlayer(ply, range)
    range = range or CV_PROXIMITY_R:GetFloat()
    local rangeSq = range * range
    local eye = ply:EyePos()
    local bestOwned, bestOwnedDist, bestAny, bestAnyDist = nil, math.huge, nil, math.huge
    local key = plyKey(ply)

    for _, rec in pairs(NPCs) do
        if IsValid(rec.ent) then
            local d = rec.ent:GetPos():DistToSqr(eye)
            if d <= rangeSq then
                if rec.ownerKey == key and d < bestOwnedDist then
                    bestOwned, bestOwnedDist = rec, d
                elseif d < bestAnyDist then
                    bestAny, bestAnyDist = rec, d
                end
            end
        end
    end

    return bestOwned or bestAny
end

-- =============================================================================
-- Net receivers
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

    -- Throttled: this handler makes the server create and remove an entity, and it
    -- was previously callable as fast as a modified client could send it.
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
        rec = findNearestNPCForPlayer(ply, CV_INTERACT_R:GetFloat() * 2)
    end

    if not rec then
        sendToast(ply, "No AI NPC nearby. Spawn one from the C menu → AI NPCs.", "error")
        return
    end

    sendMessageToNPC(rec, "user", msg, ply)
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

        local rec = findNearestNPCForPlayer(ply, 99999)
        if not rec then
            sendToast(ply, "No AI NPC nearby.", "error")
            return ""
        end
        if not chatAllowed(ply) then return "" end
        sendMessageToNPC(rec, "user", msg, ply)
        return ""
    end

    -- Proximity auto-route: regular chat within range talks to nearest NPC
    -- and is ALSO shown in world chat (we don't swallow it).
    if CV_PROXIMITY:GetBool() and anyNPCs then
        local rec = findNearestNPCForPlayer(ply, CV_PROXIMITY_R:GetFloat())
        if rec and chatAllowed(ply) then
            sendMessageToNPC(rec, "user", text, ply)
        end
    end
end)

-- =============================================================================
-- E-to-talk: detect use-key on an AI NPC and open the chat UI client-side.
-- KeyPress can fire repeatedly as the engine sees the key held, so we
-- debounce per player.
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
end)

hook.Add("OnCleanup", "AINPC_Cleanup", function(name)
    if name ~= "npcs" then return end
    cleanupAll()
end)

hook.Add("PostCleanupMap", "AINPC_MapCleanup", cleanupAll)

AINPCS.DebugPrint("[AI-NPCs] server loaded, version " .. AINPCS.Version)
