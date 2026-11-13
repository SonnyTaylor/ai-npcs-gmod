--[[
    AI NPCs — panel (v3.1)

    Three pages behind a custom tab strip:

      Library   saved characters, one click to spawn
      Create    guided 4-step maker
      Settings  provider, model, keys, voice service, volume

    Layout rules that keep this from collapsing the way v3.0 did:
      * scrolling pages get a DScrollPanel + DListLayout docked TOP (a DListLayout
        with no width lays its children out in a 110px column)
      * controls live inside fixed-height rows and are capped to CONTENT_W so the
        eye does not have to track a 1000px line
      * nothing relies on a docked panel inventing its own height
]]

AINPCS = AINPCS or {}

local providers = AINPCS.Providers
local Voices    = AINPCS.Voices
local C         = AINPCS.Colors

local FRAME_W, FRAME_H = 1040, 700
local CONTENT_W = 620

local function voiceLabel(id)
    if not id or id == "" then return "no voice" end
    local v = Voices.Get(id)
    return v and v.label or id
end

local function classLabel(id)
    local reg = list.Get("NPC") or {}
    local data = reg[id]
    return (data and data.Name) or id or "?"
end

local function divider(list)
    local d = vgui.Create("DPanel")
    d:SetTall(1)
    d.Paint = function(s, w, h)
        surface.SetDrawColor(255, 255, 255, 12)
        surface.DrawRect(0, 0, w, h)
    end
    list:Add(d)
    return d
end

local function gap(list, h)
    local p = vgui.Create("DPanel")
    p:SetTall(h or 8)
    p.Paint = nil
    list:Add(p)
    return p
end

-- A fixed-height row: the control inside is capped to CONTENT_W and left aligned.
local function field(list, height)
    local r = vgui.Create("DPanel")
    r:SetTall(height or 32)
    r.Paint = nil
    list:Add(r)
    return r
end

local function text(list, str, font, color, height, wrap)
    local l = vgui.Create("DLabel")
    l:SetFont(font or "AINPC_Body")
    l:SetTextColor(color or C.text)
    l:SetText(str)
    l:SetTall(height or 22)
    if wrap then
        l:SetWrap(true)
        l:SetAutoStretchVertical(false)
    end
    list:Add(l)
    return l
end

local function heading(list, str, sub)
    text(list, str, "AINPC_Header", C.text, 28)
    if sub then text(list, sub, "AINPC_Small", C.sub, 34, true) end
end

