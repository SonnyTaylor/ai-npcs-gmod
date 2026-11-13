--[[
    OpenRouter provider.
    Free models rotate monthly, so we fetch them at runtime from
    https://openrouter.ai/api/v1/models and filter by pricing.prompt == "0".
    A tiny hardcoded fallback list ships with the addon in case the fetch fails.
]]

local provider = {}

provider.id       = "openrouter"
provider.label    = "OpenRouter (free models available)"
provider.getKeyUrl = "https://openrouter.ai/keys"
provider.note     = "Free models rotate. Tick \"Free only\" below to hide paid models; untick it if you are happy to spend a little."

-- Paid default for people with credits: cheap and fast (1M context). The panel
-- preselects this as soon as "Free only" is unticked.
provider.defaultModel = "deepseek/deepseek-v4.1-flash-1017"

-- Fallback preset — used only if the live fetch fails. These are genuinely free
-- and text-only as of 2026-11; the live fetch supersedes them, and the previous
-- fallback list was entirely delisted by OpenRouter (every id 404'd).
provider.modelOrder = {
    "openrouter/free",
    "nvidia/nemotron-3-ultra-550b-a55b:free",
    "nvidia/nemotron-3.5-lightning:free",
    "baidu/ernie-5.5-flash-preview:free",
    "google/gemma-4-31b-it:free",
    "google/gemma-4-26b-a4b-it:free",
    "thinkingmachines/inkling-2-small:free",
    "dots-studio/dots-3-note-preview:free",
    "recursive/flint-v1.0:free",
    "liquid/lfm-3-1.7b:free",
    "deepseek/deepseek-v4.1-flash-1017",
}

local function defaults(label, ctxMax, reasoning, tools)
    return {
        label = label,
        free = true,
        price_in = 0,
        price_out = 0,
        max_tokens   = { min = 64, max = math.min(ctxMax or 8192, 32768), default = 2048 },
        temperature  = { min = 0, max = 2, default = 1 },
        reasoning    = reasoning and { "none", "low", "medium", "high" } or nil,
        tool_support = tools == true,
    }
end

provider.models = {
    -- Paid default, kept in the static list so it is selectable before the first
    -- live fetch lands. Hidden while "Free models only" is ticked.
    ["deepseek/deepseek-v4.1-flash-1017"] = {
        label = "DeepSeek V4.1 Flash (cheap + fast)",
        free = false,
        price_in = 0.15,
        price_out = 0.60,
        max_tokens  = { min = 64, max = 32768, default = 2048 },
        temperature = { min = 0, max = 2, default = 1 },
        tool_support = true,
    },
    ["openrouter/free"]                        = defaults("Free Models Router (auto-pick)", 200000, true, true),
    ["nvidia/nemotron-3-ultra-550b-a55b:free"] = defaults("Nemotron 3 Ultra 550B (free, reasoning)", 200000, true, true),
    ["nvidia/nemotron-3.5-lightning:free"]     = defaults("Nemotron 3.5 Lightning (free, fast)", 200000, true, true),
    ["baidu/ernie-5.5-flash-preview:free"]     = defaults("ERNIE 5.5 Flash (free, huge ctx)", 200000, true, true),
    ["google/gemma-4-31b-it:free"]             = defaults("Gemma 4 31B (free)", 65536, true, true),
    ["google/gemma-4-26b-a4b-it:free"]         = defaults("Gemma 4 26B A4B (free)", 65536, true, true),
    ["thinkingmachines/inkling-2-small:free"]  = defaults("Inkling 2 Small (free)", 65536, false, false),
    ["dots-studio/dots-3-note-preview:free"]   = defaults("Dots 3 Note (free)", 65536, true, true),
    ["recursive/flint-v1.0:free"]              = defaults("Flint v1.0 (free, RP-leaning)", 65536, false, false),
    ["liquid/lfm-3-1.7b:free"]                 = defaults("LFM 3 1.7B (free, tiny)", 32768, false, false),
}

if SERVER or CLIENT then
    local function buildBody(npc)
        local q = npc._quirks or {}
        local tokField = q.tokens_field or "max_tokens"
        local body = {
            model    = npc.model,
            messages = npc.messages or npc.history,
            [tokField] = npc.max_tokens,
        }
        if npc.temperature ~= nil and not q.no_temp then body.temperature = npc.temperature end
        if npc.reasoning and npc.reasoning ~= "" and not q.no_reasoning then
            -- "none" is a real OpenRouter value: reasoning off, first token sooner.
            body.reasoning = { effort = npc.reasoning }
        end
        return body
    end

    function provider.request(npc, callback)
        HTTP({
            url = "https://openrouter.ai/api/v1/chat/completions",
            method = "post",
            type = "application/json",
            headers = {
                ["Content-Type"]    = "application/json",
                ["Authorization"]   = "Bearer " .. (npc.apiKey or ""),
                ["HTTP-Referer"]    = "https://github.com/SonnyTaylor/AI-NPCs-GMod",
                ["X-Title"]         = "Garry's Mod AI NPCs",
            },
            body = util.TableToJSON(buildBody(npc)),
            success = function(code, respBody)
                AINPCS.DebugPrint("[AI-NPCs][OpenRouter] " .. tostring(code))
                local parsed = AINPCS.SafeJSON(respBody)
                if not parsed then
                    return callback("Invalid JSON from OpenRouter (HTTP " .. tostring(code) .. ")", nil)
                end
                callback(nil, parsed)
            end,
            failed = function(err)
                callback("HTTP error: " .. tostring(err), nil)
            end,
        })
    end

end

if SERVER then
    -- ----------------------------------------------------------------
    -- Live free-model fetch. Runs on startup + once every 24h.
    -- Results are merged back into provider.models and a copy is sent
    -- to clients via the AINPC_OpenRouterModels net message.
    -- ----------------------------------------------------------------

    provider._fetchedAt   = 0
    provider._fetchedList = nil

    local MAX_CHUNK = 50000

    local function sendModelsTo(target)
        if not provider._fetchedList then return end
        local payload = util.TableToJSON(provider._fetchedList)
        local total = #payload
        local chunks = math.ceil(total / MAX_CHUNK)
        if chunks < 1 then chunks = 1 end

        for i = 1, chunks do
            local startByte = (i - 1) * MAX_CHUNK + 1
            local endByte   = math.min(i * MAX_CHUNK, total)
            local slice = string.sub(payload, startByte, endByte)
            net.Start("AINPC_OpenRouterModels")
            net.WriteUInt(i, 8)
            net.WriteUInt(chunks, 8)
            net.WriteUInt(#slice, 20)
            net.WriteData(slice, #slice)
            if target then net.Send(target) else net.Broadcast() end
        end
    end

    local function broadcastModels() sendModelsTo(nil) end

    function provider.refresh(onDone)
        local cv = GetConVar("ainpc_openrouter_autorefresh")
        if cv and cv:GetInt() == 0 then
            if onDone then onDone(false, "disabled") end
            return
        end

        HTTP({
            url = "https://openrouter.ai/api/v1/models",
            method = "get",
            headers = { ["Accept"] = "application/json" },
            success = function(code, body)
                if code ~= 200 then
                    AINPCS.DebugPrint("[AI-NPCs][OpenRouter] refresh HTTP " .. tostring(code))
                    if onDone then onDone(false, "http " .. tostring(code)) end
                    return
                end

                local parsed = AINPCS.SafeJSON(body)
                if not parsed or not parsed.data then
                    if onDone then onDone(false, "bad json") end
                    return
                end

                local allList   = {}
                local allModels = {}
                local paidCount = 0

                for _, m in ipairs(parsed.data) do
                    local id = m.id or ""
                    local price = m.pricing or {}
                    local promptPrice = tonumber(price.prompt or "1") or 1
                    local complPrice  = tonumber(price.completion or "1") or 1

                    -- Chat models only: audio/image generators (e.g. google/lyria)
                    -- are priced at zero too, but can never answer an NPC line.
                    local outs = (m.architecture or {}).output_modalities
                    local textOnly = true
                    if istable(outs) then
                        for _, modality in ipairs(outs) do
                            if modality ~= "text" then textOnly = false end
                        end
                    end

                    if textOnly and id ~= "" then
                        local sp = m.supported_parameters or {}
                        local hasReasoning, hasTools = false, false
                        for _, p in ipairs(sp) do
                            if p == "reasoning" or p == "include_reasoning" then hasReasoning = true end
                            if p == "tools" then hasTools = true end
                        end

                        local ctx = tonumber(m.context_length) or 8192
                        local nameLabel = m.name or id
                        if #nameLabel > 60 then nameLabel = string.sub(nameLabel, 1, 57) .. "…" end

                        local free = (promptPrice == 0 and complPrice == 0)
                        if not free then paidCount = paidCount + 1 end

                        local entry = {
                            id = id,
                            label = nameLabel,
                            free = free,
                            -- per million tokens, for the panel's price hint
                            price_in  = promptPrice * 1000000,
                            price_out = complPrice * 1000000,
                            max_tokens   = { min = 64, max = math.min(ctx, 32768), default = 2048 },
                            temperature  = { min = 0, max = 2, default = 1 },
                            tool_support = hasTools,
                        }
                        if hasReasoning then
                            entry.reasoning = { "none", "low", "medium", "high" }
                        end
                        allModels[id] = entry
                        table.insert(allList, entry)
                    end
                end

                -- Free first (openrouter/free at the very top), then paid by input price:
                -- cheap-and-fast models land near the top of the paid block.
                table.sort(allList, function(a, b)
                    if a.id == "openrouter/free" then return true end
                    if b.id == "openrouter/free" then return false end
                    if a.free ~= b.free then return a.free end
                    if not a.free and a.price_in ~= b.price_in then return a.price_in < b.price_in end
                    return a.id < b.id
                end)

                -- Keep the net payload sane (~50KB); free models are never truncated.
                local allOrder = {}
                local MAX_MODELS = 400
                for _, entry in ipairs(allList) do
                    if #allOrder >= MAX_MODELS and not entry.free then break end
                    table.insert(allOrder, entry.id)
                end

                if #allOrder > 0 then
                    -- Always include the auto-router even if the API skipped it
                    if not allModels["openrouter/free"] then
                        local r = {
                            id = "openrouter/free",
                            label = "Free Models Router (auto-pick)",
                            free = true,
                            price_in = 0,
                            price_out = 0,
                            max_tokens  = { min = 64, max = 32768, default = 2048 },
                            temperature = { min = 0, max = 2, default = 1 },
                            tool_support = true,
                        }
                        allModels["openrouter/free"] = r
                        table.insert(allOrder, 1, "openrouter/free")
                    end

                    provider.modelOrder = allOrder
                    provider.models     = allModels
                    provider._fetchedAt = os.time()
                    provider._fetchedList = {
                        order  = allOrder,
                        models = allModels,
                    }
                    AINPCS.DebugPrint("[AI-NPCs][OpenRouter] loaded " .. #allOrder .. " models (" .. paidCount .. " paid)")
                    broadcastModels()
                    if onDone then onDone(true) end
                else
                    if onDone then onDone(false, "no free models") end
                end
            end,
            failed = function(err)
                AINPCS.DebugPrint("[AI-NPCs][OpenRouter] refresh failed: " .. tostring(err))
                if onDone then onDone(false, err) end
            end,
        })
    end

    -- Kick off a refresh as soon as this file is included. The server eagerly
    -- includes this provider at boot (see sv_gmodainpc.lua), so the timers below
    -- exist for the whole session. Do NOT gate this behind the "Initialize" hook:
    -- this file loads lazily on first use, long after Initialize has fired.
    timer.Simple(5, function() provider.refresh() end)

    -- Refresh once a day.
    timer.Create("AINPC_OpenRouterRefresh", 24 * 60 * 60, 0, function()
        provider.refresh()
    end)

    -- The config panel asks for the list when the user looks at the dropdown, so a
    -- freshly-joined client never stares at the stale hardcoded fallback list.
    local NextRequest = {}
    net.Receive("AINPC_RequestORModels", function(len, ply)
        if not IsValid(ply) then return end
        local key = ply:SteamID64() or ("ent_" .. ply:EntIndex())
        local now = CurTime()
        if (NextRequest[key] or 0) > now then return end
        NextRequest[key] = now + 5

        local fresh = provider._fetchedList and (os.time() - (provider._fetchedAt or 0)) < 24 * 60 * 60
        if fresh then
            sendModelsTo(ply)
        else
            provider.refresh()   -- broadcasts to everyone on success
        end
    end)

    -- Send current models to any player who joins after refresh.
    hook.Add("PlayerInitialSpawn", "AINPC_OpenRouterSendCache", function(ply)
        if not provider._fetchedList then return end
        timer.Simple(3, function()
            if not IsValid(ply) then return end
            sendModelsTo(ply)
        end)
    end)
end

return provider
