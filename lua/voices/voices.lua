--[[
    AI NPCs — voice registry (shared, both realms)

    A voice id looks like "engine:param":
        google:en        keyless Google Translate TTS, one voice per language
        sapi4:Sam        keyless retro Microsoft voices
        relay:barney     a cloned voice served by the local relay
                         (see lua/voices/README.md)
        streamelements:Brian
                         legacy Polly voices — the public endpoint started
                         returning 401 in late 2025, kept for people running
                         their own credentials via the relay

    Only engines that demonstrably answer today are listed in V.list. Playback is
    URL-based on purpose: no API key is needed to listen, and the *server* picks
    the voice id, so every player hears the same NPC the same way. Anything that
    needs a secret key (ElevenLabs cloning, OpenAI TTS, Piper) belongs behind the
    relay, never in the client.
]]

AINPCS = AINPCS or {}

-- Singleton per realm: several files include this module, and each include would
-- otherwise reset the relay address and any runtime-registered voices.
if AINPCS.Voices then return AINPCS.Voices end

local V = {}

V.relay   = ""                  -- set by the server, see SetRelay
V.Default = "google:en"

-- Google caps a single request at roughly 200 characters; the client splits lines
-- into chunks below that. Keep the two numbers in sync.
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

V.byId = {}
for _, v in ipairs(V.list) do
    V.byId[v.id] = v
    v.engine, v.param = string.match(v.id, "^(%w+):(.+)$")
end

-- Relay voices are declared by the companion service at runtime.
function V.Register(id, label)
    if not id or V.byId[id] then return end
    local engine, param = string.match(id, "^(%w+):(.+)$")
    if not engine then return end
    local v = { id = id, label = label or id, engine = engine, param = param }
    table.insert(V.list, v)
    V.byId[id] = v
end

function V.Get(id)
    if not id then return nil end
    return V.byId[id]
end

function V.SetRelay(url)
    V.relay = string.gsub(url or "", "/+$", "")
end

function V.IsAvailable(id)
    local v = V.Get(id)
    if not v then return false end
    if v.engine == "relay" then return V.relay ~= "" end
    return true
end

-- Percent-encode everything that isn't URL-safe. Byte-wise is correct here: the
-- endpoints take UTF-8 bytes verbatim once encoded.
function V.Encode(str)
    return (string.gsub(str or "", "([^%w%-%._~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function flatten(text)
    text = string.gsub(text or "", "%s+", " ")
    return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

-- Build the url for ONE chunk of text. Callers are responsible for splitting long
-- lines; see V.Split for that.
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
    elseif v.engine == "relay" then
        if V.relay == "" then return nil end
        return V.relay .. "/tts?voice=" .. V.Encode(v.param) .. "&text=" .. encoded
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
            -- Too long on its own: break on words.
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
