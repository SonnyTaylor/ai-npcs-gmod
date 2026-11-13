--[[
    AI NPCs — client interaction, voice playback & lip-sync layer
    Handles:
      * the E-to-talk chat window (with persistent history, quick actions & live NPC editor)
      * toast notifications
      * chat reply rendering (chat area + subtitle bubble state)
      * per-NPC 3D voice playback (both streamed Fish Audio files via sound.PlayFile
        and keyless URL voices via sound.PlayURL)
      * real-time mouth movement (GM:MouthMoveAnimation flexes driven by IGModAudioChannel:GetLevel())
        and emotional facial expressions
]]

AINPCS             = AINPCS or {}
AINPCS.Toasts      = AINPCS.Toasts or {}
AINPCS.LastChat    = AINPCS.LastChat or {}      -- [entIndex] = { text, expires, spokenUntil }
AINPCS.ChatHistory = AINPCS.ChatHistory or {}   -- [entIndex] = { { author, text, color, isSelf }, ... }

local Voices = include("voices/voices.lua")

-- Active per-entity voice playback state. Declared up here because the chat
-- reply reveal logic (below) and the voice engine (further down) share it.
local Players = {}       -- [entIndex] = { voice, chunks, nextIndex, snd, pending, failures }

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
-- Live NPC Editor Modal (edit an already-spawned NPC in the world)
-- =============================================================================

function AINPCS.OpenLiveEditModal(ent)
    if not IsValid(ent) then return end

    local f = vgui.Create("DFrame")
    f:SetSize(440, 390)
    f:Center()
    f:SetTitle("Edit Live NPC — " .. AINPCS.NPCName(ent))
    f:MakePopup()
    f.Paint = function(s, w, h)
        surface.SetDrawColor(24, 24, 28)
        surface.DrawRect(0, 0, w, h)
        surface.SetDrawColor(36, 36, 44)
        surface.DrawRect(0, 0, w, 24)
    end

    local function addLabel(txt, y)
        local l = vgui.Create("DLabel", f)
        l:SetFont("AINPC_Small")
        l:SetTextColor(Color(170, 170, 180))
        l:SetText(txt)
        l:SetPos(16, y)
        l:SetSize(400, 18)
        return l
    end

    addLabel("Name", 34)
    local nameE = vgui.Create("DTextEntry", f)
    nameE:SetPos(16, 54)
    nameE:SetSize(408, 28)
    nameE:SetText(AINPCS.NPCName(ent))

    addLabel("Personality / Character Description", 90)
    local descE = vgui.Create("DTextEntry", f)
    descE:SetPos(16, 110)
    descE:SetSize(408, 86)
    descE:SetMultiline(true)
    descE:SetText(ent:GetNWString("AINPCDescription", ""))

    addLabel("Voice", 204)
    local curVoice = Voices.NormaliseId(ent:GetNWString("AINPCVoice", Voices.Default))
    local voiceCombo = vgui.Create("DComboBox", f)
    voiceCombo:SetPos(16, 224)
    voiceCombo:SetSize(408, 28)
    voiceCombo:SetSortItems(false)

    local seenVoices = {}
    for _, p in ipairs(AINPCS.Settings.pinnedVoices or {}) do
        local vid = "fish:" .. p.name
        seenVoices[vid] = true
        voiceCombo:AddChoice(p.label .. " (Fish Audio)", vid, vid == curVoice)
    end
    for _, v in ipairs(Voices.list or {}) do
        local vid = Voices.NormaliseId(v.id)
        if not seenVoices[vid] then
            seenVoices[vid] = true
            voiceCombo:AddChoice(v.label, vid, vid == curVoice)
        end
    end
    local pickedVoice = curVoice
    voiceCombo.OnSelect = function(_, _, _, data) pickedVoice = data end

    addLabel("Weapon", 260)
    local curWep = ent:GetNWString("AINPCWeaponChoice", "none")
    local wepCombo = vgui.Create("DComboBox", f)
    wepCombo:SetPos(16, 280)
    wepCombo:SetSize(408, 28)
    wepCombo:SetSortItems(false)
    for _, wid in ipairs(AINPCS.WeaponOrder or {}) do
        local wInfo = AINPCS.Weapons[wid]
        if wInfo then
            wepCombo:AddChoice(wInfo.label, wid, wid == curWep)
        end
    end
    local pickedWep = curWep
    wepCombo.OnSelect = function(_, _, _, data) pickedWep = data end

    local saveBtn = vgui.Create("DButton", f)
    saveBtn:SetPos(16, 332)
    saveBtn:SetSize(200, 36)
    saveBtn:SetText("Save Changes")
    saveBtn:SetTextColor(color_white)
    saveBtn.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, s:IsHovered() and Color(66, 124, 216) or Color(52, 104, 190))
    end
    saveBtn.DoClick = function()
        if IsValid(ent) then
            AINPCS.UpdateLiveNPC(ent, {
                name        = AINPCS.Trim(nameE:GetValue() or ""),
                personality = AINPCS.Trim(descE:GetValue() or ""),
                voiceId     = pickedVoice,
                weapon      = pickedWep,
            })
        end
        f:Close()
    end

    local despawnBtn = vgui.Create("DButton", f)
    despawnBtn:SetPos(314, 332)
    despawnBtn:SetSize(110, 36)
    despawnBtn:SetText("Remove NPC")
    despawnBtn:SetTextColor(color_white)
    despawnBtn.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, s:IsHovered() and Color(165, 58, 58) or Color(125, 44, 44))
    end
    despawnBtn.DoClick = function()
        if IsValid(ent) then
            net.Start("AINPC_UpdateNPC")
            net.WriteEntity(ent)
            net.WriteTable({ op = "despawn" })
            net.SendToServer()
        end
        f:Close()
    end
