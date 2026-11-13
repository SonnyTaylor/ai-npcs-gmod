--[[
    AI NPCs — first-run setup wizard

    Walks a new player through the two keys the addon can use:

      1. an AI provider key (Groq is free and takes about a minute), and
      2. optionally a Fish Audio key for cloned character voices.

    Every step that needs an account links straight to that provider's key page
    and validates the pasted key against the provider before saving it, so nobody
    has to guess whether they pasted the right thing.

    Entry points:
      AINPCS.OpenSetupWizard()                    -- first run / manual
      AINPCS.OpenSetupWizard({ rerun = true })    -- from Settings
]]

AINPCS = AINPCS or {}

local providers = AINPCS.Providers or include("providers/providers.lua")
local Voices    = AINPCS.Voices or include("voices/voices.lua")

local C = AINPCS.Colors or {
    bg = Color(20, 20, 24), card = Color(34, 34, 40), cardAlt = Color(29, 29, 34),
    text = Color(235, 235, 235), sub = Color(160, 160, 170),
    accent = Color(90, 165, 255), good = Color(90, 200, 120),
    bad = Color(235, 90, 90), warn = Color(235, 190, 90),
}

surface.CreateFont("AINPC_SetupTitle", { font = "Roboto", size = 26, weight = 700 })
surface.CreateFont("AINPC_SetupHead",  { font = "Roboto", size = 19, weight = 700 })
surface.CreateFont("AINPC_SetupBody",  { font = "Roboto", size = 16, weight = 400 })
surface.CreateFont("AINPC_SetupSmall", { font = "Roboto", size = 13, weight = 400 })

local STEPS = { "Welcome", "Provider", "Key", "Voice", "Done" }

-- Providers offered by the wizard, in the order they are recommended.
local PROVIDER_CHOICES = {
    {
        id     = "groq",
        title  = "Groq",
        badge  = "Recommended · free",
        desc   = "Free tier, no credit card, very fast. A good default for AI NPCs.",
    },
    {
        id     = "openrouter",
        title  = "OpenRouter",
        badge  = "Free models",
        desc   = "One key for hundreds of models. Tick \"Free models only\" to stay free.",
    },
    {
        id     = "openai",
        title  = "OpenAI",
        badge  = "Paid",
        desc   = "Best quality, needs paid credit on your account.",
    },
    {
        id     = "deepseek",
        title  = "DeepSeek",
        badge  = "Cheap",
        desc   = "Very inexpensive. Good role-play for the price.",
    },
    {
        id     = "ollama",
        title  = "Ollama (local)",
        badge  = "No key · your PC",
        desc   = "Runs a model on your own machine. Nothing to sign up for, but you must run Ollama yourself.",
    },
}

-- =============================================================================
-- Small widgets (same visual language as the browser modals)
-- =============================================================================

local function solidRect(panel, col)
    panel.Paint = function(s, w, h)
        surface.SetDrawColor(col.r, col.g, col.b, col.a or 255)
        surface.DrawRect(0, 0, w, h)
    end
end

local function card(parent, height, bg)
    local p = vgui.Create("DPanel", parent)
    p:SetTall(height)
    p.Paint = function(s, w, h)
        surface.SetDrawColor((bg or C.card).r, (bg or C.card).g, (bg or C.card).b, 255)
        surface.DrawRect(0, 0, w, h)
    end
    return p
end

local function label(parent, text, font, col, height, wrap)
    local l = vgui.Create("DLabel", parent)
    l:SetFont(font or "AINPC_SetupBody")
    l:SetTextColor(col or C.text)
    l:SetText(text or "")
    if height then l:SetTall(height) end
    if wrap then
        l:SetWrap(true)
        l:SetAutoStretchVertical(false)
    end
    return l
end

