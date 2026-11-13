--[[
    AI NPCs — panel

    Three pages, no wall of settings:

      Library   saved characters, one click to spawn
      Create    a guided 4-step maker (identity -> voice -> body -> behaviour)
      Settings  provider, model, API keys, voice service, volume

    LLM choices live in Settings only, so making an NPC never asks you to think
    about tokens, temperatures or model ids.
]]

AINPCS = AINPCS or {}

local providers = AINPCS.Providers
local Voices    = AINPCS.Voices
local C         = AINPCS.Colors

local FRAME_W, FRAME_H = 1040, 700

local function voiceLabel(id)
    if not id or id == "" then return "no voice" end
    local v = Voices.Get(id)
    if v then return v.label end
    return id
end

local function classLabel(id)
    local reg = list.Get("NPC") or {}
    local data = reg[id]
    return (data and data.Name) or id or "?"
end

local function stack(parent)
    local l = vgui.Create("DListLayout", parent)
    l:Dock(FILL)
    l:DockPadding(14, 12, 14, 12)
    return l
end

local function row(list, height)
    local p = vgui.Create("DPanel")
    p:SetTall(height or 26)
    p.Paint = nil
    list:Add(p)
    return p
end

local function label(list, text, font, color, height, wrap)
    local l = vgui.Create("DLabel")
    l:SetFont(font or "AINPC_Body")
    l:SetTextColor(color or C.text)
    l:SetText(text)
    l:SetTall(height or 20)
    if wrap then l:SetWrap(true) l:SetAutoStretchVertical(false) end
    list:Add(l)
    return l
end

local function button(list, text, height, onClick, color)
    local b = vgui.Create("DButton")
    b:SetTall(height or 28)
    b:SetText(text)
    b:SetFont("AINPC_Body")
    b:SetTextColor(color or C.text)
    function b:Paint(w, h)
        local hover = self:IsHovered()
        draw.RoundedBox(6, 0, 0, w, h, hover and Color(70, 70, 82) or Color(52, 52, 60))
        if color == C.accent then draw.RoundedBox(6, 0, 0, w, h, Color(60, 110, 190, hover and 255 or 210)) end
    end
    if onClick then b.DoClick = onClick end
    list:Add(b)
    return b
end

local function entry(list, placeholder, height)
    local e = vgui.Create("DTextEntry")
    e:SetTall(height or 30)
    e:SetPlaceholderText(placeholder or "")
    list:Add(e)
    return e
end

local function combo(list, height)
    local cb = vgui.Create("DComboBox")
    cb:SetTall(height or 30)
    list:Add(cb)
    return cb
end

local function spacer(list, h)
    local p = vgui.Create("DPanel")
    p:SetTall(h or 8)
    p.Paint = nil
    list:Add(p)
    return p
end

-- =============================================================================
-- Wizard draft
-- =============================================================================

local function newDraft()
    return {
        id          = nil,
        name        = "",
        description = "",
        voiceId     = "",
        class       = "npc_citizen",
        reasoning   = "none",
        speak       = true,
    }
end

local draft = newDraft()

-- =============================================================================
-- Frame
-- =============================================================================

