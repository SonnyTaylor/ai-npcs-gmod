--[[
    AI NPCs — client config UI
    The panel opened from C menu → AI NPCs. Lets the user pick a provider,
    model, NPC class, enter an API key, and spawn.
]]

local providers = include("providers/providers.lua")
local Voices    = include("voices/voices.lua")

-- Each player points at their OWN relay (which holds their OWN Fish Audio key), so
-- this is a client convar. The server's ainpc_voice_relay only supplies a default.
local cvVoiceRelay = CreateClientConVar("ainpc_voice_relay_url", "", true, false,
    "Base URL of your local AI NPCs voice relay. Empty = server default / 127.0.0.1:7171")

local function relayBase()
    local url = cvVoiceRelay and cvVoiceRelay:GetString() or ""
    if url == "" then url = GetGlobalString("AINPCVoiceRelay", "") or "" end
    if url == "" then url = "http://127.0.0.1:7171" end
    return (string.gsub(url, "/+$", ""))
end

local function relayRequest(path, callback)
    HTTP({
        url = relayBase() .. path,
        method = "get",
        headers = { ["Accept"] = "application/json" },
        success = function(code, body)
            local parsed = (code == 200) and AINPCS.SafeJSON(body) or nil
            callback(istable(parsed) and parsed.voices or nil, code)
        end,
        failed = function(err) callback(nil, err) end,
    })
end

local function registerRelayVoices(list)
    local added = 0
    for _, v in ipairs(list or {}) do
        if isstring(v.name) and isstring(v.label) and not Voices.Get("relay:" .. v.name) then
            Voices.Register("relay:" .. v.name, v.label)
            added = added + 1
        end
    end
    return added
end

