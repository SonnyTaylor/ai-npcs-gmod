--[[
    AI NPCs — voice registry (shared, both realms)

    A voice id looks like "engine:param":
        google:en        keyless Google Translate TTS, one voice per language
        sapi4:Sam        keyless retro Microsoft voices
        fish:<id>        Fish Audio character/cloned voice (100% in-game via HTTP + PlayFile)
        relay:<id>       legacy alias for fish:<id> so existing saved NPCs keep working
]]

AINPCS = AINPCS or {}

if AINPCS.Voices then return AINPCS.Voices end

local V = {}

V.Default = "google:en"
V.MaxChunkChars = 180

local function entry(id, label)
    return { id = id, label = label }
end

V.list = {
    entry("google:en", "English — Google TTS"),
    entry("google:de", "Deutsch — Google TTS"),
    entry("google:ru", "Русский — Google TTS"),
    entry("google:fr", "Français — Google TTS"),
    entry("google:es", "Español — Google TTS"),
    entry("google:it", "Italiano — Google TTS"),
    entry("google:pt", "Português — Google TTS"),
    entry("google:pl", "Polski — Google TTS"),
    entry("google:nl", "Nederlands — Google TTS"),
    entry("google:sv", "Svenska — Google TTS"),
    entry("google:da", "Dansk — Google TTS"),
    entry("google:tr", "Türkçe — Google TTS"),
    entry("google:ja", "日本語 — Google TTS"),
    entry("sapi4:Sam",   "Microsoft Sam (retro)"),
    entry("sapi4:Mike",  "Microsoft Mike (retro)"),
    entry("sapi4:Mary",  "Microsoft Mary (retro)"),
}

-- Starter Fish Audio character presets (from Fish Audio public model catalog)
V.StarterFish = {
    { name = "d2e75a3e3fd6419893057c02a375a113", label = "Rick Sanchez" },
    { name = "d75c270eaee14c8aa1e9e980cc37cf1b", label = "Peter Griffin" },
    { name = "842571141c5043b999536791c3363b9f", label = "Soldier (TF2)" },
    { name = "acc8237220d8470985ec9be6c4c480a9", label = "Hatsune Miku" },
    { name = "13533a60000342348698dda798564e72", label = "Metal Sonic" },
    { name = "6c8645b95abb44e0b9095ae3b241e4cc", label = "Goku" },
    { name = "a2346273eb314b6cb82ba83dbc9d9fee", label = "Markiplier" },
    { name = "a9261e0625ce4253914f5349fa0d7852", label = "MrBeast" },
    { name = "010da99c66f44d319159c8588315f22c", label = "Donald Trump" },
    { name = "f4923bed889f48c79ebb455e6c45e9f5", label = "Tom Pearl" },
}

V.byId = {}
for _, v in ipairs(V.list) do
    V.byId[v.id] = v
    v.engine, v.param = string.match(v.id, "^(%w+):(.+)$")
end

-- Normalise legacy "relay:<id>" to "fish:<id>" while keeping both resolvable
function V.NormaliseId(id)
    if not isstring(id) or id == "" then return V.Default end
    local eng, param = string.match(id, "^(%w+):(.+)$")
    if eng == "relay" then
        return "fish:" .. param
    end
    return id
end

function V.IsFish(id)
    if not isstring(id) then return false end
    local eng, param = string.match(id, "^(%w+):(.+)$")
    return (eng == "fish" or eng == "relay") and param ~= nil and param ~= ""
end

function V.FishModelId(id)
    if not isstring(id) then return nil end
    local eng, param = string.match(id, "^(%w+):(.+)$")
    if (eng == "fish" or eng == "relay") and param and param ~= "" then
        return param
    end
    return nil
end

function V.Register(id, label)
    if not id or id == "" then return end
    id = V.NormaliseId(id)
    local engine, param = string.match(id, "^(%w+):(.+)$")
    if not engine or not param then return end

    if V.byId[id] then
        if label and label ~= "" and label ~= id then
            V.byId[id].label = label
        end
        return V.byId[id]
    end

    local v = { id = id, label = label or param, engine = engine, param = param }
    table.insert(V.list, v)
    V.byId[id] = v
    -- Also map relay:<param> so older saved characters resolve their label
    V.byId["relay:" .. param] = v
    return v
