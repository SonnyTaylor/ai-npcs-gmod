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
        id = nil, name = "", description = "", voiceId = "", voiceLabel = "",
        class = "npc_citizen", bodyModel = "", weapon = "none",
        reasoning = "none", speak = true,
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
                pill:SetTextColor(C.warn)
                pill:SetText("Fish Audio: unreachable")
                pillSub:SetText("could not reach api.fish.audio (" .. tostring(code) .. ")")
            elseif info.key_rejected then
                pill:SetTextColor(C.bad)
                pill:SetText("Fish Audio: key rejected")
                pillSub:SetText("open Settings and paste a valid Fish Audio key")
            elseif info.key_set then
                pill:SetTextColor(C.good)
                pill:SetText("Fish Audio: ready")
                pillSub:SetText(string.format("credit %s   ·   %d pinned voices",
                    type(info.credits) == "number" and string.format("%.2f", info.credits) or "?",
                    info.presets or 0))
            else
                pill:SetTextColor(C.warn)
                pill:SetText("Fish Audio: no key (built-in voices only)")
                pillSub:SetText("paste your Fish Audio key in Settings for cloned voices")
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
                "Search all of Fish Audio, or use a free built-in voice. Character voices need credit on your Fish Audio account.")

            -- One summary card; the actual picking happens in the voice browser.
            local card = vgui.Create("DPanel")
            card:SetTall(78)
            card.Paint = function(s, w, h)
                draw.RoundedBox(8, 0, 0, w, h, C.cardAlt)
            end
            stepList:Add(card)

            local nameLbl = vgui.Create("DLabel", card)
            nameLbl:SetPos(16, 14)
            nameLbl:SetSize(CONTENT_W - 180, 26)
            nameLbl:SetFont("AINPC_Header")
            nameLbl:SetTextColor(C.text)

            local subLbl = vgui.Create("DLabel", card)
            subLbl:SetPos(16, 44)
            subLbl:SetSize(CONTENT_W - 180, 20)
            subLbl:SetFont("AINPC_Small")
            subLbl:SetTextColor(C.sub)

            local function refreshVoiceCard()
                if AINPCS.IsBlank(draft.voiceId or "") then
                    draft.voiceId = AINPCS.Settings.fallbackVoice or "google:en"
                end
                local v = Voices.Get(draft.voiceId)
                nameLbl:SetText(v and v.label or draft.voiceId)
                local isFish = Voices.IsFish(draft.voiceId)
                subLbl:SetText(isFish
                    and (AINPCS.Trim(AINPCS.Settings.fishKey or "") ~= ""
                        and "Fish Audio voice — speaks in game, uses your key's credit"
                        or "Fish Audio voice — add your Fish Audio key in Settings to use it")
                    or "Built-in voice — free and keyless")
                subLbl:SetTextColor(isFish and C.warn or C.sub)
            end

            local browseBtn = styledButton(card, "Browse voices…", "primary")
            browseBtn:SetPos(CONTENT_W - 160, 22)
            browseBtn:SetSize(144, 34)
            browseBtn.DoClick = function()
                AINPCS.OpenVoiceBrowser({
                    voiceId = draft.voiceId,
                    onPick = function(voiceId, label)
                        draft.voiceId = voiceId
                        draft.voiceLabel = label or ""
                        refreshVoiceCard()
                    end,
                })
            end

            refreshVoiceCard()

            gap(stepList, 8)
            local testBtn = addButton(stepList, "Hear this voice", "ghost", function()
                local who = AINPCS.Trim(draft.name or "") ~= "" and draft.name or "an NPC"
                AINPCS.PreviewVoice(draft.voiceId, "Hello, I am " .. who .. ".")
            end, 180)
            testBtn:SetDisabled(false)

            gap(stepList, 10)
            text(stepList, "Tip: type any character into the browser's search box (barney, rick, a granny…) — every Fish Audio voice is searchable. Rows marked “free sample” play instantly without spending credit.",
                "AINPC_Small", C.sub, 46, true)

        elseif n == 3 then
            heading(stepList, "What should they look like?",
                "NPC bodies and playermodels in one list, with a live 3D preview.")

            local card = vgui.Create("DPanel")
            card:SetTall(268)
            card.Paint = function(s, w, h) draw.RoundedBox(8, 0, 0, w, h, C.cardAlt) end
            stepList:Add(card)

            local preview = vgui.Create("DModelPanel", card)
            preview:SetPos(0, 0)
            preview:SetSize(240, 268)
            preview:SetFOV(42)
            preview.LayoutEntity = function(self, ent)
                self:RunAnimation()
                ent:SetAngles(Angle(0, RealTime() * 45, 0))
            end

            local bodyName = vgui.Create("DLabel", card)
            bodyName:SetPos(258, 18)
            bodyName:SetSize(CONTENT_W - 270, 26)
            bodyName:SetFont("AINPC_Header")
            bodyName:SetTextColor(C.text)

            local bodySub = vgui.Create("DLabel", card)
            bodySub:SetPos(258, 46)
            bodySub:SetSize(CONTENT_W - 270, 40)
            bodySub:SetFont("AINPC_Small")
            bodySub:SetTextColor(C.sub)
            bodySub:SetWrap(true)

            local function refreshBodyCard()
                local reg = list.Get("NPC") or {}
                local data = reg[draft.class]
                local model = draft.bodyModel
                if not AINPCS.IsUsableBodyModel(model) then
                    model = (data and data.Model) or "models/humans/group01/male_07.mdl"
                end
                preview:SetModel(model)
                bodyName:SetText((data and data.Name) or draft.class or "?")
                bodySub:SetText(string.lower(model))
            end

            local browseBtn = styledButton(card, "Browse all bodies…", "primary")
            browseBtn:SetPos(258, 100)
            browseBtn:SetSize(200, 36)
            browseBtn.DoClick = function()
                AINPCS.OpenBodyBrowser({
                    class     = draft.class,
                    bodyModel = draft.bodyModel,
                    onPick = function(class, model)
                        draft.class = class
                        draft.bodyModel = model
                        refreshBodyCard()
                    end,
                })
            end

            local clearBtn = styledButton(card, "Reset to class default", "ghost")
            clearBtn:SetPos(258, 144)
            clearBtn:SetSize(200, 32)
            clearBtn.DoClick = function()
                draft.bodyModel = ""
                refreshBodyCard()
            end

            refreshBodyCard()

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

            gap(stepList, 10)
            text(stepList, "Weapon", "AINPC_Small", C.sub, 20)
            local wepRow = field(stepList, 36)
            local wepCombo = vgui.Create("DComboBox", wepRow)
            wepCombo:SetWide(CONTENT_W)
            wepCombo:SetTall(34)
            wepCombo:SetSortItems(false)
            for _, wid in ipairs(AINPCS.WeaponOrder or {}) do
                local wInfo = AINPCS.Weapons[wid]
                if wInfo then
                    wepCombo:AddChoice(wInfo.label, wid, draft.weapon == wid)
                end
            end
            function wepCombo.OnSelect(_, _, _, data) draft.weapon = data end
            text(stepList, "The NPC can still switch weapons, drop it, or be told to attack in conversation.",
                "AINPC_Tiny", C.sub, 18)

        else
            heading(stepList, "Ready to save", nil)

            local summary = {
                { "Name",        (AINPCS.Trim(draft.name or "") ~= "" and draft.name) or "(none)" },
                { "Voice",       voiceLabel(draft.voiceId) },
                { "Body",        (draft.bodyModel ~= "" and AINPCS.Trim(draft.bodyModel)) or classLabel(draft.class) },
                { "Weapon",      AINPCS.WeaponLabel(draft.weapon) },
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

    -- Re-runnable guided setup: provider choice, signup link, key test, Fish key.
    addButton(sl, "Run setup again (guided)", "ghost", function()
        if isfunction(AINPCS.OpenSetupWizard) then
            AINPCS.OpenSetupWizard({ rerun = true })
        end
    end, 240)

    text(sl, "Not sure which key to use? The guided setup opens the provider's key page for you and checks that the key works before saving it.",
        "AINPC_Tiny", C.sub, 30, true)
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
    heading(sl, "Fish Audio voice service",
        "Built into the addon — no helper program or .bat file. Paste your own Fish Audio key to use cloned character voices and to search the whole library.")

    local serviceStatus = text(sl, "checking...", "AINPC_Small", C.sub, 20)
    function AINPCS.RefreshSettingsService()
        AINPCS.RelayHealth(function(info)
            if not IsValid(serviceStatus) then return end
            if not info then
                serviceStatus:SetTextColor(C.warn)
                serviceStatus:SetText("Could not reach api.fish.audio (built-in voices still work)")
            elseif info.key_rejected then
                serviceStatus:SetTextColor(C.bad)
                serviceStatus:SetText("Fish Audio rejected that key — paste it again")
            elseif info.key_set then
                serviceStatus:SetTextColor(C.good)
                serviceStatus:SetText(string.format("Connected · credit %s · %d pinned voices",
                    type(info.credits) == "number" and string.format("%.2f", info.credits) or "?",
                    info.presets or 0))
            else
                serviceStatus:SetTextColor(C.warn)
                serviceStatus:SetText("No key yet — free built-in voices only")
            end
        end)
    end

    local fishRow = field(sl, 36)
    local fishE = vgui.Create("DTextEntry", fishRow)
    fishE:SetWide(CONTENT_W - 110)
    fishE:SetTall(34)
    fishE:SetPlaceholderText("Fish Audio API key (sk-fish-...)")
    fishE:SetText(AINPCS.Settings.fishKey or "")

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

    addButton(sl, "Browse all Fish Audio voices…", "ghost", function()
        AINPCS.OpenVoiceBrowser({
            voiceId = S.fallbackVoice,
            onPick = function(voiceId)
                S.fallbackVoice = voiceId
                persist()
            end,
        })
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
        -- Fallback must stay free/keyless: Fish Audio voices need credit.
        if not Voices.IsFish(v.id) then
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
