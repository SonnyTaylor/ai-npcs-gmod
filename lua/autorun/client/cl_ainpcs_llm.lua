--[[
    AI NPCs — client-side model requests

    When you join someone else's server, your API key never leaves your PC: the
    server builds the prompt (it owns the NPC's situation report), sends it here,
    and this client makes the provider call with *your* key. The reply goes back
    as plain text and the server decides what the NPC does with it.

    If you are hosting (singleplayer or a listen server) the key never has to
    travel at all, so generation stays on the server and this file does nothing.
]]

AINPCS = AINPCS or {}

local providers = AINPCS.Providers or include("providers/providers.lua")

-- Requests in flight, so a duplicate delivery cannot fire the provider twice.
local inFlight = {}

net.Receive("AINPC_LLMRequest", function()
    local entIdx = net.ReadUInt(16)
    local token  = net.ReadUInt(16)
    local ok, payload = pcall(net.ReadTable)

    if not ok or not istable(payload) then
        net.Start("AINPC_LLMReply")
        net.WriteUInt(entIdx, 16)
        net.WriteUInt(token, 16)
        net.WriteString("")
        net.WriteString("malformed request")
        net.WriteBool(false)
        net.SendToServer()
        return
    end

    local key = table.concat({ tostring(entIdx), ":", tostring(token) })
    if inFlight[key] then return end
    inFlight[key] = true

    local function finish(content, err, noKey)
        inFlight[key] = nil
        net.Start("AINPC_LLMReply")
        net.WriteUInt(entIdx, 16)
        net.WriteUInt(token, 16)
        net.WriteString(content or "")
        net.WriteString(err or "")
        net.WriteBool(noKey == true)
        net.SendToServer()
    end

    local provider = providers.get(tostring(payload.provider or ""))
    if not provider then
        finish(nil, "provider '" .. tostring(payload.provider) .. "' is not available in your game")
        return
    end

    -- Use this player's own key for whatever provider the NPC was configured with.
    local myKeys = (AINPCS.Settings and istable(AINPCS.Settings.apiKeys)) and AINPCS.Settings.apiKeys or {}
    local myKey = AINPCS.Trim(myKeys[provider.id] or "")

    if provider.id ~= "ollama" and myKey == "" then
        -- Tell the server we cannot help so it can ask the NPC's owner instead.
        finish(nil, "you have no " .. provider.label .. " key saved. Add one in Settings (or run the setup wizard).", true)
        return
    end

    local requestNPC = {
        provider    = provider.id,
        model       = payload.model or "",
        apiKey      = myKey,
        hostname    = (AINPCS.Settings and AINPCS.Settings.hostname) or "",
        max_tokens  = tonumber(payload.max_tokens) or 2048,
        temperature = tonumber(payload.temperature),
        reasoning   = payload.reasoning,
        messages    = istable(payload.messages) and payload.messages or {},
        _quirks     = istable(payload.quirks) and payload.quirks or {},
    }

    local answered = false
    local function once(content, err, noKey)
        if answered then return end
        answered = true
        finish(content, err, noKey)
    end

    -- A provider that never calls back must not leave the NPC waiting forever.
    timer.Simple(45, function()
        once(nil, "your game got no answer from " .. provider.label .. " in 45s")
    end)

    local sent, sendErr = pcall(provider.request, requestNPC, function(err, response)
        if err then
            once(nil, tostring(err))
            return
        end

        local content = AINPCS.ExtractReplyContent(response)
        if not content or AINPCS.Trim(AINPCS.CleanModelText(content)) == "" then
            once(nil, AINPCS.ExtractProviderError(response) or "the model returned an empty reply")
            return
        end

        once(content, nil)
    end)

    if not sent then
        once(nil, "request failed to start: " .. tostring(sendErr))
    end
end)

--- Debug helper: says whether this client or the server is doing the thinking.
concommand.Add("ainpc_llm_who", function()
    local host = AINPCS.IsListenHost and AINPCS.IsListenHost()
    MsgC(Color(90, 165, 255), "\n[AI NPCs] model requests\n")
    MsgN("  this client hosts the server: ", tostring(host or false))
    MsgN("  requests are made by:          ", host and "the server (key never leaves this PC)" or "this client, with your own key")
end)