function AINPCS.Open()
    if IsValid(AINPCS.Panel) then
        AINPCS.Panel:MakePopup()
        return AINPCS.Panel
    end

    local frame = vgui.Create("DFrame")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:Center()
    frame:SetTitle("")
    frame:ShowCloseButton(true)
    frame:MakePopup()
    frame:SetDraggable(true)
    AINPCS.Panel = frame

    frame.Paint = function(s, w, h)
        draw.RoundedBox(0, 0, 0, w, h, Color(24, 24, 28))
        surface.SetDrawColor(38, 38, 44)
        surface.DrawRect(0, 0, w, 52)
        draw.SimpleText("AI NPCs", "AINPC_Title", 18, 14, C.text)
        draw.SimpleText("v" .. (AINPCS.Version or "?"), "AINPC_Small", 18, 40, C.sub)
    end

    -- voice service pill in the header
    local pill = vgui.Create("DLabel", frame)
    pill:SetFont("AINPC_Small")
    pill:SetTextColor(C.sub)
    pill:SetText("voice service: checking...")
    pill:SetPos(FRAME_W - 470, 20)
    pill:SetSize(340, 18)

    local pillRefresh = vgui.Create("DButton", frame)
    pillRefresh:SetText("refresh")
    pillRefresh:SetFont("AINPC_Tiny")
    pillRefresh:SetSize(64, 20)
    pillRefresh:SetPos(FRAME_W - 120, 18)
    pillRefresh.DoClick = function() AINPCS.RefreshServicePill(pill) end

    function AINPCS.RefreshServicePill(target)
        target = target or pill
        if not IsValid(target) then return end
        AINPCS.RelayHealth(function(info)
            if not info then
                target:SetTextColor(C.bad)
                target:SetText("voice service: NOT running (relay/start.bat)")
            elseif info.key_set then
                target:SetTextColor(C.good)
                target:SetText(string.format("voice service: ready   credit %s",
                    type(info.credits) == "number" and string.format("%.2f", info.credits) or "?"))
            else
                target:SetTextColor(C.warn)
                target:SetText("voice service: running, no key (Settings)")
            end
        end)
    end

    -- ---- tabs ----
    local sheet = vgui.Create("DPropertySheet", frame)
    sheet:Dock(FILL)
    sheet:DockMargin(10, 56, 10, 10)
    sheet.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(28, 28, 33))
    end

    local libraryPage = vgui.Create("DPanel")
    libraryPage.Paint = function(s, w, h) surface.SetDrawColor(28, 28, 33) surface.DrawRect(0, 0, w, h) end

    local createPage = vgui.Create("DPanel")
    createPage.Paint = function(s, w, h) surface.SetDrawColor(28, 28, 33) surface.DrawRect(0, 0, w, h) end

    local settingsPage = vgui.Create("DPanel")
    settingsPage.Paint = function(s, w, h) surface.SetDrawColor(28, 28, 33) surface.DrawRect(0, 0, w, h) end

    sheet:AddSheet("Library", libraryPage, "icon16/user.png")
    sheet:AddSheet("Create",  createPage,  "icon16/add.png")
    sheet:AddSheet("Settings", settingsPage, "icon16/wrench.png")

    AINPCS.RefreshServicePill(pill)

    -- =========================================================================
    -- Library page
    -- =========================================================================

    local libraryList = vgui.Create("DScrollPanel", libraryPage)
    libraryList:Dock(FILL)
    libraryList:DockMargin(8, 8, 8, 8)

    local libraryCards = vgui.Create("DListLayout")
    function libraryCards:Paint(w, h) end
    libraryList:AddItem(libraryCards)

    local newBtn = vgui.Create("DButton", libraryPage)
    newBtn:Dock(BOTTOM)
    newBtn:DockMargin(8, 0, 8, 8)
    newBtn:SetTall(34)
    newBtn:SetText("+  New character")
    newBtn.DoClick = function()
        draft = newDraft()
        AINPCS.RebuildWizard(1)
        sheet:SwitchToSheet(createPage)
    end

    local function card(entry)
        local c = vgui.Create("DPanel")
        c:SetTall(74)
        c:DockMargin(0, 0, 0, 8)
        c.Paint = function(s, w, h)
            draw.RoundedBox(8, 0, 0, w, h, C.card)
            draw.RoundedBox(8, 0, 0, 4, h, C.accent)
        end

        local title = vgui.Create("DLabel", c)
        title:SetFont("AINPC_Header")
        title:SetTextColor(C.text)
        title:SetText(entry.name)
        title:SetPos(16, 8)
        title:SetSize(420, 26)

        local info = vgui.Create("DLabel", c)
        info:SetFont("AINPC_Small")
        info:SetTextColor(C.sub)
        info:SetText(string.format("%s   •   %s   •   %s",
            voiceLabel(entry.voiceId), classLabel(entry.class),
            entry.reasoning == "none" and "instant replies" or ("thinking: " .. tostring(entry.reasoning))))
        info:SetPos(16, 36)
        info:SetSize(560, 20)

        local spawn = vgui.Create("DButton", c)
        spawn:SetText("Spawn")
        spawn:SetFont("AINPC_Body")
        spawn:Dock(RIGHT)
        spawn:DockMargin(0, 8, 8, 8)
        spawn:SetWide(90)
        spawn.DoClick = function()
            AINPCS.Spawn(entry)
            AINPCS.PushToast("Spawning " .. entry.name .. "...", "success")
        end

        local edit = vgui.Create("DButton", c)
        edit:SetText("Edit")
        edit:SetFont("AINPC_Body")
        edit:Dock(RIGHT)
        edit:DockMargin(0, 8, 8, 8)
        edit:SetWide(70)
        edit.DoClick = function()
            draft = table.Copy(entry)
            AINPCS.RebuildWizard(1)
            sheet:SwitchToSheet(createPage)
        end

        local del = vgui.Create("DButton", c)
        del:SetText("x")
        del:SetFont("AINPC_Body")
        del:Dock(RIGHT)
        del:DockMargin(0, 8, 8, 8)
        del:SetWide(28)
        del.DoClick = function()
            AINPCS.RemoveLibraryEntry(entry.id)
            AINPCS.RebuildLibrary()
        end

        libraryCards:Add(c)
        return c
    end

    function AINPCS.RebuildLibrary()
        libraryCards:Clear()

        if #AINPCS.Library == 0 then
            local empty = vgui.Create("DLabel")
            empty:SetFont("AINPC_Body")
            empty:SetTextColor(C.sub)
            empty:SetText("No saved characters yet.  Click '+ New character' to make one.")
            empty:SetTall(40)
            libraryCards:Add(empty)
            return
        end

        for _, entry in ipairs(AINPCS.Library) do
            card(entry)
        end
    end

    -- =========================================================================
    -- Create page (wizard)
    -- =========================================================================

    local stepBar = vgui.Create("DPanel", createPage)
    stepBar:Dock(TOP)
    stepBar:SetTall(48)
    stepBar.Paint = function(s, w, h)
        surface.SetDrawColor(32, 32, 38)
        surface.DrawRect(0, 0, w, h)
    end

    local stepLabels = {}
    local STEP_NAMES = { "1  Identity", "2  Voice", "3  Body", "4  Behaviour", "5  Review" }
    for i, name in ipairs(STEP_NAMES) do
        local l = vgui.Create("DLabel", stepBar)
        l:SetFont("AINPC_Body")
        l:SetText(name)
        l:SetSize(150, 20)
        l:SetPos(16 + (i - 1) * 150, 14)
        stepLabels[i] = l
    end

    local nav = vgui.Create("DPanel", createPage)
    nav:Dock(BOTTOM)
    nav:SetTall(52)
    nav.Paint = function(s, w, h)
        surface.SetDrawColor(32, 32, 38)
        surface.DrawRect(0, 0, w, h)
    end

    local backBtn = vgui.Create("DButton", nav)
    backBtn:SetText("Back")
    backBtn:SetSize(100, 34)
    backBtn:SetPos(12, 9)

    local nextBtn = vgui.Create("DButton", nav)
    nextBtn:SetText("Next")
    nextBtn:SetSize(160, 34)
    nextBtn:Dock(RIGHT)
    nextBtn:DockMargin(0, 9, 12, 9)

    local stepHost = vgui.Create("DPanel", createPage)
    stepHost:Dock(FILL)
    stepHost.Paint = nil

    local currentStep = 1

    local function clearStepHost()
        for _, child in ipairs(stepHost:GetChildren()) do child:Remove() end
    end

    local function setStep(n)
        currentStep = math.Clamp(n, 1, 5)
        for i, l in ipairs(stepLabels) do
            l:SetTextColor(i == currentStep and C.accent or C.sub)
        end

        backBtn:SetVisible(currentStep > 1)
        nextBtn:SetText(currentStep == 5 and "Save & spawn" or "Next")
        AINPCS.BuildStep(currentStep)
    end

    AINPCS.BuildStep = function(n)
        clearStepHost()
        local list = stack(stepHost)

        if n == 1 then
            label(list, "Who is this NPC?", "AINPC_Header", C.text, 30)
            label(list, "The name is enough - if it is a known character the AI already knows how they talk.",
                "AINPC_Small", C.sub, 34, true)
            spacer(list, 6)

            label(list, "Name", "AINPC_Small", C.sub, 18)
            local nameE = entry(list, "e.g. Rick Sanchez", 32)
            nameE:SetText(draft.name or "")
            nameE.OnValueChange = function(_, v) draft.name = v end

            spacer(list, 6)
            label(list, "Description (optional)", "AINPC_Small", C.sub, 18)
            local descE = vgui.Create("DTextEntry")
            descE:SetMultiline(true)
            descE:SetTall(110)
            descE:SetPlaceholderText("Leave blank for a character from a game/film. Add notes for an original one.")
            descE:SetText(draft.description or "")
            descE.OnValueChange = function(_, v) draft.description = v end
            list:Add(descE)

        elseif n == 2 then
            label(list, "How should they sound?", "AINPC_Header", C.text, 30)
            label(list, "Searches your voice service (Fish Audio). Character voices need credit on your account.",
                "AINPC_Small", C.sub, 34, true)
            spacer(list, 4)

            local searchRow = row(list, 34)
            local searchE = vgui.Create("DTextEntry", searchRow)
            searchE:Dock(FILL)
            searchE:SetPlaceholderText("rick sanchez")

            local searchBtn = vgui.Create("DButton", searchRow)
            searchBtn:Dock(RIGHT)
            searchBtn:SetWide(110)
            searchBtn:SetText("Search")
            searchBtn:DockMargin(8, 0, 0, 0)

            local results = vgui.Create("DListView")
            results:SetTall(260)
            results:AddColumn("Voice")
            list:Add(results)

            spacer(list, 4)
            local statusLbl = label(list, "", "AINPC_Small", C.sub, 18)
            local previewBtn = button(list, "Preview selected voice", 28, function()
                local _, _, line = results:GetSelectedLine()
                local voiceId = line and line.voiceId
                if not voiceId then return end
                AINPCS.PreviewVoice(voiceId, "Hello, I am " .. (draft.name ~= "" and draft.name or "an NPC") .. ".")
            end)

            local function fill(voices)
                results:Clear()
                for _, v in ipairs(voices) do
                    local l = results:AddLine(v.label)
                    l.voiceId = "relay:" .. v.name
                    if draft.voiceId == l.voiceId then
                        results:SelectItem(l)
                    end
                end
                statusLbl:SetText(#voices == 0 and "no matches - is the voice service running?" or (#voices .. " matches"))
            end

            function results.OnRowSelected(_, _, line)
                draft.voiceId = line.voiceId
            end

            local function doSearch()
                statusLbl:SetText("searching...")
                AINPCS.RelayVoices(AINPCS.Trim(searchE:GetValue() or ""), fill)
            end

            searchBtn.DoClick = doSearch
            searchE.OnEnter = doSearch
            doSearch()

        elseif n == 3 then
            label(list, "What should they look like?", "AINPC_Header", C.text, 30)

            local bodyRow = row(list, 300)

            local bodyList = vgui.Create("DListView", bodyRow)
            bodyList:Dock(LEFT)
            bodyList:SetWide(420)
            bodyList:AddColumn("Body")

            local preview = vgui.Create("DModelPanel", bodyRow)
            preview:Dock(FILL)
            preview:DockMargin(10, 0, 0, 0)
            preview:SetModel("models/humans/group01/male_07.mdl")
            preview.LayoutEntity = function(self, ent)
                self:RunAnimation()
                ent:SetAngles(Angle(0, RealTime() * 60, 0))
            end

            local reg = list.Get("NPC") or {}
            local ids = {}
            for id in pairs(reg) do table.insert(ids, id) end
            table.sort(ids)

            for _, id in ipairs(ids) do
                local data = reg[id]
                local line = bodyList:AddLine((data and data.Name) or id)
                line.classId = id
                if id == draft.class then bodyList:SelectItem(line) end
            end

            function bodyList.OnRowSelected(_, _, line)
                draft.class = line.classId
                local data = reg[line.classId]
                if data and data.Model then preview:SetModel(data.Model) end
            end

        elseif n == 4 then
            label(list, "How should they answer?", "AINPC_Header", C.text, 30)
            label(list, "Off answers instantly. Thinking gives more deliberate replies but adds a pause.",
                "AINPC_Small", C.sub, 34, true)
            spacer(list, 6)

            label(list, "Reply speed", "AINPC_Small", C.sub, 18)
            local speed = combo(list)
            speed:AddChoice("Instant (no reasoning)", "none", draft.reasoning == "none")
            speed:AddChoice("A little thinking", "low", draft.reasoning == "low")
            speed:AddChoice("Balanced", "medium", draft.reasoning == "medium")
            function speed.OnSelect(_, _, value) draft.reasoning = value end

            spacer(list, 10)
            label(list, "Voice", "AINPC_Small", C.sub, 18)
            local speak = vgui.Create("DCheckBoxLabel")
            speak:SetText("Speak out loud")
            speak:SetValue(draft.speak ~= false)
            speak:SetTall(24)
            speak.OnChange = function(_, v) draft.speak = v end
            list:Add(speak)

        else
            label(list, "Ready to save", "AINPC_Header", C.text, 30)
            spacer(list, 4)

            local summary = {
                { "Name", draft.name ~= "" and draft.name or "(none)" },
                { "Voice", voiceLabel(draft.voiceId) },
                { "Body", classLabel(draft.class) },
                { "Replies", draft.reasoning == "none" and "instant" or draft.reasoning },
                { "Speaks", draft.speak and "yes" or "no" },
                { "Description", (draft.description ~= "" and draft.description) or "from the name" },
            }
            for _, pair in ipairs(summary) do
                local r = row(list, 22)
                local k = vgui.Create("DLabel", r)
                k:Dock(LEFT)
                k:SetWide(120)
                k:SetFont("AINPC_Small")
                k:SetTextColor(C.sub)
                k:SetText(pair[1])

                local v = vgui.Create("DLabel", r)
                v:Dock(FILL)
                v:SetFont("AINPC_Body")
                v:SetTextColor(C.text)
                v:SetText(pair[2])
            end

            spacer(list, 8)
            local saveOnly = button(list, "Save to library", 34, function()
                AINPCS.SaveDraft()
                AINPCS.RebuildLibrary()
                sheet:SwitchToSheet(libraryPage)
                AINPCS.PushToast(draft.name .. " saved.", "success")
            end)

            local saveSpawn = button(list, "Save & spawn now", 34, function()
                AINPCS.SaveDraft()
                AINPCS.RebuildLibrary()
                AINPCS.Spawn(draft)
            end)
            saveSpawn:SetTextColor(C.text)
        end
    end

    AINPCS.SaveDraft = function()
        if AINPCS.IsBlank(draft.name or "") then
            draft.name = "NPC"
        end
        if draft.voiceId == "" then
            draft.voiceId = AINPCS.Settings.fallbackVoice
        end
        local saved = AINPCS.UpsertLibraryEntry(table.Copy(draft))
        draft.id = saved.id
    end

    backBtn.DoClick = function() setStep(currentStep - 1) end
    nextBtn.DoClick = function()
        if currentStep == 5 then
            AINPCS.SaveDraft()
            AINPCS.RebuildLibrary()
            AINPCS.Spawn(draft)
            return
        end
        if currentStep == 1 and AINPCS.IsBlank(draft.name or "") then
            AINPCS.PushToast("Give the NPC a name first.", "info")
            return
        end
        setStep(currentStep + 1)
    end

    AINPCS.RebuildWizard = function(step) setStep(step or 1) end

    -- =========================================================================
    -- Settings page
    -- =========================================================================

    local settingsScroll = vgui.Create("DScrollPanel", settingsPage)
    settingsScroll:Dock(FILL)
    settingsScroll:DockMargin(8, 8, 8, 8)

    local sl = vgui.Create("DListLayout")
    settingsScroll:AddItem(sl)

    local S = AINPCS.Settings
    if not istable(S.apiKeys) then S.apiKeys = {} end

    local function persist() AINPCS.SaveSettings() end

    -- provider
    label(sl, "AI provider", "AINPC_Header", C.text, 28)
    label(sl, "Used for every NPC you spawn. You only set this once.",
        "AINPC_Small", C.sub, 30, true)
    local provCombo = combo(sl)
    for _, p in ipairs(providers.list()) do
        provCombo:AddChoice(p.label, p.id, p.id == S.provider)
    end

    -- model
    spacer(sl, 10)
    label(sl, "Model", "AINPC_Header", C.text, 28)
    local freeChk = vgui.Create("DCheckBoxLabel")
    freeChk:SetText("Free models only")
    freeChk:SetValue(S.freeOnly ~= false)
    freeChk:SetTall(24)
    freeChk.OnChange = function(_, v) S.freeOnly = v persist() AINPCS.BuildModelCombo() end
    sl:Add(freeChk)

    local modelCombo = combo(sl)
    local modelNote = label(sl, "", "AINPC_Small", C.sub, 18)

    function AINPCS.BuildModelCombo()
        modelCombo:Clear()
        local order, models = AINPCS.ModelList(S.provider)
        local shown = 0
        local picked = false
        for _, id in ipairs(order or {}) do
            local m = models[id]
            if m then
                local isFree = (m.free ~= false)
                if S.provider ~= "openrouter" or not S.freeOnly or isFree then
                    modelCombo:AddChoice(m.label or id, id, id == S.model)
                    shown = shown + 1
                    if id == S.model then picked = true end
                end
            end
        end

        if not picked and shown > 0 then
            local p = providers.get(S.provider)
            local preferred = p and p.defaultModel
            local order2 = order or {}
            S.model = (preferred and models[preferred]) and preferred or order2[1]
            modelCombo:ChooseOption(modelCombo:GetOptionText(1))
        end
        modelNote:SetText(shown == 0 and "no models - pick another provider" or (shown .. " models"))

        if S.provider == "openrouter" and not AINPCS.LiveOpenRouter then
            AINPCS.RequestModels()
        end
    end

    function modelCombo.OnSelect(_, _, id)
        S.model = id
        persist()
    end

    function provCombo.OnSelect(_, _, id)
        S.provider = id
        S.model = ""
        persist()
        AINPCS.BuildModelCombo()
        AINPCS.RebuildSettings()
    end

    -- api key
    spacer(sl, 10)
    label(sl, "API key for " .. "the selected provider", "AINPC_Header", C.text, 28)
    local keyRow = row(sl, 32)
    local keyE = vgui.Create("DTextEntry", keyRow)
    keyE:Dock(FILL)
    keyE:SetPlaceholderText("paste your key here")
    keyE:SetText(S.apiKeys[S.provider] or "")
    keyE.OnValueChange = function(_, v)
        S.apiKeys[S.provider] = AINPCS.Trim(v)
        persist()
    end

    local hostRow = row(sl, 32)
    local hostE = vgui.Create("DTextEntry", hostRow)
    hostE:Dock(FILL)
    hostE:SetPlaceholderText("Ollama hostname (only needed for Ollama), e.g. 127.0.0.1:11434")
    hostE:SetText(S.hostname or "")
    hostE.OnValueChange = function(_, v) S.hostname = AINPCS.Trim(v) persist() end

    local keyHint = label(sl, "", "AINPC_Small", C.sub, 30)
    function AINPCS.RebuildSettings()
        local p = providers.get(S.provider)
        keyE:SetText(S.apiKeys[S.provider] or "")
        keyHint:SetText((p and p.note or "") .. "   Get a key: " .. ((p and p.getKeyUrl) or ""))
        if p and p.requiresHostname then
            hostE:SetVisible(true)
            hostE:SetText(S.hostname or "")
        else
            hostE:SetVisible(p and p.id == "ollama")
        end
    end

    -- voice service
    spacer(sl, 12)
    label(sl, "Voice service (Fish Audio)", "AINPC_Header", C.text, 28)
    label(sl, "Character voices need a local helper with your own Fish key. Start it with relay/start.bat.",
        "AINPC_Small", C.sub, 30, true)

    local serviceStatus = label(sl, "checking...", "AINPC_Small", C.sub, 20)

    local fishRow = row(sl, 32)
    local fishE = vgui.Create("DTextEntry", fishRow)
    fishE:Dock(FILL)
    fishE:SetPlaceholderText("Fish Audio API key (sk-fish-...)")
    local fishSave = vgui.Create("DButton", fishRow)
    fishSave:Dock(RIGHT)
    fishSave:SetWide(90)
    fishSave:SetText("Save")
    fishSave:DockMargin(8, 0, 0, 0)
    fishSave.DoClick = function()
        local key = AINPCS.Trim(fishE:GetValue() or "")
        if key == "" then return end
        fishSave:SetText("...")
        AINPCS.RelaySaveKey(key, function(ok, code, body)
            fishSave:SetText("Save")
            AINPCS.PushToast(ok and "Fish key saved." or ("Rejected: " .. tostring((istable(body) and body.error) or code)),
                ok and "success" or "error")
            AINPCS.RefreshServicePill()
            AINPCS.RefreshSettingsService()
        end)
    end

    local fishOpen = button(sl, "Open voice library / pin voices", 26, function()
        gui.OpenURL(AINPCS.RelayBase() .. "/")
    end)

    function AINPCS.RefreshSettingsService()
        AINPCS.RelayHealth(function(info)
            if not info then
                serviceStatus:SetTextColor(C.bad)
                serviceStatus:SetText("NOT running - double-click relay/start.bat")
            elseif info.key_set then
                serviceStatus:SetTextColor(C.good)
                serviceStatus:SetText(string.format("Running - key set - credit %s",
                    type(info.credits) == "number" and string.format("%.2f", info.credits) or "?"))
            else
                serviceStatus:SetTextColor(C.warn)
                serviceStatus:SetText("Running - no key yet, paste one above")
            end
        end)
    end

    -- fallback voice for when the service is down
    spacer(sl, 12)
    label(sl, "Fallback voice", "AINPC_Header", C.text, 28)
    label(sl, "Used when an NPC has no character voice. These need no account.",
        "AINPC_Small", C.sub, 26, true)
    local fbCombo = combo(sl)
    for _, v in ipairs(Voices.list) do
        if not string.match(v.id, "^relay:") then
            fbCombo:AddChoice(v.label, v.id, v.id == S.fallbackVoice)
        end
    end
    function fbCombo.OnSelect(_, _, id) S.fallbackVoice = id persist() end

    -- volume
    spacer(sl, 12)
    label(sl, "Voice volume", "AINPC_Header", C.text, 28)
    local vol = vgui.Create("DNumSlider")
    vol:SetTall(40)
    vol:SetText("")
    vol:SetMin(0) vol:SetMax(1) vol:SetDecimals(2)
    vol:SetValue(GetConVar("ainpc_voice_volume") and GetConVar("ainpc_voice_volume"):GetFloat() or 1)
    vol.OnValueChanged = function(_, v)
        local cv = GetConVar("ainpc_voice_volume")
        if cv then RunConsoleCommand("ainpc_voice_volume", tostring(v)) end
    end
    sl:Add(vol)

    -- wire model list changes
    AINPCS.OnModelsChanged = function()
        if IsValid(modelCombo) then AINPCS.BuildModelCombo() end
    end

    AINPCS.BuildModelCombo()
    AINPCS.RebuildSettings()
    AINPCS.RefreshSettingsService()

    -- initial pages
    AINPCS.RebuildLibrary()
    setStep(1)

    return frame
end

concommand.Add("ainpc_open", function() AINPCS.Open() end)

list.Set("DesktopWindows", "ai_npcs_menu", {
    title = "AI NPCs",
    icon  = "materials/gptlogo/ChatGPT_logo.svg.png",
    init  = function() AINPCS.Open() end,
})