end

-- =============================================================================
-- Per-NPC Chat Window (with persistent history & quick action bar)
-- =============================================================================

AINPCS.ChatWindows = AINPCS.ChatWindows or {}

-- Lines this client sent itself, per NPC. The chat window already appends what
-- you type; the server echoes the same line back so that /say and proximity chat
-- also land in the log. Without this, typing in the window showed your message
-- twice (the local append plus the echo).
AINPCS.SelfSends = AINPCS.SelfSends or {}

local function noteSelfSend(idx, text)
    if not idx or idx <= 0 or not isstring(text) then return end
    AINPCS.SelfSends[idx] = AINPCS.SelfSends[idx] or {}
    local list = AINPCS.SelfSends[idx]
    table.insert(list, { text = text, t = RealTime() })
    while #list > 8 do table.remove(list, 1) end
end

--- Did we already append this exact line locally? Consumes the match so a
--- repeated identical message still echoes the second time.
local function consumeSelfSend(idx, text)
    local list = AINPCS.SelfSends[idx]
    if not list or not isstring(text) then return false end
    local now = RealTime()
    for i = #list, 1, -1 do
        if now - list[i].t > 30 then
            table.remove(list, i)
        elseif list[i].text == text then
            table.remove(list, i)
            return true
        end
    end
    return false
end

local function recordHistoryLine(idx, author, text, color, isSelf)
    if not idx or idx <= 0 then return end
    AINPCS.ChatHistory[idx] = AINPCS.ChatHistory[idx] or {}
    local hist = AINPCS.ChatHistory[idx]

    -- Compare against the recent tail, not just the last entry: an LLM reply can
    -- take seconds, and a slow reply used to let the same line slip in twice.
    if isSelf then
        for i = #hist, math.max(1, #hist - 5), -1 do
            local prev = hist[i]
            if prev and prev.isSelf and prev.text == text and (RealTime() - (prev.t or 0)) < 30 then
                return false
            end
        end
    end

    table.insert(hist, {
        author = author,
        text   = text,
        color  = color,
        isSelf = isSelf == true,
        t      = RealTime(),
    })
    while #hist > 40 do table.remove(hist, 1) end
    return true
