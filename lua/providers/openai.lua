local provider = {}

provider.id       = "openai"
provider.label    = "OpenAI"
provider.getKeyUrl = "https://platform.openai.com/api-keys"
provider.note     = "Paid. Blocked in some regions (Russia, China, etc)."
provider.defaultModel = "gpt-5-mini"

provider.modelOrder = {
    "gpt-5",
    "gpt-5-mini",
    "gpt-5-nano",
    "gpt-5-pro",
    "gpt-4.1",
    "gpt-4.1-mini",
    "gpt-4o",
    "gpt-4o-mini",
    "o4-mini",
}

local gpt5Settings = {
    max_tokens  = { min = 128, max = 8192, default = 2048 },
    temperature = { min = 1, max = 1, default = 1 },
    reasoning   = { "none", "minimal", "low", "medium", "high" },
    tool_support = true,
}

local gpt4Settings = {
    max_tokens  = { min = 128, max = 4096, default = 2048 },
    temperature = { min = 0, max = 2, default = 1 },
    tool_support = true,
}

provider.models = {
    ["gpt-5"]       = table.Copy(gpt5Settings), ["gpt-5-mini"] = table.Copy(gpt5Settings),
    ["gpt-5-nano"]  = table.Copy(gpt5Settings), ["gpt-5-pro"]  = table.Copy(gpt5Settings),
    ["gpt-4.1"]     = table.Copy(gpt4Settings), ["gpt-4.1-mini"] = table.Copy(gpt4Settings),
    ["gpt-4o"]      = table.Copy(gpt4Settings), ["gpt-4o-mini"]  = table.Copy(gpt4Settings),
    ["o4-mini"] = {
        max_tokens  = { min = 128, max = 8192, default = 2048 },
        temperature = { min = 1, max = 1, default = 1 },
        reasoning   = { "none", "minimal", "low", "medium", "high" },
        tool_support = true,
    },
}
provider.models["gpt-5"].label       = "GPT-5"
provider.models["gpt-5-mini"].label  = "GPT-5 Mini"
provider.models["gpt-5-nano"].label  = "GPT-5 Nano"
provider.models["gpt-5-pro"].label   = "GPT-5 Pro"
provider.models["gpt-4.1"].label     = "GPT-4.1"
provider.models["gpt-4.1-mini"].label = "GPT-4.1 Mini"
provider.models["gpt-4o"].label      = "GPT-4o"
provider.models["gpt-4o-mini"].label = "GPT-4o Mini"
provider.models["o4-mini"].label     = "o4-mini (reasoning)"

-- `request` runs on whichever machine holds the player's key: the server
-- when the local player hosts, otherwise that player's own client.
if SERVER or CLIENT then
    function provider.request(npc, callback)
        local q = npc._quirks or {}
        local tokField = q.tokens_field or "max_completion_tokens"
        local body = {
            model = npc.model,
            messages = npc.messages or npc.history,
            [tokField] = npc.max_tokens,
        }
        if npc.reasoning and npc.reasoning ~= "" and not q.no_reasoning then
            -- OpenAI has no true "off"; minimal is the fastest it will go.
            body.reasoning_effort = (npc.reasoning == "none") and "minimal" or npc.reasoning
        end
        if npc.temperature ~= nil and not q.no_temp then
            body.temperature = npc.temperature
        end

        HTTP({
            url = "https://api.openai.com/v1/chat/completions",
            method = "post",
            type = "application/json; charset=utf-8",
            headers = {
                ["Authorization"] = "Bearer " .. (npc.apiKey or ""),
            },
            body = util.TableToJSON(body),
            success = function(code, respBody)
                AINPCS.DebugPrint("[AI-NPCs][OpenAI] " .. tostring(code))
                local parsed = AINPCS.SafeJSON(respBody)
                if not parsed then
                    return callback("Invalid JSON from OpenAI (HTTP " .. tostring(code) .. ")", nil)
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