-- =============================================================================
-- Persisted settings (stored client-side so the user doesn't re-enter keys).
-- =============================================================================

local SETTINGS_FILE = "ai_npcs_settings.json"

local defaultSettings = {
    provider    = "groq",
    apiKeys     = {},     -- [providerId] = key
    hostname    = "127.0.0.1:11434",
    personality = "",
    npcClass    = "npc_citizen",
    model       = "",
    enableTTS   = true,
    ttsVoice    = "google:en",
    max_tokens  = 2048,
    temperature = 1,
    reasoning   = nil,
    name        = "",
    firstRun    = true,
    freeOnly    = true,      -- OpenRouter: hide paid models until the user opts in
}

local function loadSettings()
    if not file.Exists(SETTINGS_FILE, "DATA") then
        return table.Copy(defaultSettings)
    end
    local raw = file.Read(SETTINGS_FILE, "DATA") or ""
    local parsed = util.JSONToTable(raw, true)
    if not istable(parsed) then return table.Copy(defaultSettings) end
    for k, v in pairs(defaultSettings) do
        if parsed[k] == nil then parsed[k] = v end
    end
    if not istable(parsed.apiKeys) then parsed.apiKeys = {} end

    -- Migrate voice ids from older builds (e.g. "streamelements", "sapi4") that are
    -- no longer in the registry, so an old settings file doesn't silence the NPCs.
    if parsed.enableTTS and not Voices.Get(parsed.ttsVoice) then
        parsed.ttsVoice = Voices.Default
    end

    return parsed
end

local function saveSettings(s)
    file.Write(SETTINGS_FILE, util.TableToJSON(s))
end

local Settings = loadSettings()

-- =============================================================================
-- OpenRouter live model cache (populated by net message from server)
-- =============================================================================

local LiveOpenRouterModels = nil  -- { order = {...}, models = {...} }
local OpenRouterBuffer = { chunks = {}, expect = 0 }

net.Receive("AINPC_OpenRouterModels", function()
    local idx   = net.ReadUInt(8)
    local total = net.ReadUInt(8)
    local sz    = net.ReadUInt(20)
    local slice = net.ReadData(sz)

    if idx == 1 then
        OpenRouterBuffer.chunks = {}
        OpenRouterBuffer.expect = total
    end
    OpenRouterBuffer.chunks[idx] = slice

    if idx ~= total then return end

    local payload = table.concat(OpenRouterBuffer.chunks)
    OpenRouterBuffer = { chunks = {}, expect = 0 }

    local parsed = util.JSONToTable(payload or "", true)
    if istable(parsed) and istable(parsed.order) and istable(parsed.models) then
        LiveOpenRouterModels = parsed
        AINPCS.DebugPrint("[AI-NPCs] received " .. #parsed.order .. " live OpenRouter models")
        if AINPCS.Panel and IsValid(AINPCS.Panel) then
            AINPCS.Panel:ReloadProviderModels()
        end
    end
end)

-- =============================================================================
-- Fonts
-- =============================================================================

surface.CreateFont("AINPC_Header", { font = "Roboto", size = 22, weight = 700 })
surface.CreateFont("AINPC_Body",   { font = "Roboto", size = 16, weight = 400 })
surface.CreateFont("AINPC_Small",  { font = "Roboto", size = 13, weight = 400 })

-- =============================================================================
-- Desktop window entry
-- =============================================================================

list.Set("DesktopWindows", "ai_npcs_menu", {
    title = "AI NPCs",
    icon  = "materials/gptlogo/ChatGPT_logo.svg.png",
    init  = function() AINPCS.OpenConfigPanel() end,
})

concommand.Add("ainpc_open", function() AINPCS.OpenConfigPanel() end)

-- =============================================================================
-- Helpers
-- =============================================================================

local labelColor = Color(235, 235, 235)
local subColor   = Color(170, 170, 170)
local accent     = Color(90, 165, 255)
local errColor   = Color(235, 80, 80)
local okColor    = Color(90, 200, 120)

local function Section(parent, title)
    local p = vgui.Create("DPanel", parent)
    p:Dock(TOP)
    p:DockMargin(0, 0, 0, 10)
    p:DockPadding(12, 10, 12, 12)
    p.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(40, 40, 44))
    end

    if title then
        local lbl = vgui.Create("DLabel", p)
        lbl:SetFont("AINPC_Header")
        lbl:SetText(title)
        lbl:SetTextColor(labelColor)
        lbl:Dock(TOP)
        lbl:SetTall(26)
        lbl:DockMargin(0, 0, 0, 6)
    end

    return p
end

local function LabeledEntry(parent, label, placeholder)
    local lbl = vgui.Create("DLabel", parent)
    lbl:SetText(label)
    lbl:SetFont("AINPC_Body")
    lbl:SetTextColor(labelColor)
    lbl:Dock(TOP)
    lbl:SetTall(18)

    local entry = vgui.Create("DTextEntry", parent)
    entry:Dock(TOP)
    entry:SetTall(26)
    entry:DockMargin(0, 2, 0, 8)
    if placeholder then entry:SetPlaceholderText(placeholder) end
    return entry
end

local function getModelMap(providerId)
    if providerId == "openrouter" and LiveOpenRouterModels then
        return LiveOpenRouterModels.order, LiveOpenRouterModels.models
    end
    local p = providers.get(providerId)
    if not p then return {}, {} end
    return p.modelOrder or {}, p.models or {}
end

-- =============================================================================
-- Onboarding modal
-- =============================================================================

local function ShowOnboarding()
    local f = vgui.Create("DFrame")
    f:SetSize(520, 360)
    f:Center()
    f:SetTitle("AI NPCs — Welcome")
    f:MakePopup()
    f:SetBackgroundBlur(true)

    local body = vgui.Create("DPanel", f)
    body:Dock(FILL)
    body:DockPadding(20, 16, 20, 16)
    body.Paint = nil

    local header = vgui.Create("DLabel", body)
    header:SetFont("AINPC_Header")
    header:SetText("You need a free API key to use AI NPCs")
    header:SetTextColor(labelColor)
    header:Dock(TOP)
    header:SetTall(30)

    local para = vgui.Create("DLabel", body)
    para:SetFont("AINPC_Body")
    para:SetTextColor(subColor)
    para:SetWrap(true)
    para:SetAutoStretchVertical(true)
    para:Dock(TOP)
    para:DockMargin(0, 6, 0, 12)
    para:SetText(
        "This addon talks to real AI services, which all need an API key. Good news: two providers have genuinely free tiers that work for casual play.\n\n" ..
        "• Groq — easiest. Sign up with Google, no credit card ever. Daily rate limit is generous.\n" ..
        "• OpenRouter — more models including free reasoning models. Lower daily cap on the $0 tier.\n\n" ..
        "Click a button below to open the signup page. Paste your key into the AI NPCs panel."
    )

    local buttons = vgui.Create("DPanel", body)
    buttons:Dock(TOP)
    buttons:SetTall(40)
    buttons.Paint = nil

    local groqBtn = vgui.Create("DButton", buttons)
    groqBtn:Dock(LEFT)
    groqBtn:SetWide(220)
    groqBtn:DockMargin(0, 0, 10, 0)
    groqBtn:SetText("Get free Groq key")
    groqBtn.DoClick = function() gui.OpenURL("https://console.groq.com/keys") end

    local orBtn = vgui.Create("DButton", buttons)
    orBtn:Dock(LEFT)
    orBtn:SetWide(240)
    orBtn:SetText("Get free OpenRouter key")
    orBtn.DoClick = function() gui.OpenURL("https://openrouter.ai/keys") end

    local dismiss = vgui.Create("DButton", body)
    dismiss:Dock(BOTTOM)
    dismiss:SetTall(34)
    dismiss:DockMargin(0, 10, 0, 0)
    dismiss:SetText("Got it — don't show this again")
    dismiss.DoClick = function()
        Settings.firstRun = false
        saveSettings(Settings)
        f:Close()
    end
end

-- =============================================================================
-- Config panel
-- =============================================================================

function AINPCS.OpenConfigPanel()
    if IsValid(AINPCS.Panel) then
        AINPCS.Panel:Remove()
    end

    local frame = vgui.Create("DFrame")
    frame:SetSize(980, 620)
    frame:Center()
    frame:SetTitle("AI NPCs — spawn config  (v" .. AINPCS.Version .. ")")
    frame:MakePopup()
    frame:SetDraggable(true)
    frame:SetBackgroundBlur(true)
    frame:SetIcon("materials/gptlogo/ChatGPT_logo.svg.png")
    AINPCS.Panel = frame

    -- ---- Footer ----
    -- Dock this BEFORE the content panel: GMod docks in creation order, so a FILL
    -- sibling created first would eat the whole frame and bury the spawn button in a
    -- scroll area (the "there is no Spawn NPC button" reports).
    local footer = vgui.Create("DPanel", frame)
    footer:Dock(BOTTOM)
    footer:SetTall(70)
    footer:DockPadding(12, 10, 12, 12)
    footer.Paint = function(s, w, h) draw.RoundedBox(6, 0, 0, w, h, Color(34, 34, 38)) end

    local statusLabel = vgui.Create("DLabel", footer)
    statusLabel:Dock(LEFT)
    statusLabel:SetWide(620)
    statusLabel:SetFont("AINPC_Body")
    statusLabel:SetTextColor(subColor)
    statusLabel:SetText("")

    local spawnBtn = vgui.Create("DButton", footer)
    spawnBtn:Dock(RIGHT)
    spawnBtn:SetWide(200)
    spawnBtn:SetTall(44)
    spawnBtn:SetText("Spawn NPC")
    spawnBtn:SetFont("AINPC_Header")

    -- ---- Layout ----
    local content = vgui.Create("DPanel", frame)
    content:Dock(FILL)
    content:DockPadding(12, 12, 12, 12)
    content.Paint = nil

    -- ---- Left column: 3D model preview ----
    local leftCol = vgui.Create("DPanel", content)
    leftCol:Dock(LEFT)
    leftCol:SetWide(240)
    leftCol:DockMargin(0, 0, 10, 0)
    leftCol.Paint = function(s, w, h) draw.RoundedBox(6, 0, 0, w, h, Color(30, 30, 34)) end

    local modelHeader = vgui.Create("DLabel", leftCol)
    modelHeader:SetFont("AINPC_Header")
    modelHeader:SetText("Preview")
    modelHeader:SetTextColor(labelColor)
    modelHeader:Dock(TOP)
    modelHeader:DockMargin(12, 10, 12, 4)
    modelHeader:SetTall(24)

    local mp = vgui.Create("DModelPanel", leftCol)
    mp:Dock(FILL)
    mp:DockMargin(8, 0, 8, 8)
    mp:SetModel("models/humans/group01/male_07.mdl")
    mp:SetFOV(48)
    mp.LayoutEntity = function(self, ent)
        self:RunAnimation()
        ent:SetAngles(Angle(0, RealTime() * 80, 0))
    end

    -- ---- Middle column: Provider + NPC ----
    local middleCol = vgui.Create("DScrollPanel", content)
    middleCol:Dock(LEFT)
    middleCol:SetWide(340)
    middleCol:DockMargin(0, 0, 10, 0)

    -- ---- Right column: Settings ----
    local rightCol = vgui.Create("DScrollPanel", content)
    rightCol:Dock(FILL)

    -- ---- Provider section ----
    local providerSection = Section(middleCol, "Provider")

    local providerDropdown = vgui.Create("DComboBox", providerSection)
    providerDropdown:Dock(TOP)
    providerDropdown:SetTall(26)
    providerDropdown:DockMargin(0, 0, 0, 8)
    for _, p in ipairs(providers.list()) do
        providerDropdown:AddChoice(p.label, p.id, p.id == Settings.provider)
    end

    local providerNote = vgui.Create("DLabel", providerSection)
    providerNote:Dock(TOP)
    providerNote:SetFont("AINPC_Small")
    providerNote:SetTextColor(subColor)
    providerNote:SetWrap(true)
    providerNote:SetAutoStretchVertical(true)
    providerNote:DockMargin(0, 0, 0, 8)
    providerNote:SetText("")

    local getKeyBtn = vgui.Create("DButton", providerSection)
    getKeyBtn:Dock(TOP)
    getKeyBtn:SetTall(28)
    getKeyBtn:SetText("Get free key →")

    -- ---- Model section ----
    local modelSection = Section(middleCol, "Model")

    local hostnameLabel = vgui.Create("DLabel", modelSection)
    hostnameLabel:Dock(TOP)
    hostnameLabel:SetTall(18)
    hostnameLabel:SetText("Hostname:")
    hostnameLabel:SetFont("AINPC_Body")
    hostnameLabel:SetTextColor(labelColor)
    hostnameLabel:SetVisible(false)

    local hostnameEntry = vgui.Create("DTextEntry", modelSection)
    hostnameEntry:Dock(TOP)
    hostnameEntry:SetTall(26)
    hostnameEntry:DockMargin(0, 2, 0, 8)
    hostnameEntry:SetText(Settings.hostname or "")
    hostnameEntry:SetPlaceholderText("127.0.0.1:11434")
    hostnameEntry:SetVisible(false)

    local modelLabel = vgui.Create("DLabel", modelSection)
    modelLabel:Dock(TOP)
    modelLabel:SetTall(18)
    modelLabel:SetText("Model:")
    modelLabel:SetFont("AINPC_Body")
    modelLabel:SetTextColor(labelColor)

    -- Forward-declared: the filter needs to re-run the model population that is
    -- defined further down.
    local populateModels
    local modelFilterText = ""

    local modelFilter = vgui.Create("DTextEntry", modelSection)
    modelFilter:Dock(TOP)
    modelFilter:SetTall(24)
    modelFilter:DockMargin(0, 2, 0, 4)
    modelFilter:SetPlaceholderText("Filter models…")
    modelFilter.OnValueChange = function(_, value)
        modelFilterText = string.lower(AINPCS.Trim(value or ""))
        if populateModels then populateModels() end
    end

    -- Unticking this is the "I'm happy to pay" switch: it reveals the paid catalog
    -- and preselects the provider's defaultModel (cheap + fast DeepSeek on OpenRouter).
    local freeOnlyCheck = vgui.Create("DCheckBoxLabel", modelSection)
    freeOnlyCheck:Dock(TOP)
    freeOnlyCheck:SetText("Free models only")
    freeOnlyCheck:SetValue(Settings.freeOnly ~= false)
    if freeOnlyCheck.Label then freeOnlyCheck.Label:SetTextColor(labelColor) end
    freeOnlyCheck:DockMargin(0, 0, 0, 6)
    freeOnlyCheck.OnChange = function(_, value)
        Settings.freeOnly = value
        if populateModels then populateModels() end
    end

    local modelDropdown = vgui.Create("DComboBox", modelSection)
    modelDropdown:Dock(TOP)
    modelDropdown:SetTall(26)
    modelDropdown:DockMargin(0, 2, 0, 4)

    local modelCustomEntry = vgui.Create("DTextEntry", modelSection)
    modelCustomEntry:Dock(TOP)
    modelCustomEntry:SetTall(26)
    modelCustomEntry:DockMargin(0, 2, 0, 8)
    modelCustomEntry:SetPlaceholderText("e.g. llama3:8b")
    modelCustomEntry:SetVisible(false)

    -- ---- NPC section ----
    local npcSection = Section(middleCol, "NPC")

    local nameEntry = LabeledEntry(npcSection, "Character name", "e.g. Barney the bartender")
    nameEntry:SetText(Settings.name or "")

    local npcClassLbl = vgui.Create("DLabel", npcSection)
    npcClassLbl:Dock(TOP)
    npcClassLbl:SetTall(18)
    npcClassLbl:SetText("NPC class")
    npcClassLbl:SetFont("AINPC_Body")
    npcClassLbl:SetTextColor(labelColor)

    local npcDropdown = vgui.Create("DComboBox", npcSection)
    npcDropdown:Dock(TOP)
    npcDropdown:SetTall(26)
    npcDropdown:DockMargin(0, 2, 0, 8)

    local npcRegistry = list.Get("NPC") or {}
    local npcIds = {}
    for id, _ in pairs(npcRegistry) do table.insert(npcIds, id) end
    table.sort(npcIds)
    for _, id in ipairs(npcIds) do
        local data = npcRegistry[id]
        local label = (data and data.Name) or id
        npcDropdown:AddChoice(label, id, id == Settings.npcClass)
    end

    function npcDropdown:OnSelect(_, _, id)
        Settings.npcClass = id
        net.Start("AINPC_ModelPreview")
        net.WriteString(id or "")
        net.SendToServer()
    end

    -- ---- Settings section (right col) ----
    local settingsSection = Section(rightCol, "Settings")
    local personalityLbl = vgui.Create("DLabel", settingsSection)
    personalityLbl:Dock(TOP)
    personalityLbl:SetText("Character description")
    personalityLbl:SetFont("AINPC_Body")
    personalityLbl:SetTextColor(labelColor)
    personalityLbl:SetTall(18)

    local personalityHint = vgui.Create("DLabel", settingsSection)
    personalityHint:Dock(TOP)
    personalityHint:SetFont("AINPC_Small")
    personalityHint:SetTextColor(subColor)
    personalityHint:SetTall(16)
    personalityHint:SetText("Who are they? How do they act? A grumpy bartender? A paranoid scientist?")

    local personalityEntry = vgui.Create("DTextEntry", settingsSection)
    personalityEntry:Dock(TOP)
    personalityEntry:SetTall(70)
    personalityEntry:SetMultiline(true)
    personalityEntry:DockMargin(0, 4, 0, 10)
    personalityEntry:SetText(Settings.personality or "")

    local keyLabel = vgui.Create("DLabel", settingsSection)
    keyLabel:Dock(TOP)
    keyLabel:SetTall(18)
    keyLabel:SetFont("AINPC_Body")
    keyLabel:SetTextColor(labelColor)
    keyLabel:SetText("API Key")

    local keyEntry = vgui.Create("DTextEntry", settingsSection)
    keyEntry:Dock(TOP)
    keyEntry:SetTall(26)
    keyEntry:DockMargin(0, 2, 0, 10)
    keyEntry:SetPlaceholderText("Paste your key here")

    local maxTokSlider = vgui.Create("DNumSlider", settingsSection)
    maxTokSlider:Dock(TOP)
    maxTokSlider:SetTall(44)
    maxTokSlider:DockMargin(0, 0, 0, 4)
    maxTokSlider:SetText("Max tokens")
    maxTokSlider.Label:SetTextColor(labelColor)
    maxTokSlider:SetMin(64)
    maxTokSlider:SetMax(4096)
    maxTokSlider:SetDecimals(0)
    maxTokSlider:SetValue(Settings.max_tokens or 2048)

    local tempSlider = vgui.Create("DNumSlider", settingsSection)
    tempSlider:Dock(TOP)
    tempSlider:SetTall(44)
    tempSlider:DockMargin(0, 0, 0, 4)
    tempSlider:SetText("Temperature")
    tempSlider.Label:SetTextColor(labelColor)
    tempSlider:SetMin(0)
    tempSlider:SetMax(2)
    tempSlider:SetDecimals(2)
    tempSlider:SetValue(Settings.temperature or 1)

    local reasoningLabel = vgui.Create("DLabel", settingsSection)
    reasoningLabel:Dock(TOP)
    reasoningLabel:SetTall(18)
    reasoningLabel:SetFont("AINPC_Body")
    reasoningLabel:SetTextColor(labelColor)
    reasoningLabel:SetText("Reasoning effort")
    reasoningLabel:SetVisible(false)

    local reasoningDropdown = vgui.Create("DComboBox", settingsSection)
    reasoningDropdown:Dock(TOP)
    reasoningDropdown:SetTall(26)
    reasoningDropdown:DockMargin(0, 2, 0, 10)
    reasoningDropdown:SetVisible(false)

    local ttsLabel = vgui.Create("DLabel", settingsSection)
    ttsLabel:Dock(TOP)
    ttsLabel:SetTall(18)
    ttsLabel:SetFont("AINPC_Body")
    ttsLabel:SetTextColor(labelColor)
    ttsLabel:SetText("Voice")

    local voiceDropdown = vgui.Create("DComboBox", settingsSection)
    voiceDropdown:Dock(TOP)
    voiceDropdown:SetTall(26)
    voiceDropdown:DockMargin(0, 2, 0, 4)

    -- Rebuilt whenever the relay hands us more voices (search results, presets).
    local function fillVoiceDropdown(selectedId)
        local current = selectedId or (Settings.enableTTS and Settings.ttsVoice) or "off"
        voiceDropdown:Clear()
        voiceDropdown:AddChoice("Off — text only", "off", current == "off")
        local picked = false
        for _, v in ipairs(Voices.list) do
            local isCurrent = (v.id == current)
            voiceDropdown:AddChoice(v.label, v.id, isCurrent)
            picked = picked or isCurrent
        end
        if not picked and current ~= "off" then
            -- A relay voice id that this client's relay no longer lists.
            voiceDropdown:AddChoice(current .. " (missing)", current, true)
        end
    end
    fillVoiceDropdown()

    local voiceSearchEntry = vgui.Create("DTextEntry", settingsSection)
    voiceSearchEntry:Dock(TOP)
    voiceSearchEntry:SetTall(24)
    voiceSearchEntry:DockMargin(0, 6, 0, 4)
    voiceSearchEntry:SetPlaceholderText("Search relay voices (e.g. peter griffin) or paste a model id")

    local voiceSearchBtn = vgui.Create("DButton", settingsSection)
    voiceSearchBtn:Dock(TOP)
    voiceSearchBtn:SetTall(24)
    voiceSearchBtn:DockMargin(0, 0, 0, 4)
    voiceSearchBtn:SetText("Search voices")

    local voiceResults = vgui.Create("DComboBox", settingsSection)
    voiceResults:Dock(TOP)
    voiceResults:SetTall(26)
    voiceResults:DockMargin(0, 0, 0, 4)
    voiceResults:SetText("Search results appear here")

    local relaySetupBtn = vgui.Create("DButton", settingsSection)
    relaySetupBtn:Dock(TOP)
    relaySetupBtn:SetTall(22)
    relaySetupBtn:DockMargin(0, 0, 0, 16)
    relaySetupBtn:SetText("Voice relay setup (your own API key)")

    local testVoiceBtn = vgui.Create("DButton", settingsSection)
    testVoiceBtn:Dock(TOP)
    testVoiceBtn:SetTall(24)
    testVoiceBtn:DockMargin(0, 0, 0, 16)
    testVoiceBtn:SetText("Test voice")
    testVoiceBtn.DoClick = function()
        local _, id = voiceDropdown:GetSelected()
        if not id or id == "off" then
            AINPCS.PushToast("Pick a voice first.", "info")
            return
        end
        if not AINPCS.PreviewVoice(id) then
            AINPCS.PushToast("That voice needs the relay — set ainpc_voice_relay.", "error")
        end
    end

    local howTo = vgui.Create("DLabel", settingsSection)
    howTo:Dock(TOP)
    howTo:SetTall(48)
    howTo:DockMargin(0, 10, 0, 0)
    howTo:SetFont("AINPC_Small")
    howTo:SetTextColor(subColor)
    howTo:SetWrap(true)
    howTo:SetAutoStretchVertical(true)
    howTo:SetText("After spawning: walk up to the NPC and press E to open a chat window, or just type in chat when you're nearby. Use /say <message> to talk from anywhere.")

    -- =============================================================================
    -- Reactivity
    -- =============================================================================

    local currentProviderId = Settings.provider or "groq"
    local currentModelId = Settings.model or ""
    local currentReasoning = Settings.reasoning

    -- One line that always tells the truth about what will be sent on spawn.
    local function refreshStatus()
        local p = providers.get(currentProviderId)
        local keyOk = currentProviderId == "ollama" or not AINPCS.IsBlank(Settings.apiKeys[currentProviderId])

        local _, selectedVoice = voiceDropdown:GetSelected()
        local voiceText = (selectedVoice and selectedVoice ~= "off") and selectedVoice or "voice off"

        local parts = {
            (p and p.label) or currentProviderId,
            (currentModelId ~= "" and currentModelId) or "no model selected",
            voiceText,
        }

        local text = table.concat(parts, "   •   ")
        if keyOk then
            statusLabel:SetTextColor(subColor)
            statusLabel:SetText(text)
        else
            statusLabel:SetTextColor(errColor)
            statusLabel:SetText(text .. "      —  API key required")
        end
    end

    function voiceDropdown:OnSelect(_, _, id)
        Settings.enableTTS = id ~= "off"
        Settings.ttsVoice  = id
        refreshStatus()
    end

    keyEntry.OnValueChange = function(_, value)
        Settings.apiKeys[currentProviderId] = AINPCS.Trim(value or "")
        refreshStatus()
    end

    -- ---- Voice relay (each player supplies their own Fish Audio key there) ----
    local function applyVoiceSearchResults(voices, err)
        voiceResults:Clear()

        if not voices or #voices == 0 then
            voiceResults:SetText("No matches" .. (err and (" (" .. tostring(err) .. ")") or ""))
            AINPCS.PushToast("Voice relay: " .. tostring(err or "no matches") .. " — is it running at " .. relayBase() .. "?", "error")
            return
        end

        registerRelayVoices(voices)
        for _, v in ipairs(voices) do
            voiceResults:AddChoice(v.label, v.name, false)
        end
        voiceResults:SetText(string.format("%d result%s — pick one", #voices, #voices == 1 and "" or "s"))
    end

    local function runVoiceSearch()
        local query = AINPCS.Trim(voiceSearchEntry:GetValue() or "")
        if query == "" then
            -- Empty search = show whatever the relay knows about, capped.
            relayRequest("/voices?limit=40", applyVoiceSearchResults)
            return
        end

        -- 32-hex is a model id; anything else is a title search.
        local path
        if #query >= 20 and string.match(query, "^%x+$") then
            path = "/voices?id=" .. query
        else
            path = "/voices?q=" .. Voices.Encode(query) .. "&limit=25"
        end
        relayRequest(path, applyVoiceSearchResults)
    end

    voiceSearchBtn.DoClick = runVoiceSearch
    voiceSearchEntry.OnEnter = runVoiceSearch
    relaySetupBtn.DoClick = function() gui.OpenURL(relayBase() .. "/") end

    function voiceResults:OnSelect(_, _, name)
        if not isstring(name) then return end
        local id = "relay:" .. name
        if not Voices.Get(id) then
            -- Picked something we only have an id for; label it and move on.
            Voices.Register(id, "relay:" .. name:sub(1, 8))
            fillVoiceDropdown(id)
        end
        fillVoiceDropdown(id)
        Settings.ttsVoice = id
        Settings.enableTTS = true
        refreshStatus()
        AINPCS.PushToast("Voice set to " .. id, "success")
    end

    local function requestOpenRouterModels()
        if currentProviderId ~= "openrouter" then return end
        net.Start("AINPC_RequestORModels")
        net.SendToServer()
    end

    local function refreshKeyEntry()
        local p = providers.get(currentProviderId)
        if not p then return end
        keyEntry:SetText(Settings.apiKeys[currentProviderId] or "")
        keyEntry:SetEditable(true)
        keyLabel:SetText(p.id == "ollama" and "API Key (optional)" or "API Key")
        getKeyBtn:SetText("Get " .. (p.id == "ollama" and "Ollama" or "free") .. " key →")
        getKeyBtn.DoClick = function() gui.OpenURL(p.getKeyUrl) end
        providerNote:SetText(p.note or "")
        refreshStatus()
    end

    local function applyModelSettings(modelData)
        if not istable(modelData) then
            modelCustomEntry:SetVisible(true)
            reasoningLabel:SetVisible(false)
            reasoningDropdown:SetVisible(false)
            return
        end

        local mt = modelData.max_tokens or {}
        maxTokSlider:SetMin(mt.min or 64)
        maxTokSlider:SetMax(mt.max or 4096)
        local curMT = maxTokSlider:GetValue()
        if curMT < (mt.min or 64) or curMT > (mt.max or 4096) then
            maxTokSlider:SetValue(mt.default or 2048)
        end

        local t = modelData.temperature or {}
        tempSlider:SetMin(t.min or 0)
        tempSlider:SetMax(t.max or 2)
        local curT = tempSlider:GetValue()
        if curT < (t.min or 0) or curT > (t.max or 2) then
            tempSlider:SetValue(t.default or 1)
        end
        local locked = (t.min == t.max)
        tempSlider:SetEnabled(not locked)
        if locked then tempSlider:SetValue(t.min) end

        if istable(modelData.reasoning) and #modelData.reasoning > 0 then
            reasoningLabel:SetVisible(true)
            reasoningDropdown:SetVisible(true)
            reasoningDropdown:Clear()
            local matched = false
            for i, effort in ipairs(modelData.reasoning) do
                reasoningDropdown:AddChoice(effort:sub(1,1):upper() .. effort:sub(2), effort, effort == currentReasoning)
                if effort == currentReasoning then matched = true end
            end
            if not matched then
                reasoningDropdown:ChooseOptionID(1)
                currentReasoning = modelData.reasoning[1]
            end
        else
            reasoningLabel:SetVisible(false)
            reasoningDropdown:SetVisible(false)
            currentReasoning = nil
        end
    end

    populateModels = function()
        modelDropdown:Clear()
        local order, models = getModelMap(currentProviderId)
        local p = providers.get(currentProviderId)

        local isOpenRouter = (currentProviderId == "openrouter")
        freeOnlyCheck:SetVisible(isOpenRouter)
        local freeOnly = isOpenRouter and (Settings.freeOnly ~= false)
        local filter = modelFilterText or ""

        local function collect(filterText)
            local out = {}
            for _, id in ipairs(order or {}) do
                local m = models[id]
                if m then
                    local isFree = (m.free ~= false)  -- static entries predate the flag
                    if not freeOnly or isFree then
                        local label = m.label or id
                        if filterText == "" or string.find(string.lower(label .. " " .. id), filterText, 1, true) then
                            local shown = label
                            if not isFree then
                                shown = string.format("%s  ·  $%.2f/$%.2f per M", label,
                                    tonumber(m.price_in) or 0, tonumber(m.price_out) or 0)
                            end
                            table.insert(out, { id = id, label = shown })
                        end
                    end
                end
            end
            return out
        end

        local visible = collect(filter)
        -- A filter that matches nothing (or a paid-only list while "free only" is
        -- ticked) must not blank the picker; fall back to the unfiltered list.
        if #visible == 0 and #(order or {}) > 0 then
            visible = collect("")
        end

        if #visible > 0 then
            modelDropdown:SetVisible(true)

            local labelFor, firstId, firstLabel = {}, nil, nil
            for _, v in ipairs(visible) do
                labelFor[v.id] = v.label
                firstId = firstId or v.id
                firstLabel = firstLabel or v.label
                modelDropdown:AddChoice(v.label, v.id, v.id == currentModelId)
            end

            -- Nothing selected, stale selection, or a paid model while "free only"
            -- is ticked -> fall back to the provider's defaultModel, then the first row.
            if not labelFor[currentModelId] then
                local preferred = p and p.defaultModel
                local target = (preferred and labelFor[preferred]) and preferred or firstId
                currentModelId = target
                modelDropdown:ChooseOption(labelFor[target] or firstLabel)
            end

            modelCustomEntry:SetVisible(p and p.allowCustomModel == true)
            if p and p.allowCustomModel then
                modelCustomEntry:SetText(Settings.model or "")
            end
            applyModelSettings(models[currentModelId])
        else
            local allowCustom = p and p.allowCustomModel == true
            modelDropdown:SetVisible(false)
            modelCustomEntry:SetVisible(allowCustom)
            modelCustomEntry:SetText(Settings.model or "")
            applyModelSettings(nil)
        end

        local showHost = p and p.requiresHostname == true
        hostnameLabel:SetVisible(showHost)
        hostnameEntry:SetVisible(showHost)

        -- The hardcoded list rotates; ask the server for today's catalog.
        if isOpenRouter and not LiveOpenRouterModels then
            requestOpenRouterModels()
        end

        refreshStatus()
    end

    function frame:ReloadProviderModels()
        if currentProviderId == "openrouter" then populateModels() end
    end

    function providerDropdown:OnSelect(_, _, id)
        currentProviderId = id
        Settings.provider = id
        currentModelId = nil
        refreshKeyEntry()
        populateModels()
        requestOpenRouterModels()
    end

    function modelDropdown:OnSelect(_, _, id)
        currentModelId = id
        Settings.model = id
        local _, models = getModelMap(currentProviderId)
        applyModelSettings(models[id])
        refreshStatus()
    end

    function reasoningDropdown:OnSelect(_, _, value)
        currentReasoning = value
    end

    -- ---- Spawn ----
    spawnBtn.DoClick = function()
        local key = AINPCS.Trim(keyEntry:GetValue() or "")
        Settings.apiKeys[currentProviderId] = key
        Settings.personality = personalityEntry:GetValue() or ""
        Settings.name = nameEntry:GetValue() or ""
        Settings.hostname = hostnameEntry:GetValue() or ""
        Settings.max_tokens = math.floor(maxTokSlider:GetValue())
        Settings.temperature = tempSlider:GetValue()
        Settings.reasoning = currentReasoning

        local _, voiceId = voiceDropdown:GetSelected()
        Settings.enableTTS = voiceId ~= nil and voiceId ~= "off"
        Settings.ttsVoice  = Settings.enableTTS and voiceId or "off"

        local modelId = currentModelId
        if modelCustomEntry:IsVisible() then
            local custom = AINPCS.Trim(modelCustomEntry:GetValue() or "")
            if custom ~= "" then modelId = custom end
        end
        Settings.model = modelId

        saveSettings(Settings)

        net.Start("AINPC_SpawnRequest")
        net.WriteTable({
            provider    = currentProviderId,
            apiKey      = key,
            hostname    = Settings.hostname,
            class       = Settings.npcClass,
            personality = Settings.personality,
            name        = Settings.name,
            model       = modelId,
            max_tokens  = Settings.max_tokens,
            temperature = Settings.temperature,
            reasoning   = currentReasoning,
            enableTTS   = Settings.enableTTS,
            voiceId     = Settings.ttsVoice,
        })
        net.SendToServer()

        frame:Close()
    end

    -- Initial state
    refreshKeyEntry()
    populateModels()

    -- Populate the voice picker with whatever the player's relay already knows.
    relayRequest("/voices?limit=40", function(voices)
        if registerRelayVoices(voices) > 0 then fillVoiceDropdown() end
    end)

    -- Preview the currently-selected NPC
    net.Start("AINPC_ModelPreview")
    net.WriteString(Settings.npcClass or "npc_citizen")
    net.SendToServer()

    -- Remember the model panel so we can update it when the server replies.
    AINPCS._ModelPreviewTarget = mp

    if Settings.firstRun then
        timer.Simple(0.1, ShowOnboarding)
    end
end

net.Receive("AINPC_ModelPreviewResponse", function()
    local modelPath = net.ReadString()
    local mp = AINPCS._ModelPreviewTarget
    if modelPath ~= "" and IsValid(mp) then
        mp:SetModel(modelPath)
    end
end)