end

local function appendChatLineToWidget(win, author, text, color)
    if not IsValid(win) then return end
    local list = win.chatList
    if not IsValid(list) then return end

    local canvas = list:GetCanvas()
    local width  = canvas:GetWide() - 12
    if width < 100 then width = 440 end

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
    body:SetTextColor(Color(235, 235, 235))
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

    local npcName = AINPCS.NPCName(ent)

    local f = vgui.Create("DFrame")
    f:SetSize(500, 430)
    f:SetPos(ScrW() - 520, ScrH() - 470)
    f:SetTitle("Talking to " .. npcName)
    f:SetDeleteOnClose(true)
    f:MakePopup()

    -- Opaque fill via surface.DrawRect: draw.RoundedBox with alpha < 255 faded
    -- out entirely over a translucent Mantle window, leaving the map visible
    -- through the chat log.
    f.Paint = function(s, w, h)
        surface.SetDrawColor(22, 22, 26)
        surface.DrawRect(0, 0, w, h)
        surface.SetDrawColor(34, 34, 42)
        surface.DrawRect(0, 0, w, 24)
    end
    f.OnRemove = function() AINPCS.ChatWindows[idx] = nil end
    AINPCS.ChatWindows[idx] = f

    -- Quick Action Bar (Follow, Stay, Calm, Clear Memory, Edit Live NPC)
    local actionBar = vgui.Create("DPanel", f)
    actionBar:Dock(TOP)
    actionBar:SetTall(30)
    actionBar:DockMargin(6, 4, 6, 2)
    actionBar.Paint = nil

    local function quickBtn(labelTxt, col, onClick)
        local b = vgui.Create("DButton", actionBar)
        b:Dock(LEFT)
        b:DockMargin(0, 0, 4, 0)
        b:SetWide(88)
        b:SetText(labelTxt)
        b:SetFont("AINPC_Small")
        b:SetTextColor( Color(235, 235, 235) )
        b.Paint = function(s, w, h)
            draw.RoundedBox(5, 0, 0, w, h, s:IsHovered() and Color(col.r + 18, col.g + 18, col.b + 18) or col)
        end
        b.DoClick = onClick
        return b
    end

    quickBtn("Follow Me", Color(44, 78, 120), function()
        if IsValid(ent) then AINPCS.CommandNPC(ent, "follow") end
    end)
    quickBtn("Stay Here", Color(52, 52, 62), function()
        if IsValid(ent) then AINPCS.CommandNPC(ent, "stay") end
    end)
    quickBtn("Calm Down", Color(52, 82, 62), function()
        if IsValid(ent) then AINPCS.CommandNPC(ent, "stop_attacking") end
    end)
    quickBtn("Clear Chat", Color(82, 52, 52), function()
        if IsValid(ent) then AINPCS.ClearNPCMemory(ent) end
        if IsValid(f.chatList) then f.chatList:Clear() end
    end)
    quickBtn("Edit NPC", Color(68, 58, 98), function()
        if IsValid(ent) then AINPCS.OpenLiveEditModal(ent) end
    end)

    local inputRow = vgui.Create("DPanel", f)
    inputRow:Dock(BOTTOM)
    inputRow:SetTall(34)
    inputRow:DockMargin(6, 2, 6, 6)
    inputRow.Paint = nil

    local list = vgui.Create("DScrollPanel", f)
    list:Dock(FILL)
    list:DockMargin(6, 2, 6, 4)
    f.chatList = list

    local entry = vgui.Create("DTextEntry", inputRow)
    entry:Dock(FILL)
    entry:DockMargin(0, 0, 6, 0)
    entry:SetPlaceholderText("Type a message and press Enter...")
    entry:RequestFocus()

    local sendBtn = vgui.Create("DButton", inputRow)
    sendBtn:Dock(RIGHT)
    sendBtn:SetWide(84)
    sendBtn:SetText("Send")
    sendBtn:SetTextColor(color_white)
    sendBtn.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, s:IsHovered() and Color(66, 124, 216) or Color(52, 104, 190))
    end

    local function send()
        local msg = AINPCS.Trim(entry:GetValue() or "")
        if msg == "" then return end
        if not IsValid(ent) then
            AINPCS.PushToast("NPC no longer exists.", "error")
            f:Close()
            return
        end
        if recordHistoryLine(idx, "You", msg, Color(130, 200, 255), true) then
            appendChatLineToWidget(f, "You", msg, Color(130, 200, 255))
            noteSelfSend(idx, msg)
        end
        entry:SetText("")

        net.Start("AINPC_ChatRequest")
        net.WriteEntity(ent)
        net.WriteString(msg)
        net.SendToServer()
    end

    sendBtn.DoClick = send
    entry.OnEnter   = send

    -- Replay full persisted conversation history for this NPC
    local hist = AINPCS.ChatHistory[idx] or {}
    for _, item in ipairs(hist) do
        appendChatLineToWidget(f, item.author, item.text, item.color)
    end

    return f
