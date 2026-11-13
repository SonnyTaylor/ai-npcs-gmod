--[[
    AI NPCs — provider registry
    Loaded on both realms. Each provider module exposes:
      provider.id          (string)
      provider.label       (string, shown in UI)
      provider.getKeyUrl   (string, URL users open to get a free API key)
      provider.modelOrder  (array of model ids, optional)
      provider.models      (map of id → { label, max_tokens, temperature, reasoning, tool_support })
      provider.defaultModel (optional id preselected in the panel when nothing else fits)
      provider.request     (server-only function: request(npc, callback))
      provider.refresh     (optional, server-only, refreshes model list at runtime)
]]

local providers = {}

local REGISTRY_ORDER = { "groq", "openrouter", "openai", "deepseek", "ollama" }
local REGISTRY = {}

local function loadProvider(id)
    if REGISTRY[id] ~= nil then return REGISTRY[id] end
    local ok, mod = pcall(include, "providers/" .. id .. ".lua")
    if not ok or not istable(mod) then
        AINPCS.DebugPrint("[AI-NPCs] Failed to load provider '" .. tostring(id) .. "': " .. tostring(mod))
        REGISTRY[id] = false
        return nil
    end
    mod.id = mod.id or id
    REGISTRY[id] = mod
    return mod
end

function providers.get(id)
    if not id or id == "" then return nil end
    return loadProvider(id)
end

function providers.list()
    local out = {}
    for _, id in ipairs(REGISTRY_ORDER) do
        local mod = loadProvider(id)
        if mod then table.insert(out, mod) end
    end
    return out
end

function providers.ids()
    local out = {}
    for _, id in ipairs(REGISTRY_ORDER) do
        table.insert(out, id)
    end
    return out
end

return providers