local function actionButton(parent, text, kind, width, height)
    local styles = {
        primary = { base = Color(52, 104, 190),  hover = Color(66, 124, 216) },
        ghost   = { base = Color(48, 48, 56),    hover = Color(64, 64, 74) },
        good    = { base = Color(46, 104, 62),   hover = Color(58, 130, 78) },
        link    = { base = Color(38, 38, 46),    hover = Color(52, 52, 64) },
    }
    local st = styles[kind or "ghost"]

    local b = vgui.Create("DButton", parent)
    b:SetText("")
    b._label = text
    if width then b:SetWide(width) end
    if height then b:SetTall(height) end
    b.Paint = function(s, w, h)
        local col = s:GetDisabled() and Color(44, 44, 50) or (s:IsHovered() and st.hover or st.base)
        surface.SetDrawColor(col.r, col.g, col.b, 255)
        surface.DrawRect(0, 0, w, h)
        draw.SimpleText(s._label or "", "AINPC_SetupBody", w / 2, h / 2,
            s:GetDisabled() and Color(120, 120, 130) or C.text,
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    function b:SetLabel(t) self._label = t self:InvalidateLayout(true) end
    return b
end

local function entryBox(parent, placeholder, height)
    local box = vgui.Create("DPanel", parent)
    box:SetTall(height or 36)
    box.Paint = function(s, w, h)
        surface.SetDrawColor(30, 30, 36, 255)
        surface.DrawRect(0, 0, w, h)
        if IsValid(s.entry) and s.entry:IsEditing() then
            surface.SetDrawColor(90, 165, 255)
            surface.DrawOutlinedRect(0, 0, w, h, 1)
        end
    end

    local e = vgui.Create("DTextEntry", box)
    e:Dock(FILL)
    e:DockMargin(10, 0, 10, 0)
    e:SetFont("AINPC_SetupBody")
    e:SetTextColor(C.text)
    e:SetDrawBackground(false)
    e:SetPlaceholderText(placeholder or "")
    e:SetUpdateOnType(true)
    box.entry = e
    return box
end

-- =============================================================================
-- Wizard
-- =============================================================================

function AINPCS.OpenSetupWizard(opts)
    opts = opts or {}
    if IsValid(AINPCS.SetupWizard) then
        AINPCS.SetupWizard:MakePopup()
        return AINPCS.SetupWizard
    end

    local S = AINPCS.Settings
    if not istable(S.apiKeys) then S.apiKeys = {} end

    -- Never nag twice: the moment the wizard is shown, first-run is done.
    if S.firstRun then
        S.firstRun = false
        AINPCS.SaveSettings()
    end

    local state = {
        step      = 1,
        provider  = S.provider or "groq",
        key       = AINPCS.Trim(S.apiKeys[S.provider] or ""),
        hostname  = S.hostname or "",
        fishKey   = S.fishKey or "",
        keyOk     = false,
        fishOk    = AINPCS.Trim(S.fishKey or "") ~= "",
        wantFish  = false,
    }

    local FRAME_W, FRAME_H = 860, 620
    local RAIL_W, FOOT_H = 190, 60

    local f = vgui.Create("DFrame")
    f:SetSize(math.min(FRAME_W, ScrW() - 60), math.min(FRAME_H, ScrH() - 60))
    f:Center()
    f:SetTitle("")
    f:MakePopup()
    f:SetDraggable(true)
    f:SetDeleteOnClose(true)
    f.Paint = function(s, w, h)
        surface.SetDrawColor(20, 20, 24)
        surface.DrawRect(0, 0, w, h)
        surface.SetDrawColor(32, 32, 40)
        surface.DrawRect(0, 0, w, 30)
        draw.SimpleText(opts.rerun and "AI NPCs — setup" or "Welcome to AI NPCs",
            "AINPC_SetupHead", 14, 15, C.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        -- step rail
        surface.SetDrawColor(26, 26, 31)
        surface.DrawRect(0, 30, RAIL_W, h - 30)
    end

    AINPCS.SetupWizard = f

    -- ---- step rail --------------------------------------------------------
    local rail = vgui.Create("DPanel", f)
    rail:SetPos(0, 30)
    rail:SetSize(RAIL_W, FRAME_H - 30 - FOOT_H)
    rail.Paint = nil

    local railLabels = {}
    for i, name in ipairs(STEPS) do
        local row = vgui.Create("DPanel", rail)
        row:SetPos(0, 18 + (i - 1) * 42)
        row:SetSize(RAIL_W, 36)
        row.Paint = function(s, w, h)
            if s.active then
                surface.SetDrawColor(44, 78, 130)
                surface.DrawRect(0, 0, w, h)
                surface.SetDrawColor(90, 165, 255)
                surface.DrawRect(0, 0, 4, h)
            end
        end

        local dot = vgui.Create("DLabel", row)
        dot:SetPos(16, 8)
        dot:SetSize(20, 20)
        dot:SetFont("AINPC_SetupSmall")
        dot:SetTextColor(C.sub)
        dot:SetText(i)

        local lbl = vgui.Create("DLabel", row)
        lbl:SetPos(40, 8)
        lbl:SetSize(RAIL_W - 50, 20)
        lbl:SetFont("AINPC_SetupBody")
        lbl:SetTextColor(C.sub)
        lbl:SetText(name)

        railLabels[i] = { row = row, dot = dot, lbl = lbl }
        row.name = name
    end

    -- ---- footer -----------------------------------------------------------
    local footer = vgui.Create("DPanel", f)
    footer:Dock(BOTTOM)
    footer:SetTall(FOOT_H)
    footer.Paint = function(s, w, h)
        surface.SetDrawColor(26, 26, 31)
        surface.DrawRect(0, 0, w, h)
    end

    local backBtn = actionButton(footer, "Back", "ghost", 96, 34)
    backBtn:Dock(LEFT)
    backBtn:DockMargin(14, 13, 0, 13)

    local skipBtn = actionButton(footer, "Skip for now", "link", 120, 34)
    skipBtn:Dock(LEFT)
    skipBtn:DockMargin(8, 13, 0, 13)

    local nextBtn = actionButton(footer, "Next", "primary", 190, 34)
    nextBtn:Dock(RIGHT)
    nextBtn:DockMargin(0, 13, 14, 13)

    -- ---- content host -----------------------------------------------------
    local host = vgui.Create("DPanel", f)
    host:SetPos(RAIL_W, 30)
    host:SetSize(FRAME_W - RAIL_W, FRAME_H - 30 - FOOT_H)
    host.Paint = nil
    host:DockPadding(24, 22, 24, 16)

    -- ---- helpers ----------------------------------------------------------
    local function stepTitle(title, sub)
        local t = label(host, title, "AINPC_SetupTitle", C.text, 34)
        t:Dock(TOP)
        if sub then
            local s = label(host, sub, "AINPC_SetupBody", C.sub, 46, true)
            s:Dock(TOP)
            s:DockMargin(0, 0, 0, 10)
        end
    end

    local function statusLine(initial)
        local l = label(host, initial or "", "AINPC_SetupSmall", C.sub, 22)
        l:Dock(TOP)
        return l
    end

    local function setStatus(lbl, text, kind)
        if not IsValid(lbl) then return end
        lbl:SetText(text or "")
        lbl:SetTextColor(kind == "ok" and C.good or kind == "bad" and C.bad or kind == "warn" and C.warn or C.sub)
    end

    local function openURLButton(parent, url, text)
        local b = actionButton(parent, text or ("Open " .. url), "link", 340, 32)
        b.DoClick = function()
            gui.OpenURL(url)
            surface.PlaySound("ui/buttonclick.wav")
        end
        return b
    end

    -- =====================================================================
    -- Step bodies
    -- =====================================================================

    local render  -- forward declaration

    local function renderWelcome()
        stepTitle("Let's get your AI NPCs talking",
            "Two keys, both optional except the first. The whole thing takes about a minute and nothing is sent to this server's owner.")

        local list = vgui.Create("DPanel", host)
        list:Dock(TOP)
        list:SetTall(210)
        list.Paint = nil

        local items = {
            {
                n = "1",
                title = "An AI provider key — required",
                body  = "This is the \"brain\". Groq has a free tier and no credit card, so it is the easiest place to start.",
            },
            {
                n = "2",
                title = "A Fish Audio key — optional",
                body  = "Only needed for cloned character voices (Barney, Rick, anything on fish.audio). Without it, AI NPCs use the free built-in voices.",
            },
            {
                n = "3",
                title = "Nothing leaves your PC unless an NPC speaks",
                body  = "Your key is stored in garrysmod/data/ai_npcs_settings.json on your machine. Search and testing happen from your game.",
            },
        }

        for i, item in ipairs(items) do
            local row = card(list, 66, C.cardAlt)
            row:SetPos(0, (i - 1) * 70)
            row:SetWide(560)

            local num = label(row, item.n, "AINPC_SetupTitle", C.accent, 30)
            num:SetPos(14, 18)
            num:SetWide(24)

            local t = label(row, item.title, "AINPC_SetupHead", C.text, 24)
            t:SetPos(46, 12)
            t:SetWide(500)

            local b = label(row, item.body, "AINPC_SetupSmall", C.sub, 30, true)
            b:SetPos(46, 36)
            b:SetWide(500)
        end

        local note = label(host,
            "You can re-run this wizard any time from Settings → \"Run setup again\".",
            "AINPC_SetupSmall", C.sub, 22)
        note:Dock(TOP)
        note:DockMargin(0, 6, 0, 0)
    end

    local function renderProvider()
        stepTitle("Which AI provider?",
            "Pick one. You can change it later; each provider keeps its own key.")

        local list = vgui.Create("DPanel", host)
        list:Dock(TOP)
        list:SetTall(5 * 70)
        list.Paint = nil

        local buttons = {}

        local function refreshSelection()
            for id, b in pairs(buttons) do
                b.selected = (id == state.provider)
                b:InvalidateLayout(true)
            end
        end

        for i, choice in ipairs(PROVIDER_CHOICES) do
            local row = vgui.Create("DButton", list)
            row:SetPos(0, (i - 1) * 70)
            row:SetSize(566, 62)
            row:SetText("")
            row.providerId = choice.id
            row.Paint = function(s, w, h)
                local col = s.selected and Color(40, 72, 122) or (s:IsHovered() and Color(44, 44, 54) or Color(34, 34, 40))
                surface.SetDrawColor(col.r, col.g, col.b, 255)
                surface.DrawRect(0, 0, w, h)
                if s.selected then
                    surface.SetDrawColor(90, 165, 255)
                    surface.DrawRect(0, 0, 4, h)
                end
            end

            local title = label(row, choice.title, "AINPC_SetupHead", C.text, 24)
            title:SetPos(16, 10)
            title:SetWide(220)

            local badge = label(row, choice.badge, "AINPC_SetupSmall",
                choice.badge:find("free") and C.good or C.warn, 20)
            badge:SetPos(226, 13)
            badge:SetWide(320)

            local desc = label(row, choice.desc, "AINPC_SetupSmall", C.sub, 24, true)
            desc:SetPos(16, 34)
            desc:SetWide(534)

            row.DoClick = function()
                state.provider = choice.id
                state.key      = AINPCS.Trim(S.apiKeys[choice.id] or "")
                state.keyOk    = false
                refreshSelection()
                surface.PlaySound("ui/buttonclick.wav")
            end

            buttons[choice.id] = row
        end

        refreshSelection()

        local note = label(host,
            "Groq is the recommended start: free tier, no card, and fast enough that NPCs answer in a second or two.",
            "AINPC_SetupSmall", C.sub, 32, true)
        note:Dock(TOP)
        note:DockMargin(0, 8, 0, 0)
    end

    local function renderKey()
        local prov = AINPCS.ProviderSignup(state.provider)
        if not prov then
            stepTitle("Unknown provider", nil)
            return
        end

        if prov.local_ then
            stepTitle("Point it at your local model server",
                "Ollama runs on your own PC and needs no key. Enter the address Ollama is listening on.")

            local row = card(host, 76, C.cardAlt)
            row:Dock(TOP)
            row:DockMargin(0, 6, 0, 8)

            local lbl = label(row, "Ollama address", "AINPC_SetupSmall", C.sub, 20)
            lbl:SetPos(14, 10)

            local box = entryBox(row, "127.0.0.1:11434", 34)
            box:SetPos(14, 32)
            box:SetWide(400)
            box.entry:SetText(state.hostname or "")
            box.entry.OnValueChange = function(_, v)
                state.hostname = AINPCS.Trim(v or "")
            end

            local openBtn = openURLButton(host, "https://ollama.com/download", "Download Ollama…")
            openBtn:Dock(TOP)
            openBtn:DockMargin(0, 6, 0, 6)
            openBtn:SetWide(220)

            local info = label(host,
                "Local servers are reached from the server that runs the game. On a listen server that is your own PC; "
                .. "on a dedicated server the address must be reachable from that machine.",
                "AINPC_SetupSmall", C.sub, 56, true)
            info:Dock(TOP)

            state.keyOk = true
            return
        end

        stepTitle("Get your " .. prov.label .. " key",
            prov.note ~= "" and prov.note or nil)

        -- 1. create / find the key
        local stepOne = card(host, 78, C.cardAlt)
        stepOne:Dock(TOP)
        stepOne:DockMargin(0, 4, 0, 8)

        local t1 = label(stepOne, "1. Sign in and create an API key", "AINPC_SetupHead", C.text, 24)
        t1:SetPos(14, 10)

        local url1 = label(stepOne, prov.keyUrl, "AINPC_SetupSmall", C.accent, 20)
        url1:SetPos(14, 36)
        url1:SetWide(360)

        local openBtn = actionButton(stepOne, "Open key page", "primary", 150, 30)
        openBtn:SetPos(400, 26)
        openBtn.DoClick = function()
            gui.OpenURL(prov.keyUrl)
            surface.PlaySound("ui/buttonclick.wav")
        end

        -- 2. paste it
        local stepTwo = card(host, 116, C.cardAlt)
        stepTwo:Dock(TOP)
        stepTwo:DockMargin(0, 0, 0, 8)

        local t2 = label(stepTwo, "2. Paste the key here", "AINPC_SetupHead", C.text, 24)
        t2:SetPos(14, 10)

        local box = entryBox(stepTwo, "paste your key", 34)
        box:SetPos(14, 36)
        box:SetWide(400)
        box.entry:SetText(state.key or "")
        box.entry.OnValueChange = function(_, v) state.key = AINPCS.Trim(v or "") end

        local testBtn = actionButton(stepTwo, "Test & save", "good", 132, 34)
        testBtn:SetPos(422, 36)

        local status = label(stepTwo, "", "AINPC_SetupSmall", C.sub, 34, true)
        status:SetPos(14, 74)
        status:SetWide(540)

        if state.keyOk then
            setStatus(status, "Saved and verified.", "ok")
        elseif state.key ~= "" then
            setStatus(status, "A key is stored for this provider. Press Test & save to verify it again.", "warn")
        end

        testBtn.DoClick = function()
            local key = AINPCS.Trim(box.entry:GetValue() or "")
            if key == "" then
                setStatus(status, "Paste a key first.", "bad")
                return
            end

            setStatus(status, "Checking with " .. prov.label .. "…", "warn")
            testBtn:SetDisabled(true)

            AINPCS.TestProviderKey(state.provider, key, function(ok, message)
                if not IsValid(f) then return end
                testBtn:SetDisabled(false)

                if ok then
                    S.provider = state.provider
                    S.apiKeys[state.provider] = key
                    -- Let the panel pick the provider's own default model.
                    S.model = ""
                    AINPCS.SaveSettings()
                    state.keyOk = true
                    setStatus(status, "Key accepted and saved. Press Next.", "ok")
                else
                    state.keyOk = false
                    setStatus(status, message, "bad")
                end
            end)
        end

        local note = label(host,
            "Your key is saved on this PC only, in garrysmod/data/ai_npcs_settings.json. "
            .. "It is used to talk to the provider and is never shown to other players.",
            "AINPC_SetupSmall", C.sub, 40, true)
        note:Dock(TOP)
    end

    local function renderVoice()
        stepTitle("How should they sound?",
            "Free built-in voices work right now. A Fish Audio key unlocks cloned character voices.")

        local row = vgui.Create("DPanel", host)
        row:Dock(TOP)
        row:SetTall(60)
        row.Paint = nil

        local freeBtn = vgui.Create("DButton", row)
        freeBtn:SetPos(0, 0)
        freeBtn:SetSize(270, 54)
        freeBtn:SetText("")
        freeBtn.Paint = function(s, w, h)
            local sel = not state.wantFish
            local col = sel and Color(40, 72, 122) or (s:IsHovered() and Color(44, 44, 54) or Color(34, 34, 40))
            surface.SetDrawColor(col.r, col.g, col.b, 255)
            surface.DrawRect(0, 0, w, h)
            draw.SimpleText("Free built-in voices", "AINPC_SetupHead", 14, 14, C.text)
            draw.SimpleText("Google TTS + retro SAPI4 · no account", "AINPC_SetupSmall", 14, 34, C.sub)
        end
        freeBtn.DoClick = function()
            state.wantFish = false
            render()
        end

        local fishBtn = vgui.Create("DButton", row)
        fishBtn:SetPos(280, 0)
        fishBtn:SetSize(270, 54)
        fishBtn:SetText("")
        fishBtn.Paint = function(s, w, h)
            local sel = state.wantFish
            local col = sel and Color(40, 72, 122) or (s:IsHovered() and Color(44, 44, 54) or Color(34, 34, 40))
            surface.SetDrawColor(col.r, col.g, col.b, 255)
            surface.DrawRect(0, 0, w, h)
            draw.SimpleText("Fish Audio character voices", "AINPC_SetupHead", 14, 14, C.text)
            draw.SimpleText("Cloned voices · needs a key", "AINPC_SetupSmall", 14, 34, C.sub)
        end
        fishBtn.DoClick = function()
            state.wantFish = true
            render()
        end

        if not state.wantFish then
            local info = label(host,
                "Every NPC will speak with a free built-in voice. You can add Fish Audio later from Settings.",
                "AINPC_SetupSmall", C.sub, 40, true)
            info:Dock(TOP)
            info:DockMargin(0, 8, 0, 0)
            return
        end

        local stepOne = card(host, 74, C.cardAlt)
        stepOne:Dock(TOP)
        stepOne:DockMargin(0, 8, 0, 8)

        local t1 = label(stepOne, "1. Create a Fish Audio key", "AINPC_SetupHead", C.text, 24)
        t1:SetPos(14, 10)

        local url1 = label(stepOne, "https://fish.audio/app/api-keys/", "AINPC_SetupSmall", C.accent, 20)
        url1:SetPos(14, 36)
        url1:SetWide(360)

        local openBtn = actionButton(stepOne, "Open Fish Audio", "primary", 150, 30)
        openBtn:SetPos(400, 24)
        openBtn.DoClick = function()
            gui.OpenURL("https://fish.audio/app/api-keys/")
            surface.PlaySound("ui/buttonclick.wav")
        end

        local stepTwo = card(host, 116, C.cardAlt)
        stepTwo:Dock(TOP)
        stepTwo:DockMargin(0, 0, 0, 8)

        local t2 = label(stepTwo, "2. Paste the key here (optional)", "AINPC_SetupHead", C.text, 24)
        t2:SetPos(14, 10)

        local box = entryBox(stepTwo, "sk-fish-…", 34)
        box:SetPos(14, 36)
        box:SetWide(400)
        box.entry:SetText(state.fishKey or "")
        box.entry.OnValueChange = function(_, v) state.fishKey = AINPCS.Trim(v or "") end

        local testBtn = actionButton(stepTwo, "Test & save", "good", 132, 34)
        testBtn:SetPos(422, 36)

        local status = label(stepTwo, "", "AINPC_SetupSmall", C.sub, 34, true)
        status:SetPos(14, 74)
        status:SetWide(540)

        if state.fishOk then
            setStatus(status, "Fish Audio key saved.", "ok")
        end

        testBtn.DoClick = function()
            local key = AINPCS.Trim(box.entry:GetValue() or "")
            if key == "" then
                setStatus(status, "Paste a key, or press Skip for now.", "bad")
                return
            end

            setStatus(status, "Checking with Fish Audio…", "warn")
            testBtn:SetDisabled(true)

            AINPCS.RelaySaveKey(key, function(ok, code, body)
                if not IsValid(f) then return end
                testBtn:SetDisabled(false)
                if ok then
                    state.fishOk = true
                    setStatus(status, "Key accepted and saved.", "ok")
                else
                    state.fishOk = false
                    local err = (istable(body) and body.error) or ("HTTP " .. tostring(code))
                    setStatus(status, tostring(err), "bad")
                end
            end)
        end

        local note = label(host,
            "Fish Audio voices cost credit per spoken line and are rendered by the server, so everyone nearby hears the same voice. "
            .. "You can skip this now and add it later.",
            "AINPC_SetupSmall", C.sub, 40, true)
        note:Dock(TOP)
    end

    local function renderDone()
        stepTitle("You're set up", "Here is what the addon will use.")

        local function summaryLine(kind, value, ok)
            local row = card(host, 40, C.cardAlt)
            row:Dock(TOP)
            row:DockMargin(0, 0, 0, 6)

            local k = label(row, kind, "AINPC_SetupSmall", C.sub, 20)
            k:SetPos(14, 11)
            k:SetWide(170)

            local v = label(row, value, "AINPC_SetupBody", ok and C.text or C.warn, 20)
            v:SetPos(190, 11)
            v:SetWide(360)
        end

        local prov = providers.get(S.provider)
        local key = AINPCS.Trim((S.apiKeys[S.provider] or ""))
        local hasKey = (S.provider == "ollama") or key ~= ""

        summaryLine("AI provider", (prov and prov.label) or S.provider, hasKey)
        summaryLine("API key", hasKey and ("saved (" .. AINPCS.RedactKey(key) .. ")") or "not set yet", hasKey)
        summaryLine("Voice", AINPCS.Trim(S.fishKey or "") ~= "" and "Fish Audio + free built-ins" or "free built-in voices", true)
        summaryLine("Storage", "garrysmod/data/ai_npcs_settings.json", true)

        local gapSpacer = vgui.Create("DPanel", host)
        gapSpacer:Dock(TOP)
        gapSpacer:SetTall(14)
        gapSpacer.Paint = nil

        local hint = label(host,
            "Next: open the panel and build a character. Press E on an AI NPC in game to talk.",
            "AINPC_SetupSmall", C.sub, 22, true)
        hint:Dock(TOP)

        if not hasKey then
            local warn = label(host,
                "No AI key yet — you can still open the panel, but NPCs will not be able to reply until you add one.",
                "AINPC_SetupSmall", C.warn, 36, true)
            warn:Dock(TOP)
        end
    end

    -- =====================================================================
    -- Step machine
    -- =====================================================================

    render = function()
        host:Clear()

        for i, entry in pairs(railLabels) do
            entry.row.active = (i == state.step)
            entry.row:InvalidateLayout(true)
            entry.dot:SetTextColor(i <= state.step and C.text or C.sub)
            entry.lbl:SetTextColor(i == state.step and C.text or C.sub)
        end

        backBtn:SetVisible(state.step > 1)
        skipBtn:SetVisible(state.step < 5)
        nextBtn:SetLabel(state.step == 5 and "Open AI NPCs" or "Next")

        -- A key step with no verified key should not let you slip past silently,
        -- but it is still allowed (the player may already have a working setup).
        if state.step == 1 then renderWelcome()
        elseif state.step == 2 then renderProvider()
        elseif state.step == 3 then renderKey()
        elseif state.step == 4 then renderVoice()
        else renderDone() end
    end

    local function goStep(n)
        state.step = math.Clamp(n, 1, #STEPS)
        if state.step == 4 and state.fishOk == nil then state.fishOk = false end
        render()
    end

    backBtn.DoClick = function() goStep(state.step - 1) end

    skipBtn.DoClick = function()
        if state.step == 3 then
            -- do not silently skip a key they typed but never verified
            if state.key ~= "" and not state.keyOk then
                S.provider = state.provider
                S.apiKeys[state.provider] = state.key
                AINPCS.SaveSettings()
            end
            if AINPCS.Trim(state.hostname or "") ~= "" then
                S.hostname = state.hostname
                AINPCS.SaveSettings()
            end
            goStep(4)
            return
        end

        if state.step == 4 then
            goStep(5)
            return
        end

        f:Close()
        if opts.onClose then opts.onClose() end
    end

    nextBtn.DoClick = function()
        surface.PlaySound("ui/buttonclick.wav")

        if state.step == 2 then
            -- carry the provider choice forward even before a key is verified
            S.provider = state.provider
            S.model = ""
            AINPCS.SaveSettings()
            goStep(3)
            return
        end

        if state.step == 3 then
            if AINPCS.Trim(state.hostname or "") ~= "" then
                S.hostname = state.hostname
            end
            if state.key ~= "" then
                S.apiKeys[state.provider] = state.key
                S.provider = state.provider
            end
            AINPCS.SaveSettings()
            goStep(4)
            return
        end

        if state.step == 4 then
            goStep(5)
            return
        end

        if state.step == 5 then
            f:Close()
            if AINPCS.Open then
                timer.Simple(0, function() AINPCS.Open() end)
            end
            return
        end

        goStep(state.step + 1)
    end

    f.OnRemove = function()
        AINPCS.SetupWizard = nil
        AINPCS.SaveSettings()
        if opts.onClose then opts.onClose() end
    end

    render()
    return f
end

concommand.Add("ainpc_setup", function()
    AINPCS.OpenSetupWizard({ rerun = true })
end)
