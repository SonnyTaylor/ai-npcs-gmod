--[[
    AI NPCs — client interaction layer
    Handles:
      * the E-to-talk chat popup
      * toast notifications
      * chat reply rendering (chat area + optional speech bubble log)
      * per-NPC voice playback, chunked and positioned in 3D
]]

AINPCS          = AINPCS or {}
AINPCS.Toasts   = AINPCS.Toasts or {}
AINPCS.LastChat = AINPCS.LastChat or {}   -- [entIndex] = { text, until }

-- =============================================================================
-- Toast (top-right ephemeral messages)
-- =============================================================================

local TOAST_COLORS = {
    info    = Color(60, 120, 200),
    success = Color(60, 160, 90),
    error   = Color(200, 60, 60),
}

function AINPCS.PushToast(text, kind)
    table.insert(AINPCS.Toasts, 1, {
        text    = text or "",
        kind    = kind or "info",
        expires = RealTime() + 6,
        born    = RealTime(),
    })
    while #AINPCS.Toasts > 5 do table.remove(AINPCS.Toasts) end
end

hook.Add("HUDPaint", "AINPC_Toasts", function()
    if #AINPCS.Toasts == 0 then return end
    surface.SetFont("AINPC_Body")

    local now = RealTime()
    local y = 140
    for i = #AINPCS.Toasts, 1, -1 do
        if AINPCS.Toasts[i].expires < now then
            table.remove(AINPCS.Toasts, i)
        end
    end

    for _, t in ipairs(AINPCS.Toasts) do
        local lifespan = t.expires - t.born
        local remaining = t.expires - now
        local alpha = 255
        if remaining < 0.5 then alpha = math.floor(remaining * 2 * 255) end
        if now - t.born < 0.25 then alpha = math.floor((now - t.born) * 4 * 255) end

        local tw, th = surface.GetTextSize(t.text)
        local w = math.max(tw + 28, 220)
        local h = th + 16
        local x = ScrW() - w - 20
        local bg = TOAST_COLORS[t.kind] or TOAST_COLORS.info

        draw.RoundedBox(6, x, y, w, h, Color(30, 30, 34, alpha))
        draw.RoundedBox(6, x, y, 4, h, Color(bg.r, bg.g, bg.b, alpha))
        draw.SimpleText(t.text, "AINPC_Body", x + 14, y + h / 2, Color(235, 235, 235, alpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        y = y + h + 6
    end
end)

net.Receive("AINPC_Toast", function()
    AINPCS.PushToast(net.ReadString(), net.ReadString())
end)

-- =============================================================================
-- Per-NPC chat window
-- =============================================================================

AINPCS.ChatWindows = AINPCS.ChatWindows or {}

local function closeChatWindow(entIndex)
    local w = AINPCS.ChatWindows[entIndex]
    if IsValid(w) then w:Remove() end
    AINPCS.ChatWindows[entIndex] = nil
end

local function appendChatLine(win, author, text, color)
    local list = win.chatList
    if not IsValid(list) then return end

    local canvas = list:GetCanvas()
    local width  = canvas:GetWide() - 8
    if width < 100 then width = 400 end

    local authorLbl = vgui.Create("DLabel", canvas)
    authorLbl:SetFont("AINPC_Small")
    authorLbl:SetTextColor(color or Color(200, 200, 200))
    authorLbl:SetText(author)
    authorLbl:SizeToContents()
    authorLbl:Dock(TOP)
    authorLbl:DockMargin(4, 6, 4, 0)
    list:AddItem(authorLbl)

    local body = vgui.Create("DLabel", canvas)
    body:SetFont("AINPC_Body")
    body:SetTextColor(Color(230, 230, 230))
    body:SetText(text)
    body:SetWrap(true)
    body:SetAutoStretchVertical(true)
    body:SetWide(width)
    body:Dock(TOP)
    body:DockMargin(4, 0, 4, 6)
    list:AddItem(body)

    timer.Simple(0, function()
        if IsValid(list) and IsValid(body) then
            list:ScrollToChild(body)
        end
    end)
end

function AINPCS.OpenChatWindow(ent)
    if not IsValid(ent) then return end
    local idx = ent:EntIndex()
    if IsValid(AINPCS.ChatWindows[idx]) then
        AINPCS.ChatWindows[idx]:MakePopup()
        return AINPCS.ChatWindows[idx]
    end

    local npcName = ent:GetNWString("AINPCName", "NPC")

    local f = vgui.Create("DFrame")
    f:SetSize(460, 380)
    f:SetPos(ScrW() - 480, ScrH() - 420)
    f:SetTitle("Talking to " .. npcName)
    f:SetDeleteOnClose(true)
    f:MakePopup()
    f.OnRemove = function() AINPCS.ChatWindows[idx] = nil end
    AINPCS.ChatWindows[idx] = f

    local list = vgui.Create("DScrollPanel", f)
    list:Dock(FILL)
    list:DockMargin(6, 4, 6, 6)
    f.chatList = list

    local inputRow = vgui.Create("DPanel", f)
    inputRow:Dock(BOTTOM)
    inputRow:SetTall(32)
    inputRow:DockMargin(6, 0, 6, 6)
    inputRow.Paint = nil

    local entry = vgui.Create("DTextEntry", inputRow)
    entry:Dock(FILL)
    entry:DockMargin(0, 0, 6, 0)
    entry:SetPlaceholderText("Type a message and press Enter")
    entry:RequestFocus()

    local sendBtn = vgui.Create("DButton", inputRow)
    sendBtn:Dock(RIGHT)
    sendBtn:SetWide(80)
    sendBtn:SetText("Send")

    local function send()
        local msg = AINPCS.Trim(entry:GetValue() or "")
        if msg == "" then return end
        if not IsValid(ent) then
            AINPCS.PushToast("NPC no longer exists.", "error")
            f:Close()
            return
        end
        appendChatLine(f, "You", msg, Color(130, 200, 255))
        entry:SetText("")

        net.Start("AINPC_ChatRequest")
        net.WriteEntity(ent)
        net.WriteString(msg)
        net.SendToServer()
    end

    sendBtn.DoClick = send
    entry.OnEnter   = send

    -- Replay the last thing the NPC said, if any.
    local last = AINPCS.LastChat[idx]
    if last and last.text and last.text ~= "" then
        appendChatLine(f, npcName, last.text, Color(255, 210, 120))
    end

    return f
end

-- =============================================================================
-- Chat reply handler
-- =============================================================================

net.Receive("AINPC_ChatReply", function()
    local ent    = net.ReadEntity()
    local name   = net.ReadString()
    local text   = net.ReadString()
    local isErr  = net.ReadBool()

    local idx = IsValid(ent) and ent:EntIndex() or 0
    AINPCS.LastChat[idx] = {
        text        = text,
        isError     = isErr,
        expires     = RealTime() + 10,
        -- Subtitle bubble lifetime on the HUD, roughly the length of the voice line.
        spokenUntil = isErr and 0 or (RealTime() + math.Clamp(#text / 14, 2.5, 9)),
    }

    local win = AINPCS.ChatWindows[idx]
    if IsValid(win) then
        appendChatLine(win, name, text, isErr and Color(235, 120, 120) or Color(255, 210, 120))
    end

    local colour = isErr and Color(235, 120, 120) or Color(255, 210, 120)
    chat.AddText(colour, "[" .. name .. "] ", Color(230, 230, 230), text)
end)

net.Receive("AINPC_OpenChatUI", function()
    local ent = net.ReadEntity()
    if IsValid(ent) then AINPCS.OpenChatWindow(ent) end
end)

-- =============================================================================
-- Voice playback
--
-- The server broadcasts (npc, voice id, text); every client builds the same urls
-- from the shared registry, so an NPC sounds identical to everyone in the server.
-- Long lines are split into chunks the engine will actually accept, played back
-- to back, re-positioned every frame so a walking NPC keeps its voice attached to
-- its head instead of leaving it behind where the sentence started.
-- =============================================================================

local Voices = include("voices/voices.lua")

local cvVoiceVolume = CreateClientConVar("ainpc_voice_volume", "1", true, false,
    "AI NPC voice volume (0-1).", 0, 1)

local warnedVoiceFailure = false
local Players = {}     -- [entIndex] = { voice, chunks, nextIndex, snd, pending, failures }

local function stopVoice(idx)
    local p = Players[idx]
    if not p then return end
    if p.snd and p.snd.Stop then pcall(p.snd.Stop, p.snd) end
    Players[idx] = nil
end

-- Channel state, written defensively: IsPlaying() is documented for
-- IGModAudioChannel but is absent in some builds (it threw every frame here), so
-- fall back to GetState(). GMOD_CHANNEL_IS_PLAYING == 1, _BUFFERING == 3.
local function channelPlaying(snd)
    if not snd then return false end

    if snd.IsPlaying then
        local ok, playing = pcall(snd.IsPlaying, snd)
        if ok then return playing and true or false end
    end

    if snd.GetState then
        local ok, state = pcall(snd.GetState, snd)
        if ok and state ~= nil then return (state == 1 or state == 3) end
    end

    if snd.GetTime and snd.GetLength then
        local okTime, now = pcall(snd.GetTime, snd)
        local okLen, len = pcall(snd.GetLength, snd)
        if okTime and okLen and now and len and len > 0 then return now < (len - 0.05) end
    end

    return false
end

local function voiceError(errId, errName)
    if warnedVoiceFailure then return end
    warnedVoiceFailure = true
    AINPCS.PushToast("Voice playback failed (" .. tostring(errName or errId) .. "). The voice host may be down or rate-limiting.", "error")
    AINPCS.DebugPrint("[AI-NPCs] voice error " .. tostring(errId) .. ": " .. tostring(errName))
end

-- The server convar is empty by default, which used to leave V.relay == "" and
-- silently make every cloned voice unplayable even when a local relay was up. Fall
-- back to the client's own relay address, which also carries the probed host
-- spelling (localhost vs 127.0.0.1).
local function currentRelayURL()
    local url = GetGlobalString("AINPCVoiceRelay", "") or ""
    if url == "" and AINPCS.RelayBase then url = AINPCS.RelayBase() end
    return url
end

net.Receive("AINPC_TTSPlay", function()
    local ent = net.ReadEntity()
    local voiceId = net.ReadString()
    local text = net.ReadString()

    if not IsValid(ent) then return end
    Voices.SetRelay(currentRelayURL())

    local chunks = Voices.Split(text)
    if #chunks == 0 then return end

    local idx = ent:EntIndex()
    stopVoice(idx)      -- a new line interrupts whatever is still playing
    Players[idx] = {
        voice = voiceId,
        chunks = chunks,
        nextIndex = 1,
        snd = nil,
        pending = false,
        failures = 0,
    }
end)

-- One "engine" pass per frame: advance queues, keep the active chunk glued to the NPC.
hook.Add("Think", "AINPC_VoiceEngine", function()
    local volume = math.Clamp(cvVoiceVolume:GetFloat(), 0, 1)

    for idx, p in pairs(Players) do
        local ent = Entity(idx)

        if not IsValid(ent) then
            stopVoice(idx)                      -- dead/removed NPC = silence
        elseif p.pending then
            -- Waiting for PlayURL to hand us a channel. A callback that never
            -- arrives would otherwise stall this NPC's queue forever.
            if RealTime() - (p.pendingSince or 0) > 5 then
                p.pending = false
                p.failures = (p.failures or 0) + 1
                if p.failures >= 3 then stopVoice(idx) end
            end
        elseif channelPlaying(p.snd) then
            if p.snd.SetPos then p.snd:SetPos(ent:GetPos() + Vector(0, 0, 62)) end
        else
            p.snd = nil
            local chunk = p.chunks[p.nextIndex]

            if not chunk then
                stopVoice(idx)                  -- done speaking
            else
                p.nextIndex = p.nextIndex + 1
                local url = Voices.BuildURL(p.voice, chunk)

                if url then
                    p.pending = true
                    p.pendingSince = RealTime()
                    local npc = ent

                    sound.PlayURL(url, "3d mono", function(snd, errId, errName)
                        if Players[idx] ~= p then return end     -- superseded meanwhile
                        p.pending = false

                        if not snd or not snd.SetPos then
                            p.failures = (p.failures or 0) + 1
                            voiceError(errId, errName)
                            if p.failures >= 3 then
                                stopVoice(idx)                  -- host is down; stop trying
                            end
                            return
                        end

                        if not IsValid(npc) then
                            p.pending = false
                            return
                        end

                        snd:SetPos(npc:GetPos() + Vector(0, 0, 62))
                        snd:Set3DFadeDistance(220, 1600)
                        snd:SetVolume(volume)
                        snd:Play()
                        p.snd = snd
                    end)
                else
                    p.failures = (p.failures or 0) + 1
                    if p.failures >= 3 then stopVoice(idx) end
                end
            end
        end
    end
end)

-- Entity indices are recycled: a dying NPC must not leave its voice keyed to an
-- index that the next NPC will inherit.
hook.Add("EntityRemoved", "AINPC_VoiceRemoved", function(ent)
    if not IsValid(ent) then return end
    stopVoice(ent:EntIndex())
end)

-- Used by the "Test voice" button in the config panel.
function AINPCS.PreviewVoice(voiceId, sample)
    Voices.SetRelay(currentRelayURL())
    local url = Voices.BuildURL(voiceId, sample or "Hello. This is what I sound like.")
    if not url then return false end

    sound.PlayURL(url, "mono", function(snd, errId, errName)
        if not IsValid(snd) then
            voiceError(errId, errName)
            return
        end
        snd:SetVolume(math.Clamp(cvVoiceVolume:GetFloat(), 0, 1))
        snd:Play()
    end)
    return true
end


-- =============================================================================
-- Feasibility probe: can GMod play a sound it wrote to disk itself?
--
-- If this works, the Fish Audio POST could happen straight from the game and the
-- external voice service would only be needed for exotic cases. It synthesises a
-- short tone in Lua (no network, no key, no cost) and tries to play it back.
-- =============================================================================

local function le16(v)
    v = math.floor(v) % 65536
    return string.char(v % 256, math.floor(v / 256) % 256)
end

local function le32(v)
    v = math.floor(v) % 4294967296
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function makeToneWav(seconds, hz, rate)
    rate = rate or 22050
    local n = math.floor(rate * (seconds or 0.6))
    local out = {}
    for i = 0, n - 1 do
        local v = math.floor(math.sin(i * hz * 2 * math.pi / rate) * 11000)
        if v < 0 then v = v + 65536 end
        out[#out + 1] = string.char(v % 256, math.floor(v / 256) % 256)
    end
    local data = table.concat(out)
    return "RIFF" .. le32(36 + #data) .. "WAVE" ..
           "fmt " .. le32(16) .. le16(1) .. le16(1) .. le32(rate) ..
           le32(rate * 2) .. le16(2) .. le16(16) ..
           "data" .. le32(#data) .. data
end

concommand.Add("ainpc_probe_localaudio", function()
    local wav = makeToneWav(0.6, 440)
    file.Write("ainpc_probe.wav", wav)

    local size = file.Size("ainpc_probe.wav", "DATA") or 0
    print(string.format("[AI-NPCs] wrote %d bytes to data/ainpc_probe.wav", size))

    local paths = { "data/ainpc_probe.wav", "ainpc_probe.wav" }
    local function tryPath(i)
        if i > #paths then
            print("[AI-NPCs] local file playback NOT supported - the voice service stays required")
            chat.AddText(Color(235, 120, 120), "[AI NPCs] ", Color(230, 230, 230),
                "Local audio playback unsupported; the voice service is still required.")
            return
        end

        local path = paths[i]
        sound.PlayFile(path, "mono", function(snd, errId, errName)
            if snd and snd.Play then
                snd:SetVolume(0.2)
                snd:Play()
                print(string.format("[AI-NPCs] local file playback WORKS via '%s'", path))
                chat.AddText(Color(130, 220, 150), "[AI NPCs] ",
                    Color(230, 230, 230), "Local audio playback works (" .. path .. ").")
            else
                print(string.format("[AI-NPCs] '%s' failed: %s %s", path, tostring(errId), tostring(errName)))
                tryPath(i + 1)
            end
        end)
    end
    tryPath(1)
end)

-- =============================================================================
-- Spawn result
-- =============================================================================

net.Receive("AINPC_SpawnResult", function()
    local ok = net.ReadBool()
    local ent = net.ReadEntity()
    local name = net.ReadString()
    if ok and IsValid(ent) then
        AINPCS.PushToast(name .. " spawned. Walk up and press E to talk.", "success")
    end
end)