local function styledButton(parent, label_, kind)
    local b = vgui.Create("DButton", parent)
    b:SetText("")
    b:SetFont("AINPC_Body")

    local palette = {
        primary = { base = Color(52, 104, 190), hover = Color(66, 124, 216) },
        ghost   = { base = Color(48, 48, 56),  hover = Color(64, 64, 74) },
        danger  = { base = Color(120, 46, 46), hover = Color(150, 58, 58) },
    }
    local p = palette[kind or "ghost"]

    b._label = label_
    b.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, s:IsHovered() and p.hover or p.base)
        draw.SimpleText(s._label or "", "AINPC_Body", w / 2, h / 2, C.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    function b:SetLabel(t) self._label = t end
    return b
end

local function addButton(list, label_, kind, onClick, width, height)
    local r = field(list, (height or 32) + 4)
    local b = styledButton(r, label_, kind)
    b:Dock(LEFT)
    b:SetWide(width or 200)
    b.DoClick = onClick
    return b
end

-- =============================================================================
-- Draft / wizard state
-- =============================================================================

local function newDraft()
    return {
        id = nil, name = "", description = "", voiceId = "",
        class = "npc_citizen", reasoning = "none", speak = true,
    }
end

local draft = newDraft()

-- =============================================================================
-- Panel
-- =============================================================================

-- Classic Derma interface. Entry point is AINPCS.Open() in cl_2_ainpcs_open.lua,
-- which routes here when Mantle is absent (or when ainpc_ui 1 forces the classic
-- UI). This file is frozen at v3.1: bug fixes only, no new features.
function AINPCS.OpenClassic()
    if IsValid(AINPCS.Panel) then
        AINPCS.Panel:MakePopup()
        return AINPCS.Panel
    end

    local frame = vgui.Create("DFrame")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:Center()
    frame:SetTitle("")
    frame:MakePopup()
    frame:SetDraggable(true)
    AINPCS.Panel = frame

    frame:SetTitle("AI NPCs")

    local TITLEBAR = 24
    local HEADER = 56

    frame.Paint = function(s, w, h)
        draw.RoundedBox(0, 0, 0, w, h, Color(22, 22, 26))
        surface.SetDrawColor(32, 32, 38)
        surface.DrawRect(0, TITLEBAR, w, HEADER)
        draw.SimpleText("AI NPCs", "AINPC_Title", 20, TITLEBAR + 8, C.text)
        draw.SimpleText("v" .. tostring(AINPCS.Version or "?"), "AINPC_Tiny", 20, TITLEBAR + 38, C.sub)
    end

    -- ---- header: voice service status ----
    local pill = vgui.Create("DLabel", frame)
    pill:SetFont("AINPC_Small")
    pill:SetTextColor(C.sub)
    pill:SetText("voice service: checking...")
    pill:SetPos(FRAME_W - 540, TITLEBAR + 12)
    pill:SetSize(380, 18)

    local pillSub = vgui.Create("DLabel", frame)
    pillSub:SetFont("AINPC_Tiny")
    pillSub:SetTextColor(C.sub)
    pillSub:SetText("")
    pillSub:SetPos(FRAME_W - 540, TITLEBAR + 32)
    pillSub:SetSize(380, 16)

    local refreshBtn = styledButton(frame, "Refresh", "ghost")
    refreshBtn:SetSize(80, 24)
    refreshBtn:SetPos(FRAME_W - 116, TITLEBAR + 16)

    function AINPCS.RefreshPill()
        AINPCS.RelayHealth(function(info, code)
            if not IsValid(pill) then return end
            if not info then
                pill:SetTextColor(C.bad)
                if type(code) == "number" then
                    -- HTTP.sys answers 400 when the Host header does not match the
                    -- relay's registered prefix (localhost vs 127.0.0.1).
                    pill:SetText("voice service: unreachable (HTTP " .. code .. ")")
                    pillSub:SetText(code == 400
                        and "wrong host - use http://localhost:7171"
                        or "the relay answered, but not with /health JSON")
                else
                    pill:SetText("voice service: NOT running")
                    pillSub:SetText("tried " .. tostring(AINPCS._relayTried or AINPCS.RelayBase()))
                end
            elseif info.unparsed then
                pill:SetTextColor(C.warn)
                pill:SetText("voice service: running, unreadable status")
                pillSub:SetText("see ainpc_voice_diag in the console")
            elseif info.key_set then
                pill:SetTextColor(C.good)
                pill:SetText("voice service: ready")
                pillSub:SetText(string.format("credit %s   %s",
                    type(info.credits) == "number" and string.format("%.2f", info.credits) or "?",
                    AINPCS.RelayBase()))
            else
                pill:SetTextColor(C.warn)
                pill:SetText("voice service: running, no key")
                pillSub:SetText("paste your Fish Audio key in Settings")
            end
        end)
    end

    refreshBtn.DoClick = function() AINPCS.RefreshPill() end

    -- ---- tab strip ----
    local PAGES = { "library", "create", "settings" }
    local TITLES = { library = "Library", create = "Create", settings = "Settings" }

    local tabBar = vgui.Create("DPanel", frame)
    tabBar:Dock(TOP)
    tabBar:DockMargin(0, TITLEBAR + HEADER, 0, 0)
    tabBar:SetTall(42)
    tabBar.Paint = function(s, w, h)
        surface.SetDrawColor(32, 32, 38)
        surface.DrawRect(0, 0, w, h)
    end

    local body = vgui.Create("DPanel", frame)
    body:Dock(FILL)
    body.Paint = function(s, w, h)
        surface.SetDrawColor(22, 22, 26)
        surface.DrawRect(0, 0, w, h)
    end

    local pages, tabButtons = {}, {}
    local activePage = "library"

    local function showPage(name)
        activePage = name
        for key, page in pairs(pages) do
            if IsValid(page) then page:SetVisible(key == name) end
        end
        for key, btn in pairs(tabButtons) do
            btn.active = (key == name)
            btn:InvalidateLayout(true)
        end
    end

    for i, name in ipairs(PAGES) do
        local page = vgui.Create("DPanel", body)
        page:Dock(FILL)
        page.Paint = nil
        page:SetVisible(false)
        pages[name] = page

        local btn = vgui.Create("DButton", tabBar)
        btn:SetText("")
        btn:SetPos(16 + (i - 1) * 120, 8)
        btn:SetSize(112, 26)
        btn.Paint = function(s, w, h)
            if s.active then
                draw.RoundedBox(6, 0, 0, w, h, Color(44, 44, 52))
                surface.SetDrawColor(90, 165, 255)
                surface.DrawRect(8, h - 3, w - 16, 2)
            elseif s:IsHovered() then
                draw.RoundedBox(6, 0, 0, w, h, Color(38, 38, 45))
            end
            draw.SimpleText(TITLES[s.pageName], "AINPC_Body", w / 2, h / 2,
                s.active and C.text or C.sub, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        btn.pageName = name
        btn.DoClick = function() showPage(name) end
        tabButtons[name] = btn
    end

    local function switched(name) showPage(name) end
    AINPCS.ShowPage = switched

    -- =========================================================================
    -- Library page
    -- =========================================================================

    local libraryPage = pages.library

    -- Bottom bar first: a FILL sibling created before it would consume the space.
    local newRow = vgui.Create("DPanel", libraryPage)
    newRow:Dock(BOTTOM)
    newRow:SetTall(52)
    newRow:DockMargin(20, 0, 20, 14)
    newRow.Paint = nil

    local libraryScroll = vgui.Create("DScrollPanel", libraryPage)
    libraryScroll:Dock(FILL)
    libraryScroll:DockMargin(20, 12, 20, 12)

    local libraryList = vgui.Create("DListLayout")
    libraryScroll:AddItem(libraryList)
    libraryList:Dock(TOP)                 -- width comes from the canvas; without this it is 0
    libraryList:DockPadding(0, 0, 0, 0)

    local newBtn = styledButton(newRow, "+  New character", "primary")
    newBtn:Dock(LEFT)
    newBtn:SetWide(200)
    newBtn.DoClick = function()
        draft = newDraft()
        AINPCS.BuildStep(1)
        switched("create")
    end

    local libraryHint = vgui.Create("DLabel", newRow)
    libraryHint:Dock(FILL)
    libraryHint:DockMargin(14, 0, 0, 0)
    libraryHint:SetFont("AINPC_Small")
    libraryHint:SetTextColor(C.sub)
    libraryHint:SetText("Saved characters can be spawned again any time.")
    libraryHint:SetContentAlignment(0)

    local function libraryCard(entry)
        local card = vgui.Create("DPanel")
        card:SetTall(84)
        card:DockMargin(0, 0, 0, 8)
        card.Paint = function(s, w, h)
            draw.RoundedBox(8, 0, 0, w, h, C.card)
            draw.RoundedBox(8, 0, 0, 4, h, Color(90, 165, 255))
        end

        local name = vgui.Create("DLabel", card)
        name:SetFont("AINPC_Header")
        name:SetTextColor(C.text)
        name:SetText(entry.name)
        name:SetPos(18, 12)
        name:SetSize(500, 28)

        local info = vgui.Create("DLabel", card)
        info:SetFont("AINPC_Small")
        info:SetTextColor(C.sub)
        info:SetText(string.format("%s   •   %s   •   %s",
            voiceLabel(entry.voiceId), classLabel(entry.class),
            entry.reasoning == "none" and "instant replies" or ("thinking: " .. tostring(entry.reasoning))))
        info:SetPos(18, 44)
        info:SetSize(560, 20)

        local spawn = styledButton(card, "Spawn", "primary")
        spawn:Dock(RIGHT)
        spawn:DockMargin(0, 24, 14, 24)
        spawn:SetWide(96)
        spawn.DoClick = function()
            AINPCS.Spawn(entry)
        end

        local edit = styledButton(card, "Edit", "ghost")
        edit:Dock(RIGHT)
        edit:DockMargin(0, 24, 8, 24)
        edit:SetWide(72)
        edit.DoClick = function()
            draft = table.Copy(entry)
            AINPCS.BuildStep(1)
            switched("create")
        end

        local del = styledButton(card, "Delete", "danger")
        del:Dock(RIGHT)
        del:DockMargin(0, 24, 8, 24)
        del:SetWide(72)
        del.DoClick = function()
            AINPCS.RemoveLibraryEntry(entry.id)
            AINPCS.RebuildLibrary()
        end

        libraryList:Add(card)
    end

    function AINPCS.RebuildLibrary()
        libraryList:Clear()
        if #AINPCS.Library == 0 then
            local empty = vgui.Create("DLabel")
            empty:SetFont("AINPC_Body")
            empty:SetTextColor(C.sub)
            empty:SetText("Nothing saved yet.  Press “+ New character” to build one.")
            empty:SetTall(44)
            libraryList:Add(empty)
            return
        end
        for _, entry in ipairs(AINPCS.Library) do
            libraryCard(entry)
        end
    end

    -- =========================================================================
    -- Create page (wizard)
    -- =========================================================================

    local createPage = pages.create

    local stepBar = vgui.Create("DPanel", createPage)
    stepBar:Dock(TOP)
    stepBar:SetTall(44)
    stepBar.Paint = function(s, w, h)
        surface.SetDrawColor(28, 28, 33)
        surface.DrawRect(0, 0, w, h)
    end

    local STEP_NAMES = { "Identity", "Voice", "Body", "Behaviour", "Review" }
    local stepLabels = {}
    for i, name in ipairs(STEP_NAMES) do
        local l = vgui.Create("DLabel", stepBar)
        l:SetFont("AINPC_Small")
        l:SetText(i .. ".  " .. name)
        l:SetPos(20 + (i - 1) * 140, 14)
        l:SetSize(134, 20)
        stepLabels[i] = l
    end

    local nav = vgui.Create("DPanel", createPage)
    nav:Dock(BOTTOM)
    nav:SetTall(56)
    nav:DockMargin(0, 0, 0, 0)
    nav.Paint = function(s, w, h)
        surface.SetDrawColor(28, 28, 33)
        surface.DrawRect(0, 0, w, h)
    end

    local backBtn = styledButton(nav, "Back", "ghost")
    backBtn:SetPos(20, 12)
    backBtn:SetSize(100, 32)

    local nextBtn = styledButton(nav, "Next", "primary")
    nextBtn:Dock(RIGHT)
    nextBtn:DockMargin(0, 12, 20, 12)
    nextBtn:SetWide(180)

    local stepScroll = vgui.Create("DScrollPanel", createPage)
    stepScroll:Dock(FILL)
    stepScroll:DockMargin(0, 0, 0, 0)

    local stepList = vgui.Create("DListLayout")
    stepScroll:AddItem(stepList)
    stepList:Dock(TOP)
    stepList:DockPadding(20, 16, 20, 16)

    local currentStep = 1

    local function setStep(n)
        currentStep = math.Clamp(n, 1, 5)
        for i, l in ipairs(stepLabels) do
            l:SetTextColor(i == currentStep and C.accent or C.sub)
        end

        backBtn:SetVisible(currentStep > 1)
        nextBtn:SetLabel(currentStep == 5 and "Save & spawn" or "Next")
        AINPCS.BuildStep(currentStep)
        stepScroll:GetCanvas():InvalidateLayout(true)
    end

    AINPCS.BuildStep = function(n)
        stepList:Clear()

        if n == 1 then
            heading(stepList, "Who is this NPC?",
                "The name is enough. If it belongs to a known character the AI already knows how they talk.")

            local nameRow = field(stepList, 36)
            local nameE = vgui.Create("DTextEntry", nameRow)
            nameE:SetWide(CONTENT_W)
            nameE:SetTall(34)
            -- Commit while typing. DTextEntry only fires OnValueChange on Enter
            -- or focus loss, and a click on a button does not always move focus,
            -- so the last thing typed was dropped and the step rebuilt empty.
            nameE:SetUpdateOnType(true)
            nameE:SetPlaceholderText("e.g. Rick Sanchez")
            nameE:SetText(draft.name or "")
            nameE.OnValueChange = function(_, v) draft.name = v end

            gap(stepList, 6)
            text(stepList, "Description (optional)", "AINPC_Small", C.sub, 20)

            local descRow = field(stepList, 120)
            local descE = vgui.Create("DTextEntry", descRow)
            descE:SetMultiline(true)
            descE:SetWide(CONTENT_W)
            descE:SetTall(116)
            descE:SetUpdateOnType(true)
            descE:SetPlaceholderText("Leave blank for a character from a game or film. Add notes for an original one.")
            descE:SetText(draft.description or "")
            descE.OnValueChange = function(_, v) draft.description = v end

        elseif n == 2 then
            heading(stepList, "How should they sound?",
                "Searches your voice service. Character voices need credit on your Fish Audio account.")

            local searchRow = field(stepList, 36)
            local searchE = vgui.Create("DTextEntry", searchRow)
            searchE:SetWide(CONTENT_W - 120)
            searchE:SetTall(34)
            searchE:SetUpdateOnType(true)
            searchE:SetPlaceholderText("rick sanchez")

            local searchBtn = styledButton(searchRow, "Search", "primary")
            searchBtn:SetPos(CONTENT_W - 112, 0)
            searchBtn:SetSize(108, 34)

            local listRow = field(stepList, 250)
            local results = vgui.Create("DListView", listRow)
            results:SetWide(CONTENT_W)
            results:SetTall(246)
            results:AddColumn("Voice")
            results:SetMultiSelect(false)

            local statusLbl = text(stepList, "", "AINPC_Small", C.sub, 20)

            local previewBtn = addButton(stepList, "Preview selected voice", "ghost", function()
                local line = results:GetSelectedLine()
                if line and line.voiceId then
                    AINPCS.PreviewVoice(line.voiceId, "Hello, I am " ..
                        (AINPCS.Trim(draft.name or "") ~= "" and draft.name or "an NPC") .. ".")
                end
            end, 220)

            local function fill(voices)
                results:Clear()
                for _, v in ipairs(voices or {}) do
                    local line = results:AddLine(v.label)
                    line.voiceId = "relay:" .. v.name
                    if draft.voiceId == line.voiceId then results:SelectItem(line) end
                end
                statusLbl:SetText(#(voices or {}) == 0
                    and "no matches - is the voice service running?" or (#(voices or {}) .. " matches, click one"))
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
            heading(stepList, "What should they look like?", "Pick the body model.")

            local bodyRow = field(stepList, 300)

            local bodyList = vgui.Create("DListView", bodyRow)
            bodyList:SetPos(0, 0)
            bodyList:SetSize(CONTENT_W - 260, 296)
            bodyList:AddColumn("Body")

            local previewBox = vgui.Create("DPanel", bodyRow)
            previewBox:SetPos(CONTENT_W - 250, 0)
            previewBox:SetSize(250, 296)
            previewBox.Paint = function(s, w, h) draw.RoundedBox(8, 0, 0, w, h, C.cardAlt) end

            local preview = vgui.Create("DModelPanel", previewBox)
            preview:Dock(FILL)
            preview:SetModel("models/humans/group01/male_07.mdl")
            preview:SetFOV(46)
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
            heading(stepList, "How should they answer?",
                "Instant skips reasoning entirely: the NPC starts talking immediately.")

            text(stepList, "Reply speed", "AINPC_Small", C.sub, 20)
            local speedRow = field(stepList, 36)
            local speed = vgui.Create("DComboBox", speedRow)
            speed:SetWide(CONTENT_W)
            speed:SetTall(34)
            speed:AddChoice("Instant (no reasoning)", "none", draft.reasoning == "none")
            speed:AddChoice("A little thinking", "low", draft.reasoning == "low")
            speed:AddChoice("Balanced", "medium", draft.reasoning == "medium")
            function speed.OnSelect(_, _, value) draft.reasoning = value end

            gap(stepList, 10)
            local speakRow = field(stepList, 28)
            local speak = vgui.Create("DCheckBoxLabel", speakRow)
            speak:SetText("Speak out loud")
            speak:SetValue(draft.speak ~= false)
            speak:SetFont("AINPC_Body")
            speak:SetTextColor(C.text)
            speak:SetTall(26)
            speak:SetWide(CONTENT_W)
            speak.OnChange = function(_, v) draft.speak = v end

        else
            heading(stepList, "Ready to save", nil)

            local summary = {
                { "Name",        (AINPCS.Trim(draft.name or "") ~= "" and draft.name) or "(none)" },
                { "Voice",       voiceLabel(draft.voiceId) },
                { "Body",        classLabel(draft.class) },
                { "Replies",     draft.reasoning == "none" and "instant" or tostring(draft.reasoning) },
                { "Speaks",      draft.speak and "yes" or "no" },
                { "Description", (AINPCS.Trim(draft.description or "") ~= "" and draft.description) or "from the name" },
            }

            for _, pair in ipairs(summary) do
                local r = vgui.Create("DPanel")
                r:SetTall(24)
                r.Paint = nil
                stepList:Add(r)

                local k = vgui.Create("DLabel", r)
                k:SetPos(0, 2)
                k:SetSize(120, 20)
                k:SetFont("AINPC_Small")
                k:SetTextColor(C.sub)
                k:SetText(pair[1])

                local v = vgui.Create("DLabel", r)
                v:SetPos(120, 2)
                v:SetSize(CONTENT_W - 120, 20)
                v:SetFont("AINPC_Body")
                v:SetTextColor(C.text)
                v:SetText(pair[2])
            end

            gap(stepList, 12)
            addButton(stepList, "Save to library", "ghost", function()
                AINPCS.SaveDraft()
                AINPCS.RebuildLibrary()
                switched("library")
                AINPCS.PushToast(draft.name .. " saved.", "success")
            end, 220)

            addButton(stepList, "Save & spawn now", "primary", function()
                AINPCS.SaveDraft()
                AINPCS.RebuildLibrary()
                AINPCS.Spawn(draft)
            end, 220)
        end
    end

    AINPCS.SaveDraft = function()
        if AINPCS.IsBlank(draft.name or "") then draft.name = "NPC" end
        if draft.voiceId == "" then draft.voiceId = AINPCS.Settings.fallbackVoice end
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

    local settingsPage = pages.settings
    local S = AINPCS.Settings
    if not istable(S.apiKeys) then S.apiKeys = {} end

    local settingsScroll = vgui.Create("DScrollPanel", settingsPage)
    settingsScroll:Dock(FILL)
    settingsScroll:DockMargin(20, 12, 20, 12)

    local sl = vgui.Create("DListLayout")
    settingsScroll:AddItem(sl)
    sl:Dock(TOP)
    sl:DockPadding(0, 0, 0, 24)

    local function persist() AINPCS.SaveSettings() end

    heading(sl, "AI provider", "Used for every NPC. You set this once.")
    local provRow = field(sl, 36)
    local provCombo = vgui.Create("DComboBox", provRow)
    provCombo:SetWide(CONTENT_W)
    provCombo:SetTall(34)
    for _, p in ipairs(providers.list()) do
        provCombo:AddChoice(p.label, p.id, p.id == S.provider)
    end

    local keyHint = text(sl, "", "AINPC_Tiny", C.sub, 34, true)

    divider(sl)
    gap(sl, 10)
    heading(sl, "Model", nil)

    local freeRow = field(sl, 26)
    local freeChk = vgui.Create("DCheckBoxLabel", freeRow)
    freeChk:SetText("Free models only")
    freeChk:SetValue(S.freeOnly ~= false)
    if freeChk.Label then
        freeChk.Label:SetFont("AINPC_Small")
        freeChk.Label:SetTextColor(C.sub)
    end
    freeChk:SetTall(24)
    freeChk.OnChange = function(_, v)
        S.freeOnly = v
        persist()
        AINPCS.BuildModelCombo()
    end

    local modelRow = field(sl, 36)
    local modelCombo = vgui.Create("DComboBox", modelRow)
    modelCombo:SetWide(CONTENT_W)
    modelCombo:SetTall(34)
    function modelCombo.OnSelect(_, _, id) S.model = id persist() end

    local modelNote = text(sl, "", "AINPC_Tiny", C.sub, 18)

    function AINPCS.BuildModelCombo()
        modelCombo:Clear()
        local order, models = AINPCS.ModelList(S.provider)
        local shown, picked = 0, false

        for _, id in ipairs(order or {}) do
            local m = models[id]
            if m then
                local isFree = (m.free ~= false)
                if S.provider ~= "openrouter" or not S.freeOnly or isFree then
                    local label_ = m.label or id
                    if not isFree then
                        label_ = string.format("%s  ($%.2f/$%.2f per M)", label_,
                            tonumber(m.price_in) or 0, tonumber(m.price_out) or 0)
                    end
                    modelCombo:AddChoice(label_, id, id == S.model)
                    shown = shown + 1
                    if id == S.model then picked = true end
                end
            end
        end

        if not picked and shown > 0 then
            local p = providers.get(S.provider)
            local preferred = p and p.defaultModel
            local first = (order or {})[1]
            S.model = (preferred and models[preferred]) and preferred or first
            local text1 = modelCombo:GetOptionText(1)
            if text1 then modelCombo:ChooseOption(text1) end
        end

        modelNote:SetText(shown == 0 and "no models for this provider" or (shown .. " models"))

        if S.provider == "openrouter" and not AINPCS.LiveOpenRouter then
            AINPCS.RequestModels()
        end
    end

    local function refreshKeyHint()
        local p = providers.get(S.provider)
        keyHint:SetText(string.format("%s\nGet a key: %s",
            (p and p.note) or "", (p and p.getKeyUrl) or ""))
    end

    function provCombo.OnSelect(_, _, id)
        S.provider = id
        S.model = ""
        persist()
        refreshKeyHint()
        AINPCS.BuildModelCombo()
        AINPCS.RebuildKeyField()
    end

    divider(sl)
    gap(sl, 10)
    heading(sl, "API key", nil)

    local keyRow = field(sl, 36)
    local keyE = vgui.Create("DTextEntry", keyRow)
    keyE:SetWide(CONTENT_W)
    keyE:SetTall(34)
    keyE:SetUpdateOnType(true)   -- persist per keystroke, not on focus loss
    keyE:SetPlaceholderText("paste your provider key")
    keyE.OnValueChange = function(_, v)
        S.apiKeys[S.provider] = AINPCS.Trim(v)
        persist()
    end

    function AINPCS.RebuildKeyField()
        keyE:SetText(S.apiKeys[S.provider] or "")
    end

    local hostRow = field(sl, 36)
    local hostE = vgui.Create("DTextEntry", hostRow)
    hostE:SetWide(CONTENT_W)
    hostE:SetTall(34)
    hostE:SetUpdateOnType(true)
    hostE:SetPlaceholderText("Ollama hostname (only for Ollama): 127.0.0.1:11434")
    hostE:SetText(S.hostname or "")
    hostE.OnValueChange = function(_, v)
        S.hostname = AINPCS.Trim(v or "")
        persist()
    end

    divider(sl)
    gap(sl, 10)
    heading(sl, "Voice service (Fish Audio)",
        "Character voices need a local helper with your own Fish key. Start it with relay/start.bat.")

    local serviceStatus = text(sl, "checking...", "AINPC_Small", C.sub, 20)
    function AINPCS.RefreshSettingsService()
        AINPCS.RelayHealth(function(info)
            if not IsValid(serviceStatus) then return end
            if not info then
                serviceStatus:SetTextColor(C.bad)
                serviceStatus:SetText("NOT running - double-click relay/start.bat")
            elseif info.key_set then
                serviceStatus:SetTextColor(C.good)
                serviceStatus:SetText(string.format("Running - key set - credit %s",
                    type(info.credits) == "number" and string.format("%.2f", info.credits) or "?"))
            else
                serviceStatus:SetTextColor(C.warn)
                serviceStatus:SetText("Running - no key yet, paste one below")
            end
        end)
    end

    local fishRow = field(sl, 36)
    local fishE = vgui.Create("DTextEntry", fishRow)
    fishE:SetWide(CONTENT_W - 110)
    fishE:SetTall(34)
    fishE:SetPlaceholderText("Fish Audio API key (sk-fish-...)")

    local fishSave = styledButton(fishRow, "Save", "primary")
    fishSave:SetPos(CONTENT_W - 100, 0)
    fishSave:SetSize(100, 34)
    fishSave.DoClick = function()
        local key = AINPCS.Trim(fishE:GetValue() or "")
        if key == "" then return end
        AINPCS.RelaySaveKey(key, function(ok, code, body)
            AINPCS.PushToast(ok and "Fish key saved."
                or ("Rejected: " .. tostring((istable(body) and body.error) or code)),
                ok and "success" or "error")
            AINPCS.RefreshPill()
            AINPCS.RefreshSettingsService()
        end)
    end

    addButton(sl, "Open voice library / pin voices", "ghost", function()
        gui.OpenURL(AINPCS.RelayBase() .. "/")
    end, 260)

    divider(sl)
    gap(sl, 10)
    heading(sl, "Fallback voice",
        "Used when an NPC has no character voice, or when the voice service is down. No account needed.")

    local fbRow = field(sl, 36)
    local fbCombo = vgui.Create("DComboBox", fbRow)
    fbCombo:SetWide(CONTENT_W)
    fbCombo:SetTall(34)
    for _, v in ipairs(Voices.list) do
        if not string.match(v.id, "^relay:") then
            fbCombo:AddChoice(v.label, v.id, v.id == S.fallbackVoice)
        end
    end
    function fbCombo.OnSelect(_, _, id) S.fallbackVoice = id persist() end

    divider(sl)
    gap(sl, 10)
    heading(sl, "Volume", nil)

    local volRow = field(sl, 42)
    local vol = vgui.Create("DNumSlider", volRow)
    vol:SetWide(CONTENT_W)
    vol:SetTall(40)
    vol:SetText("")
    vol:SetMin(0)
    vol:SetMax(1)
    vol:SetDecimals(2)
    local volCv = GetConVar("ainpc_voice_volume")
    vol:SetValue(volCv and volCv:GetFloat() or 1)
    vol.OnValueChanged = function(_, v)
        RunConsoleCommand("ainpc_voice_volume", tostring(math.Clamp(v, 0, 1)))
    end

    AINPCS.OnModelsChanged = function()
        if IsValid(modelCombo) then AINPCS.BuildModelCombo() end
    end

    -- ---- boot ----
    refreshKeyHint()
    AINPCS.RebuildKeyField()
    AINPCS.BuildModelCombo()
    AINPCS.RefreshSettingsService()
    AINPCS.RefreshPill()
    setStep(1)
    AINPCS.RebuildLibrary()
    switched("library")

    return frame
end
