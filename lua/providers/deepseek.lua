local provider = {}

provider.id       = "deepseek"
provider.label    = "DeepSeek"
provider.getKeyUrl = "https://platform.deepseek.com/api_keys"
provider.note     = "Cheap paid API. Two models: chat (fast) and reasoner (o1-style)."
provider.defaultModel = "deepseek-chat"

provider.modelOrder = { "deepseek-chat", "deepseek-reasoner" }

provider.models = {
    ["deepseek-chat"] = {
        label = "DeepSeek Chat (V3)",
        max_tokens  = { min = 64, max = 8192, default = 2048 },
        temperature = { min = 0, max = 2, default = 1.3 },
        tool_support = true,
    },
    ["deepseek-reasoner"] = {
        label = "DeepSeek Reasoner (R1)",
        max_tokens  = { min = 64, max = 8192, default = 2048 },
        temperature = { min = 1, max = 1, default = 1 },
        tool_support = false,
    },
}

if SERVER then
    function provider.request(npc, callback)
        local q = npc._quirks or {}
        local tokField = q.tokens_field or "max_tokens"
        local body = {
            model    = npc.model,
            messages = npc.messages or npc.history,
            [tokField] = npc.max_tokens,
        }
        -- DeepSeek reasoner ignores temperature; chat uses it.
        if npc.temperature ~= nil and npc.model ~= "deepseek-reasoner" and not q.no_temp then
            body.temperature = npc.temperature
        end

        HTTP({
            url = "https://api.deepseek.com/chat/completions",
            method = "post",
            type = "application/json",
            headers = {
                ["Content-Type"]  = "application/json",
                ["Authorization"] = "Bearer " .. (npc.apiKey or ""),
            },
            body = util.TableToJSON(body),
            success = function(code, respBody)
                AINPCS.DebugPrint("[AI-NPCs][DeepSeek] " .. tostring(code))
                local parsed = AINPCS.SafeJSON(respBody)
                if not parsed then
                    return callback("Invalid JSON from DeepSeek (HTTP " .. tostring(code) .. ")", nil)
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