end

-- =============================================================================
-- Chat Reply Handler
-- =============================================================================

-- Replies that are waiting for their voice line to start, keyed by ent index.
-- The server tells us whether a voice is coming; until that channel is actually
-- playing, showing the text would put words in the NPC's mouth before it speaks.
local PendingChat = {}

local function displayChatReply(entry)
    if entry.shown then return end
    entry.shown = true

    local idx, name, text, isErr = entry.idx, entry.name, entry.text, entry.isErr

    AINPCS.LastChat[idx] = {
        text        = text,
        isError     = isErr,
        expires     = RealTime() + 10,
        spokenUntil = isErr and 0 or (RealTime() + math.Clamp(#text / 13.5, 2.5, 9.5)),
    }

    local win = AINPCS.ChatWindows[idx]

    -- Only log the player's line if we did not already append it ourselves
    -- (typing in this window) and it really came from someone else (/say,
    -- proximity chat, another player at the NPC).
    if entry.speakerLine and entry.speakerLine ~= "" and not consumeSelfSend(idx, entry.speakerLine) then
        local ply = LocalPlayer()
        local isLocal = IsValid(ply) and (entry.speakerNick == ply:Nick() or entry.speakerNick == "")
        local authorLabel = isLocal and "You" or entry.speakerNick
        local authorCol = isLocal and Color(130, 200, 255) or Color(170, 220, 255)
        if recordHistoryLine(idx, authorLabel, entry.speakerLine, authorCol, isLocal) and IsValid(win) then
            appendChatLineToWidget(win, authorLabel, entry.speakerLine, authorCol)
        end
    end

    local replyCol = isErr and Color(235, 120, 120) or Color(255, 210, 120)
    if recordHistoryLine(idx, name, text, replyCol, false) and IsValid(win) then
        appendChatLineToWidget(win, name, text, replyCol)
    end

    chat.AddText(replyCol, "[" .. name .. "] ", Color(230, 230, 230), text)
end

net.Receive("AINPC_ChatReply", function()
    local ent         = net.ReadEntity()
    local name        = net.ReadString()
    local text        = net.ReadString()
    local isErr       = net.ReadBool()
    local speakerNick = net.ReadString()
    local speakerLine = net.ReadString()
    local expectsAudio = net.ReadBool()

    local idx = IsValid(ent) and ent:EntIndex() or 0

    local entry = {
        idx         = idx,
        name        = name,
        text        = text,
        isErr       = isErr,
        speakerNick = speakerNick,
        speakerLine = speakerLine,
        -- Never hold a line hostage to a slow/failing voice host.
        deadline    = RealTime() + 4.5,
        shown       = false,
    }

    if expectsAudio and idx > 0 then
        PendingChat[idx] = entry
    else
        displayChatReply(entry)
    end
end)

--- Push any queued replies whose voice has now started (or timed out).
function AINPCS.FlushPendingChat()
    for idx, entry in pairs(PendingChat) do
        if entry.shown or not IsValid(Entity(idx)) then
            if not entry.shown then displayChatReply(entry) end
            PendingChat[idx] = nil
        else
            local voice = Players[idx]
            local started = (voice and voice.snd ~= nil) or (AINPCS.GetVoiceLevel(idx) ~= nil)
            if started or RealTime() >= entry.deadline then
                displayChatReply(entry)
                PendingChat[idx] = nil
            end
        end
    end
end

net.Receive("AINPC_OpenChatUI", function()
    local ent = net.ReadEntity()
    if IsValid(ent) then AINPCS.OpenChatWindow(ent) end
end)

-- =============================================================================
-- 3D Voice Playback Engine (PlayFile for Fish Audio + PlayURL for Keyless TTS)
-- =============================================================================

local cvVoiceVolume = CreateClientConVar("ainpc_voice_volume", "1", true, false,
    "AI NPC voice volume (0-1).", 0, 1)

local warnedVoiceFailure = false
local Players = {}       -- (declared at the top of this file)
local StreamBuffers = {} -- [streamId] = { parts, got, total, ext, ent, t }

local function getHeadPos(ent)
    if not IsValid(ent) then return Vector(0, 0, 0) end
    if ent.LookupBone then
        local bone = ent:LookupBone("ValveBiped.Bip01_Head1")
        if bone then
            local pos = ent:GetBonePosition(bone)
            if pos and pos ~= ent:GetPos() then return pos end
        end
    end
    if ent.EyePos then return ent:EyePos() end
    return ent:GetPos() + Vector(0, 0, 62)
end

local function stopVoice(idx)
    local p = Players[idx]
    if not p then return end
    if p.snd and p.snd.Stop then pcall(p.snd.Stop, p.snd) end
    Players[idx] = nil
end

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

-- Real-time audio amplitude (0..1) for an NPC's active audio channel
function AINPCS.GetVoiceLevel(idx)
    local p = Players[idx]
    if not p or not p.snd or not channelPlaying(p.snd) then return nil end
    if not p.snd.GetLevel then return nil end
    local ok, l, r = pcall(p.snd.GetLevel, p.snd)
    if not ok then return nil end
    return math.Clamp(((l or 0) + (r or 0)) * 1.45, 0, 1)
end

local function voiceError(errId, errName)
    if warnedVoiceFailure then return end
    warnedVoiceFailure = true
    AINPCS.PushToast("Voice playback failed (" .. tostring(errName or errId) .. ").", "error")
    AINPCS.DebugPrint("[AI-NPCs] voice error " .. tostring(errId) .. ": " .. tostring(errName))
end

local function attach3DChannel(idx, ent, snd)
    if not IsValid(ent) or not snd then return end
    local volume = math.Clamp(cvVoiceVolume:GetFloat(), 0, 1)
    if snd.SetPos then snd:SetPos(getHeadPos(ent)) end
    if snd.Set3DFadeDistance then snd:Set3DFadeDistance(220, 1600) end
    if snd.SetVolume then snd:SetVolume(volume) end
    if snd.Play then snd:Play() end
end

-- Streamed binary audio from server (Fish Audio MP3/WAV chunks -> file.Write -> sound.PlayFile)
net.Receive("AINPC_TTSAudio", function()
    local streamId = net.ReadUInt(16)
    local ent      = net.ReadEntity()
    local ext      = net.ReadString()
    local idx      = net.ReadUInt(8)
    local total    = net.ReadUInt(8)
    local len      = net.ReadUInt(16)
    local data     = net.ReadData(len)

    local buf = StreamBuffers[streamId]
    if not buf then
        buf = { parts = {}, got = 0, total = total, ext = ext, ent = ent, t = RealTime() }
        StreamBuffers[streamId] = buf
    end
    if not buf.parts[idx] then
        buf.parts[idx] = data
        buf.got = buf.got + 1
    end
    if buf.got < buf.total then return end
    StreamBuffers[streamId] = nil

    if not IsValid(ent) then return end
    local audioBytes = table.concat(buf.parts)
    if #audioBytes < 128 then return end

    if not file.IsDir("ainpc_tts", "DATA") then
        file.CreateDir("ainpc_tts")
    end
    local safeExt = (ext == "wav") and "wav" or "mp3"
    local relPath = "ainpc_tts/stream_" .. streamId .. "." .. safeExt
    file.Write(relPath, audioBytes)

    local entIdx = ent:EntIndex()
    stopVoice(entIdx)
    local p = {
        voice     = "stream",
        chunks    = {},
        nextIndex = 1,
        snd       = nil,
        pending   = true,
        pendingSince = RealTime(),
        failures  = 0,
    }
    Players[entIdx] = p

    sound.PlayFile("data/" .. relPath, "3d mono noplay", function(snd, errId, errName)
        if Players[entIdx] ~= p then return end
        p.pending = false
        if not snd or not snd.Play then
            stopVoice(entIdx)
            voiceError(errId, errName)
            return
        end
        if not IsValid(ent) then
            stopVoice(entIdx)
            return
        end
        p.snd = snd
        attach3DChannel(entIdx, ent, snd)
    end)

    timer.Simple(35, function()
        if file.Exists(relPath, "DATA") then pcall(file.Delete, relPath) end
    end)
end)

-- Keyless URL TTS (Google / SAPI4) or client-side Fish Audio fallback
net.Receive("AINPC_TTSPlay", function()
    local ent     = net.ReadEntity()
    local voiceId = Voices.NormaliseId(net.ReadString())
    local text    = net.ReadString()

    if not IsValid(ent) then return end
    local entIdx = ent:EntIndex()
    stopVoice(entIdx)

    local fishModelId = Voices.FishModelId(voiceId)
    if fishModelId then
        if AINPCS.Trim(AINPCS.Settings.fishKey or "") ~= "" then
            local p = {
                voice        = voiceId,
                chunks       = {},
                nextIndex    = 1,
                snd          = nil,
                pending      = true,
                pendingSince = RealTime(),
                failures     = 0,
            }
            Players[entIdx] = p
            AINPCS.FishSynthesize(fishModelId, text, function(playPath, err)
                if Players[entIdx] ~= p or not IsValid(ent) then return end
                if not playPath then
                    -- Fall back to built-in voice so NPC is never mute
                    voiceId = AINPCS.Settings.fallbackVoice or Voices.Default
                    p.voice = voiceId
                    p.chunks = Voices.Split(text)
                    p.pending = false
                    return
                end
                sound.PlayFile(playPath, "3d mono noplay", function(snd)
                    if Players[entIdx] ~= p or not IsValid(ent) then return end
                    p.pending = false
                    if snd and snd.Play then
                        p.snd = snd
                        attach3DChannel(entIdx, ent, snd)
                    else
                        stopVoice(entIdx)
                    end
                end)
            end)
            return
        else
            voiceId = AINPCS.Settings.fallbackVoice or Voices.Default
        end
    end

    local chunks = Voices.Split(text)
    if #chunks == 0 then return end

    Players[entIdx] = {
        voice     = voiceId,
        chunks    = chunks,
        nextIndex = 1,
        snd       = nil,
        pending   = false,
        failures  = 0,
    }
end)

-- =============================================================================
-- Mouth Movement (GM:MouthMoveAnimation flexes) & Emotional Facial Expressions
-- =============================================================================

local function getClientFlexId(ent, name)
    ent._ainpcClFlex = ent._ainpcClFlex or {}
    local mdl = ent:GetModel() or ""
    if ent._ainpcClFlexModel ~= mdl then
        ent._ainpcClFlex = {}
        ent._ainpcClFlexModel = mdl
    end
    local id = ent._ainpcClFlex[name]
    if id == nil then
        id = (ent.GetFlexIDByName and ent:GetFlexIDByName(name)) or false
        ent._ainpcClFlex[name] = id
    end
    return id or nil
end

local function updateNPCMouthAndFace(ent)
    if not IsValid(ent) then return end
    local idx = ent:EntIndex()
    local now = CurTime()
    local ft  = FrameTime()

    local level = AINPCS.GetVoiceLevel(idx)
    local speaking = (level ~= nil) or (ent:GetNWFloat("AINPCSpeakingUntil", 0) > now)
    local jaw = 0

    if level then
        jaw = math.Clamp(level * 1.15, 0, 1.2)
    elseif speaking then
        local t = now * 12 + idx
        jaw = math.Clamp(math.abs(math.sin(t)) * 0.55 + math.abs(math.sin(t * 1.73)) * 0.30, 0, 1)
    end

    -- Smooth jaw interpolation so mouth movement looks natural
    ent._ainpcJawWeight = math.Approach(ent._ainpcJawWeight or 0, jaw, ft * 10)
    local smoothJaw = ent._ainpcJawWeight

    if ent.GetFlexNum and ent:GetFlexNum() > 0 then
        ent._ainpcClFace = ent._ainpcClFace or {}
        local face = ent._ainpcClFace
        local mood = ent:GetNWString("AINPCMood", "neutral")
        local targetExpr = AINPCS.Expressions[mood] or {}

        for name, w in pairs(face) do
            if not targetExpr[name] then
                face[name] = math.Approach(w, 0, ft * 2.5)
                if face[name] <= 0.001 then
                    local fid = getClientFlexId(ent, name)
                    if fid then ent:SetFlexWeight(fid, 0) end
                    face[name] = nil
                end
            end
        end
        for name, targetW in pairs(targetExpr) do
            face[name] = math.Approach(face[name] or 0, targetW, ft * 2.5)
        end

        for name, w in pairs(face) do
            local fid = getClientFlexId(ent, name)
            if fid then
                if name == "jaw_drop" then w = math.max(w, smoothJaw) end
                ent:SetFlexWeight(fid, w)
            end
        end

        -- Apply GM:MouthMoveAnimation flexes (jaw_drop, left_part, right_part, left_mouth_drop, right_mouth_drop)
        for _, mf in ipairs(AINPCS.MouthFlexes) do
            local fid = getClientFlexId(ent, mf.name)
            if fid then
                local baseW = face[mf.name] or 0
                ent:SetFlexWeight(fid, math.max(baseW, smoothJaw * mf.scale))
            end
        end
    end

    -- Also drive "mouth" pose parameter for models that use pose parameters instead of flexes
    if ent.LookupPoseParameter and ent.SetPoseParameter then
        local pp = ent:LookupPoseParameter("mouth")
        if pp and pp >= 0 then
            ent:SetPoseParameter("mouth", smoothJaw * 60)
        end
    end
end

-- Advance voice queues, keep 3D audio glued to the NPC's head, and animate mouth/face
hook.Add("Think", "AINPC_VoiceAndMouthEngine", function()
    local volume = math.Clamp(cvVoiceVolume:GetFloat(), 0, 1)

    for idx, p in pairs(Players) do
        local ent = Entity(idx)

        if not IsValid(ent) then
            stopVoice(idx)
        elseif p.pending then
            if RealTime() - (p.pendingSince or 0) > 10 then
                p.pending = false
                p.failures = (p.failures or 0) + 1
                if p.failures >= 3 then stopVoice(idx) end
            end
        elseif channelPlaying(p.snd) then
            if p.snd.SetPos then p.snd:SetPos(getHeadPos(ent)) end
            if p.snd.SetVolume then p.snd:SetVolume(volume) end
        else
            p.snd = nil
            local chunk = p.chunks and p.chunks[p.nextIndex]

            if not chunk then
                stopVoice(idx)
            else
                p.nextIndex = p.nextIndex + 1
                local url = Voices.BuildURL(p.voice, chunk)

                if url then
                    p.pending = true
                    p.pendingSince = RealTime()
                    local npc = ent

                    sound.PlayURL(url, "3d mono", function(snd, errId, errName)
                        if Players[idx] ~= p then return end
                        p.pending = false

                        if not snd or not snd.SetPos then
                            p.failures = (p.failures or 0) + 1
                            voiceError(errId, errName)
                            if p.failures >= 3 then stopVoice(idx) end
                            return
                        end

                        if not IsValid(npc) then
                            p.pending = false
                            return
                        end

                        p.snd = snd
                        attach3DChannel(idx, npc, snd)
                    end)
                else
                    p.failures = (p.failures or 0) + 1
                    if p.failures >= 3 then stopVoice(idx) end
                end
            end
        end
    end

    -- Reveal queued replies whose voice has now started playing.
    AINPCS.FlushPendingChat()

    -- Update facial expressions & mouth flexes on all active AI NPCs
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:GetNWBool("IsAINPC", false) then
            updateNPCMouthAndFace(ent)
            -- Hook RenderOverride once so flex weights are applied right before DrawModel()
            if not ent._ainpcRenderHooked then
                ent._ainpcRenderHooked = true
                ent.RenderOverride = function(self)
                    updateNPCMouthAndFace(self)
                    self:DrawModel()
                end
            end
        end
    end
end)

hook.Add("EntityRemoved", "AINPC_VoiceRemoved", function(ent)
    if not IsValid(ent) then return end
    local idx = ent:EntIndex()
    stopVoice(idx)
    PendingChat[idx] = nil
    AINPCS.LastChat[idx] = nil
end)

-- Used by the "Preview selected voice" button in the config panel.
function AINPCS.PreviewVoice(voiceId, sample)
    voiceId = Voices.NormaliseId(voiceId or Voices.Default)
    local text = sample or "Hello! This is what I sound like."

    local fishModelId = Voices.FishModelId(voiceId)
    if fishModelId then
        AINPCS.FishSynthesize(fishModelId, text, function(playPath, err)
            if not playPath then
                AINPCS.PushToast(err or "Fish Audio preview failed.", "error")
                return
            end
            sound.PlayFile(playPath, "mono", function(snd, errId, errName)
                if not IsValid(snd) then
                    voiceError(errId, errName)
                    return
                end
                snd:SetVolume(math.Clamp(cvVoiceVolume:GetFloat(), 0, 1))
                snd:Play()
            end)
        end)
        return true
    end

    local url = Voices.BuildURL(voiceId, text)
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
-- Spawn result
-- =============================================================================

net.Receive("AINPC_SpawnResult", function()
    local ok = net.ReadBool()
    local ent = net.ReadEntity()
    local name = net.ReadString()
    if ok and IsValid(ent) then
        -- Entity indices get recycled. A fresh spawn must not inherit the
        -- previous occupant's name, transcript, or voice queue.
        local idx = ent:EntIndex()
        AINPCS.ChatHistory[idx] = nil
        AINPCS.LastChat[idx] = nil
        AINPCS.SelfSends[idx] = nil
        PendingChat[idx] = nil
        stopVoice(idx)
        local win = AINPCS.ChatWindows[idx]
        if IsValid(win) then win:Close() end

        -- No toast here: the server already sends AINPC_Toast for the spawn, and
        -- raising one in both places showed the same notification twice.
        AINPCS.DebugPrint("[AI-NPCs] spawned " .. tostring(name))
    end
end)
