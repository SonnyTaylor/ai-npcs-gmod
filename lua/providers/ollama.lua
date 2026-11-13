--[[
    Ollama provider (self-hosted). Uses the OpenAI-compatible
    /v1/chat/completions endpoint so max_tokens/temperature work natively
    and the response shape matches every other provider.
]]

local provider = {}

provider.id       = "ollama"
provider.label    = "Ollama (self-hosted)"
provider.getKeyUrl = "https://ollama.com/download"
provider.note     = "Runs locally (default 127.0.0.1:11434). Type any pulled model ID or pick a common preset below."

provider.requiresHostname = true
provider.allowCustomModel = true
provider.defaultModel     = "llama3.1:8b"

provider.modelOrder = {
    "llama3.1:8b",
    "llama3.2:3b",
    "gemma3:12b",
    "gemma3:4b",
    "qwen2.5:7b",
    "qwen3:8b",
    "deepseek-r1:8b",
    "mistral:7b",
}

local function preset(label, reasoning)
    return {
        label = label,
        free = true,
        price_in = 0,
        price_out = 0,
        max_tokens = { min = 64, max = 16384, default = 2048 },
        temperature = { min = 0, max = 2, default = 1 },
        reasoning = reasoning and { "none", "low", "medium", "high" } or nil,
        tool_support = true,
    }
end

provider.models = {
    ["llama3.1:8b"]    = preset("Llama 3.1 8B (local)", false),
    ["llama3.2:3b"]    = preset("Llama 3.2 3B (fast local)", false),
    ["gemma3:12b"]     = preset("Gemma 3 12B (local)", false),
    ["gemma3:4b"]      = preset("Gemma 3 4B (fast local)", false),
    ["qwen2.5:7b"]     = preset("Qwen 2.5 7B (local)", false),
    ["qwen3:8b"]       = preset("Qwen 3 8B (local, reasoning)", true),
    ["deepseek-r1:8b"] = preset("DeepSeek R1 8B (local, reasoning)", true),
    ["mistral:7b"]     = preset("Mistral 7B (local)", false),
}

-- `request` runs on whichever machine holds the player's key: the server
-- when the local player hosts, otherwise that player's own client.
if SERVER or CLIENT then
    function provider.request(npc, callback)
        local rawHost = npc.hostname
        if not rawHost or AINPCS.Trim(rawHost) == "" then
            rawHost = "127.0.0.1:11434"
        end
        local host = AINPCS.NormaliseHostname(rawHost, "http")

        local body = {
            model    = (npc.model and npc.model ~= "") and npc.model or "llama3.1:8b",
            messages = npc.messages or npc.history,
            stream   = false,
        }
        if npc.max_tokens then body.max_tokens = npc.max_tokens end
        if npc.temperature ~= nil then body.temperature = npc.temperature end

        local headers = { ["Content-Type"] = "application/json" }
        if not AINPCS.IsBlank(npc.apiKey) then
            headers["Authorization"] = "Bearer " .. npc.apiKey
        end

        local httpFn = AINPCS.HTTP or HTTP
        httpFn({
            url = host .. "/v1/chat/completions",
            method = "post",
            type = "application/json",
            headers = headers,
            body = util.TableToJSON(body),
            success = function(code, respBody)
                AINPCS.DebugPrint("[AI-NPCs][Ollama] " .. tostring(code))
                local parsed = AINPCS.SafeJSON(respBody)
                if not parsed then
                    return callback("Invalid JSON from Ollama (HTTP " .. tostring(code) .. "). Is Ollama running at " .. host .. "?", nil)
                end
                callback(nil, parsed)
            end,
            failed = function(err)
                callback("HTTP error: " .. tostring(err) .. " (is Ollama running at " .. host .. "?)", nil)
            end,
        })
    end
end

return provider