end

-- Register starter Fish voices out of the box
for _, p in ipairs(V.StarterFish) do
    V.Register("fish:" .. p.name, p.label)
end

function V.Get(id)
    if not id or id == "" then return nil end
    local v = V.byId[id] or V.byId[V.NormaliseId(id)]
    if v then return v end
    -- Allow any dynamically selected fish:<32-hex> or relay:<32-hex> id
    local modelId = V.FishModelId(id)
    if modelId and string.match(modelId, "^[A-Za-z0-9_%-]+$") then
        return V.Register("fish:" .. modelId, modelId)
    end
    return nil
end

function V.SetRelay(_)
    -- Kept as a no-op for backward compatibility; external relay is retired.
end

function V.IsAvailable(id)
    return V.Get(id) ~= nil
end

-- Percent-encode everything that isn't URL-safe.
function V.Encode(str)
    return (string.gsub(str or "", "([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function flatten(text)
    text = string.gsub(text or "", "%s+", " ")
    return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

-- Build the URL for keyless URL-streamed voices (Google TTS, SAPI4).
-- Fish Audio voices use POST /v1/tts -> file.Write -> sound.PlayFile instead.
function V.BuildURL(id, text)
    local v = V.Get(id) or V.Get(V.Default)
    if not v then return nil end

    text = flatten(text)
    if #text == 0 then return nil end

    local encoded = V.Encode(text)

    if v.engine == "google" then
        return "https://translate.google.com/translate_tts?ie=UTF-8&client=tw-ob&tl="
            .. V.Encode(v.param) .. "&q=" .. encoded
    elseif v.engine == "sapi4" then
        return "https://tetyys.com/SAPI4/SAPI4?voice="
            .. V.Encode(v.param) .. "&pitch=100&speed=150&text=" .. encoded
    elseif v.engine == "streamelements" then
        return "https://api.streamelements.com/kappa/v2/speech?voice="
            .. V.Encode(v.param) .. "&text=" .. encoded
    end

    return nil
end

-- Split a line into speakable chunks: sentence boundaries first, word boundaries
-- when a single sentence is still too long, hard cuts as a last resort.
function V.Split(text, maxChars)
    maxChars = maxChars or V.MaxChunkChars
    local chunks = {}
    if flatten(text) == "" then return chunks end

    local sentences = {}
    local buffer = ""
    for piece in string.gmatch(flatten(text) .. " ", "(.-[%.%!%?]+%s+)") do
        buffer = buffer .. piece
    end
    local remainder = string.sub(flatten(text), #buffer + 1)
    if buffer ~= "" then table.insert(sentences, buffer) end
    if flatten(remainder) ~= "" then table.insert(sentences, remainder) end
    if #sentences == 0 then table.insert(sentences, flatten(text)) end

    local current = ""
    for _, sentence in ipairs(sentences) do
        sentence = flatten(sentence)
        if #sentence > maxChars then
            local line = ""
            for word in string.gmatch(sentence, "%S+") do
                if #line == 0 then
                    line = word
                elseif #line + 1 + #word <= maxChars then
                    line = line .. " " .. word
                else
                    table.insert(chunks, line)
                    line = word
                end
                while #line > maxChars do
                    table.insert(chunks, string.sub(line, 1, maxChars))
                    line = string.sub(line, maxChars + 1)
                end
            end
            if line ~= "" then
                if #current + 1 + #line <= maxChars then
                    current = (current == "" and line) or (current .. " " .. line)
                else
                    if current ~= "" then table.insert(chunks, current) end
                    current = line
                end
            end
        elseif #current == 0 then
            current = sentence
        elseif #current + 1 + #sentence <= maxChars then
            current = current .. " " .. sentence
        else
            table.insert(chunks, current)
            current = sentence
        end
    end

    if current ~= "" then table.insert(chunks, current) end
    if #chunks == 0 then table.insert(chunks, flatten(text)) end
    return chunks
end

AINPCS.Voices = V
return V
