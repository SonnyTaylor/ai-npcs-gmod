local provider = {}

provider.id       = "groq"
provider.label    = "Groq (free tier available)"
provider.getKeyUrl = "https://console.groq.com/keys"
provider.note     = "Free tier with daily rate limits. No credit card required. Fast inference."

provider.modelOrder = {
    "llama-3.3-70b-versatile",
    "llama-3.1-8b-instant",
    "openai/gpt-oss-120b",
    "openai/gpt-oss-20b",
    "qwen/qwen3-32b",
    "meta-llama/llama-4-maverick-17b-128e-instruct",
    "meta-llama/llama-4-scout-17b-16e-instruct",
    "groq/compound",
}

local function base(ctxMax, defTokens)
    return {
        max_tokens  = { min = 64, max = ctxMax, default = defTokens or 2048 },
        temperature = { min = 0, max = 2, default = 1 },
        tool_support = true,
    }
end

local function reasoningModel(ctxMax)
    local m = base(ctxMax)
    m.reasoning = { "none", "low", "medium", "high" }
    return m
end

provider.models = {
    ["llama-3.3-70b-versatile"] = base(32768),
    ["llama-3.1-8b-instant"]    = base(131072),
    ["openai/gpt-oss-120b"]     = reasoningModel(65536),
    ["openai/gpt-oss-20b"]      = reasoningModel(65536),
    ["qwen/qwen3-32b"]          = reasoningModel(40960),
    ["meta-llama/llama-4-maverick-17b-128e-instruct"] = base(8192),
    ["meta-llama/llama-4-scout-17b-16e-instruct"]     = base(8192),
    ["groq/compound"]           = base(32768),
}
provider.models["llama-3.3-70b-versatile"].label = "LLaMA 3.3 70B (general)"
provider.models["llama-3.1-8b-instant"].label    = "LLaMA 3.1 8B (fast)"
provider.models["openai/gpt-oss-120b"].label     = "GPT-OSS 120B (reasoning)"
provider.models["openai/gpt-oss-20b"].label      = "GPT-OSS 20B (reasoning)"
provider.models["qwen/qwen3-32b"].label          = "Qwen3 32B (reasoning)"
provider.models["meta-llama/llama-4-maverick-17b-128e-instruct"].label = "LLaMA 4 Maverick 17B"
provider.models["meta-llama/llama-4-scout-17b-16e-instruct"].label     = "LLaMA 4 Scout 17B"
provider.models["groq/compound"].label           = "Compound (with web search)"

if SERVER then
    function provider.request(npc, callback)
        local body = {
            model = npc.model,
            messages = npc.history,
            max_tokens = npc.max_tokens,
        }
        if npc.temperature ~= nil then body.temperature = npc.temperature end
        if npc.reasoning and npc.reasoning ~= "" then
            -- Groq has no "off"; low + hidden thinking is the fast path.
            body.reasoning_effort = (npc.reasoning == "none") and "low" or npc.reasoning
            body.reasoning_format = "hidden"
        end

        HTTP({
            url = "https://api.groq.com/openai/v1/chat/completions",
            method = "post",
            type = "application/json",
            headers = {
                ["Content-Type"]  = "application/json",
                ["Authorization"] = "Bearer " .. (npc.apiKey or ""),
            },
            body = util.TableToJSON(body),
            success = function(code, respBody)
                AINPCS.DebugPrint("[AI-NPCs][Groq] " .. tostring(code))
                local parsed = AINPCS.SafeJSON(respBody)
                if not parsed then
                    return callback("Invalid JSON from Groq (HTTP " .. tostring(code) .. ")", nil)
                end
                callback(nil, parsed)
            end,
            failed = function(err)
                callback("HTTP error: " .. tostring(err), nil)
            end,
        })
    end
end

return provider
