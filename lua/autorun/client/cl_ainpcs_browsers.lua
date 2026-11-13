--[[
    AI NPCs — shared browser modals

    Two self-contained pickers, used by both the classic Derma panel and the
    Mantle panel so neither has to grow its own copy:

      AINPCS.OpenBodyBrowser({ class, bodyModel, onPick })

        ONE list. NPC bodies and playermodels live in the same searchable,
        paged, icon grid with a live 3D preview — there is no second "browse
        bodies" menu any more.

      AINPCS.OpenVoiceBrowser({ voiceId, onPick })

        Search-first. The default view is what Fish Audio actually ranks first
        (most-used voices), not a hardcoded pin list. Duplicate uploads of the
        same character collapse into one row, every row can be previewed for
        free from Fish's pre-rendered samples, and results page in.

    Both write nothing to disk and send nothing to the server except through
    the caller's onPick callback.
]]

AINPCS = AINPCS or {}

local Voices = include("voices/voices.lua")

local C = AINPCS.Colors or {
    bg      = Color(20, 20, 24),
    card    = Color(34, 34, 40),
    cardAlt = Color(29, 29, 34),
    text    = Color(235, 235, 235),
    sub     = Color(160, 160, 170),
    accent  = Color(90, 165, 255),
    good    = Color(90, 200, 120),
    bad     = Color(235, 90, 90),
    warn    = Color(235, 190, 90),
}

surface.CreateFont("AINPC_Card", { font = "Roboto", size = 17, weight = 600 })
surface.CreateFont("AINPC_Meta", { font = "Roboto", size = 12, weight = 400 })
surface.CreateFont("AINPC_Search", { font = "Roboto", size = 17, weight = 400 })

-- =============================================================================
-- Small shared widgets
-- =============================================================================

local function paintButton(btn, palette)
    btn:SetText("")
    btn.Paint = function(s, w, h)
        local col = s:IsHovered() and palette.hover or palette.base
        if s:GetDisabled() then col = palette.disabled or Color(46, 46, 52) end
        draw.RoundedBox(6, 0, 0, w, h, col)
        draw.SimpleText(s._label or "", "AINPC_Small", w / 2, h / 2,
            s:GetDisabled() and Color(120, 120, 130) or C.text,
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
end

local PALETTE = {
    primary = { base = Color(52, 104, 190),  hover = Color(66, 124, 216) },
    ghost   = { base = Color(48, 48, 56),    hover = Color(64, 64, 74) },
    danger  = { base = Color(120, 46, 46),   hover = Color(150, 58, 58) },
    good    = { base = Color(46, 104, 62),   hover = Color(58, 130, 78) },
}

local function button(parent, label, kind, width, height)
    local b = vgui.Create("DButton", parent)
    b._label = label
    b:SetText("")
    paintButton(b, PALETTE[kind or "ghost"])
    if width then b:SetWide(width) end
    if height then b:SetTall(height) end
    b.SetLabel = function(self, t) self._label = t self:InvalidateLayout(true) end
    return b
end

local function closeExisting(key)
    if IsValid(AINPCS[key]) then AINPCS[key]:Remove() end
    AINPCS[key] = nil
end

local function modalFrame(key, title, w, h)
    closeExisting(key)

    local f = vgui.Create("DFrame")
    f:SetSize(math.min(w, ScrW() - 60), math.min(h, ScrH() - 60))
    f:Center()
    f:SetTitle("")
    f:MakePopup()
    f:SetDraggable(true)
    f:SetDeleteOnClose(true)

    -- Opaque, and drawn with surface.DrawRect rather than draw.RoundedBox:
    -- a rounded box with alpha 252 composites to nothing when the frame sits over
    -- a translucent parent (Mantle windows use background_alpha), which left the
    -- modal with only its child controls visible over the game world.
    f.Paint = function(s, sw, sh)
        surface.SetDrawColor(22, 22, 26)
        surface.DrawRect(0, 0, sw, sh)
        surface.SetDrawColor(34, 34, 42)
        surface.DrawRect(0, 0, sw, 30)
        draw.SimpleText(title, "AINPC_Header", 14, 15, C.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end
    f.OnRemove = function() AINPCS[key] = nil end

    AINPCS[key] = f
    return f
end

--- Rounded search box with placeholder + "always commits" behaviour.
local function searchEntry(parent, placeholder, height)
    local box = vgui.Create("DPanel", parent)
    box:SetTall(height or 38)
    box.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(30, 30, 36))
        if IsValid(s.entry) and s.entry:IsEditing() then
            surface.SetDrawColor(90, 165, 255, 180)
            surface.DrawOutlinedRect(0, 0, w, h, 1)
        end
    end

    local e = vgui.Create("DTextEntry", box)
    e:Dock(FILL)
    e:DockMargin(10, 0, 10, 0)
    e:SetFont("AINPC_Search")
    e:SetTextColor(C.text)
    e:SetDrawBackground(false)
    e:SetPlaceholderText(placeholder or "")
    e:SetUpdateOnType(true)
    box.entry = e
    return box
end

local function segmented(parent, options, onSelect, initial)
    local bar = vgui.Create("DPanel", parent)
    bar:SetTall(30)
    bar.Paint = nil

    local buttons = {}
    local active = initial or options[1].value

    local function refresh()
        for value, b in pairs(buttons) do
            b.active = (value == active)
            b:InvalidateLayout(true)
        end
    end

    for _, opt in ipairs(options) do
        local b = vgui.Create("DButton", bar)
        b:Dock(LEFT)
        b:DockMargin(0, 0, 6, 0)
        b:SetWide(opt.width or 130)
        b:SetText("")
        b.value = opt.value
        b.Paint = function(s, w, h)
            draw.RoundedBox(6, 0, 0, w, h,
                s.active and Color(44, 78, 130) or (s:IsHovered() and Color(56, 56, 66) or Color(40, 40, 48)))
            draw.SimpleText(opt.label, "AINPC_Small", w / 2, h / 2,
                s.active and C.text or C.sub, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        b.DoClick = function()
            active = opt.value
            refresh()
            onSelect(opt.value)
        end
        buttons[opt.value] = b
    end

    refresh()
    return bar, function() return active end
end

-- =============================================================================
-- Body catalogue
-- =============================================================================

local function humaniseModelName(path)
    local file = string.match(string.lower(path or ""), "([^/]+)%.mdl$") or path or "?"
    file = string.gsub(file, "_", " ")
    return (string.gsub(file, "^%l", string.upper))
end

--- Built fresh for each browser open. Caching it was a mistake: the first build
--- can happen before addon content is mounted, and every model that failed the
--- check at that moment disappeared from the list for the rest of the session.
function AINPCS.BuildBodyCatalogue()
    local out, seenModel = {}, {}

    local function add(entry)
        local model = string.lower(entry.model or "")
        if model == "" then return end
        if seenModel[model] then return end
        if not AINPCS.IsUsableBodyModel(model) then return end
        seenModel[model] = true
        entry.model = model
        entry.search = string.lower((entry.name or "") .. " " .. (entry.class or "") .. " " .. model)
        out[#out + 1] = entry
    end

    local reg = list.Get("NPC") or {}
    for id, data in pairs(reg) do
        if istable(data) and isstring(data.Model) and data.Model ~= "" then
            add({
                kind  = "npc",
                class = data.Class or id,
                model = data.Model,
                name  = data.Name or id,
                sub   = data.Class or id,
            })
        end
    end

    local okModels, models = pcall(player_manager.AllValidModels)
    if okModels and istable(models) then
        for niceName, path in pairs(models) do
            add({
                kind  = "player",
                class = "npc_citizen",
                model = path,
                name  = tostring(niceName),
                sub   = "playermodel",
            })
        end
    end

    -- Fall back to the spawnmenu's own model list when player_manager is sparse.
    if #out < 5 then
        for _, path in ipairs(list.Get("PlayerOptionsModel") or {}) do
            if isstring(path) then
                add({ kind = "player", class = "npc_citizen", model = path,
                      name = humaniseModelName(path), sub = "playermodel" })
            end
        end
    end

    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return a.kind == "npc" end
        return string.lower(a.name) < string.lower(b.name)
    end)

    return out
end

-- =============================================================================
-- Body browser — ONE list for NPC bodies and playermodels
-- =============================================================================

local BODY_PER_PAGE = 36

function AINPCS.OpenBodyBrowser(opts)
    opts = opts or {}
    local onPick = opts.onPick or function() end
    local currentClass = opts.class or "npc_citizen"
    local currentModel = string.lower(opts.bodyModel or "")

    local catalogue = AINPCS.BuildBodyCatalogue()

    -- Forward declarations. The filter control below renders on click, and a
    -- local declared after its closure would resolve to a global instead.
    local render, pick
    local filter = "npc"
    local page = 1
    local query = ""
    local selected = nil
    local modelToEntry = {}
    for _, e in ipairs(catalogue) do modelToEntry[e.model] = e end

    -- Pre-select whatever the character already uses, and open on the matching tab.
    if currentModel ~= "" and modelToEntry[currentModel] then
        selected = modelToEntry[currentModel]
        filter = (selected.kind == "player") and "player" or "npc"
    end

    local f = modalFrame("BodyBrowser", "Choose a body", 1000, 660)

    -- ---- header -----------------------------------------------------------
    local header = vgui.Create("DPanel", f)
    header:Dock(TOP)
    header:SetTall(46)
    header:DockMargin(12, 6, 12, 4)
    header.Paint = nil

    local filterBar = segmented(header, {
        { label = "NPC bodies",   value = "npc",    width = 118 },
        { label = "Playermodels", value = "player", width = 128 },
        { label = "Everything",   value = "all",    width = 104 },
    }, function(value)
        filter = value
        page = 1
        render()
    end, filter)
    filterBar:Dock(LEFT)
    filterBar:SetWide(380)
    filterBar:SetTall(30)

    local searchBox = searchEntry(header, "Search by name, class or model path…", 32)
    searchBox:Dock(FILL)
    searchBox:DockMargin(10, 0, 0, 0)

    -- ---- footer -----------------------------------------------------------
    local footer = vgui.Create("DPanel", f)
    footer:Dock(BOTTOM)
    footer:SetTall(46)
    footer:DockMargin(12, 4, 12, 10)
    footer.Paint = nil

    local prevBtn = button(footer, "< Prev", "ghost", 80, 32)
    prevBtn:Dock(LEFT)

    local pageLbl = vgui.Create("DLabel", footer)
    pageLbl:Dock(LEFT)
    pageLbl:DockMargin(12, 0, 12, 0)
    pageLbl:SetFont("AINPC_Small")
    pageLbl:SetTextColor(C.sub)
    pageLbl:SetText("")
    pageLbl:SetContentAlignment(4)

    local nextBtn = button(footer, "Next >", "ghost", 80, 32)
    nextBtn:Dock(LEFT)

    local useBtn = button(footer, "Use this body", "primary", 200, 34)
    useBtn:Dock(RIGHT)

    local pickedLabel = vgui.Create("DLabel", footer)
    pickedLabel:Dock(FILL)
    pickedLabel:DockMargin(14, 0, 14, 0)
    pickedLabel:SetFont("AINPC_Small")
    pickedLabel:SetTextColor(C.sub)
    pickedLabel:SetContentAlignment(6)

    -- ---- preview column (right) ------------------------------------------
    local previewCol = vgui.Create("DPanel", f)
    previewCol:Dock(RIGHT)
    previewCol:SetWide(260)
    previewCol:DockMargin(0, 0, 12, 0)
    previewCol.Paint = function(s, w, h) draw.RoundedBox(8, 0, 0, w, h, C.cardAlt) end

    local preview = vgui.Create("DModelPanel", previewCol)
    preview:Dock(FILL)
    preview:DockMargin(6, 6, 6, 6)
    preview:SetFOV(42)
    preview.LayoutEntity = function(self, ent)
        self:RunAnimation()
        ent:SetAngles(Angle(0, RealTime() * 45, 0))
    end

    -- ---- icon grid --------------------------------------------------------
    local scroll = vgui.Create("DScrollPanel", f)
    scroll:Dock(FILL)
    scroll:DockMargin(12, 0, 0, 0)

    -- ---- state ------------------------------------------------------------
    local function matches(entry)
        if filter ~= "all" and entry.kind ~= filter then return false end
        if query == "" then return true end
        return string.find(entry.search, query, 1, true) ~= nil
    end

    pick = function(entry)
        selected = entry
        if entry then
            preview:SetModel(entry.model)
            preview:SetFOV(42)
            pickedLabel:SetText(entry.name .. "   ·   " .. (entry.sub or entry.class))
            pickedLabel:SetTextColor(C.text)
        end
    end

    render = function()
        local list = {}
        for _, e in ipairs(catalogue) do
            if matches(e) then list[#list + 1] = e end
        end

        local pages = math.max(1, math.ceil(#list / BODY_PER_PAGE))
        if page > pages then page = pages end
        if page < 1 then page = 1 end

        scroll:Clear()

        local layout = vgui.Create("DIconLayout")
        scroll:AddItem(layout)
        layout:Dock(TOP)
        layout:SetSpaceX(6)
        layout:SetSpaceY(6)
        layout:DockPadding(0, 6, 0, 6)

        local from = (page - 1) * BODY_PER_PAGE + 1
        local to   = math.min(page * BODY_PER_PAGE, #list)

        local ICON = 92
        local CELL = ICON + 6

        for i = from, to do
            local entry = list[i]
            local holder = vgui.Create("DPanel")
            holder:SetSize(ICON, ICON + 20)
            holder.Paint = function(s, w, h)
                local isSel = (selected == entry)
                if isSel or s:IsHovered() then
                    draw.RoundedBox(8, 0, 0, w, h, isSel and Color(44, 78, 130) or Color(44, 44, 52))
                end
            end

            local icon = vgui.Create("SpawnIcon", holder)
            icon:SetPos(2, 2)
            icon:SetSize(ICON - 4, ICON - 4)
            icon:SetModel(entry.model)
            icon:SetTooltip(entry.name .. "\n" .. entry.model)
            icon.DoClick = function() pick(entry) end

            local lbl = vgui.Create("DLabel", holder)
            lbl:SetPos(2, ICON + 1)
            lbl:SetSize(ICON - 4, 16)
            lbl:SetFont("AINPC_Meta")
            lbl:SetTextColor(selected == entry and C.text or C.sub)
            lbl:SetText(entry.name)
            lbl:SetContentAlignment(5)
            lbl:SetMouseInputEnabled(false)

            layout:Add(holder)
        end

        -- Give the canvas an explicit height so the scroll bar exists even on the
        -- first frame, before DIconLayout has measured itself.
        local availW = (scroll:GetWide() or 0)
        if availW <= 0 then availW = 640 end
        local perRow = math.max(1, math.floor((availW + 6) / CELL))
        local rows   = math.ceil(math.max(1, to - from + 1) / perRow)
        layout:SetTall(rows * (ICON + 26) + 14)

        pageLbl:SetText(string.format("%d bodies   ·   page %d / %d", #list, page, pages))
        prevBtn:SetDisabled(page <= 1)
        nextBtn:SetDisabled(page >= pages)

        if #list == 0 then
            local empty = vgui.Create("DLabel")
            scroll:AddItem(empty)
            empty:SetFont("AINPC_Body")
            empty:SetTextColor(C.sub)
            empty:SetText("No bodies match that search.")
            empty:SetTall(40)
            empty:Dock(TOP)
        end
    end

    prevBtn.DoClick = function() page = page - 1 render() end
    nextBtn.DoClick = function() page = page + 1 render() end
    useBtn.DoClick = function()
        if not selected then
            AINPCS.PushToast("Pick a body first.", "info")
            return
        end
        onPick(selected.class, selected.model, selected)
        f:Close()
    end

    searchBox.entry.OnValueChange = function(_, value)
        query = string.lower(AINPCS.Trim(value or ""))
        page = 1
        render()
    end

    if selected then
        pick(selected)
    else
        local first = nil
        for _, e in ipairs(catalogue) do
            if e.class == currentClass then first = e break end
        end
        pick(first or catalogue[1])
    end

    render()
    return f
end

-- =============================================================================
-- Voice browser — search-first, deduped, previewable
-- =============================================================================

local LANGUAGES = {
    { label = "Any language", value = "" },
    { label = "English",      value = "en" },
    { label = "Japanese",     value = "ja" },
    { label = "Chinese",      value = "zh" },
    { label = "Spanish",      value = "es" },
    { label = "French",       value = "fr" },
    { label = "German",       value = "de" },
    { label = "Russian",      value = "ru" },
    { label = "Portuguese",   value = "pt" },
    { label = "Korean",       value = "ko" },
}

local SORTS = {
    { label = "Most used",  value = "task_count" },
    { label = "Best match", value = "score" },
}

-- Fish Audio's public listing is a 1000-model window (max_offset in the
-- response). With 50 per page that is 20 pages; asking beyond it returns
-- nothing useful, so the pager stops there instead of showing an empty page.
local PAGE_SIZE = 50
local MAX_PAGE  = 20

local function langText(langs)
    if not istable(langs) or #langs == 0 then return "" end
    local out = {}
    for i = 1, math.min(#langs, 3) do out[#out + 1] = langs[i] end
    return table.concat(out, ", ")
end

function AINPCS.OpenVoiceBrowser(opts)
    opts = opts or {}
    local onPick = opts.onPick or function() end
    local currentVoice = Voices.NormaliseId(opts.voiceId or "")

    local f = modalFrame("VoiceBrowser", "Choose a voice", 940, 700)

    -- Forward declaration: the filter widgets below need to trigger a fetch, and
    -- a local declared after their closures would resolve to a global instead.
    local request
    local page = 1
    local query = ""
    local language = ""
    local sortBy = "task_count"
    local showingBuiltin = false
    local requested = 0
    local selectedId = currentVoice
    local selectedLabel = nil

    -- ---- header -----------------------------------------------------------
    local header = vgui.Create("DPanel", f)
    header:Dock(TOP)
    header:SetTall(44)
    header:DockMargin(12, 6, 12, 2)
    header.Paint = nil

    local searchBox = searchEntry(header, "Search 100,000+ voices — try barney, rick, granny…", 36)
    searchBox:Dock(FILL)

    local searchBtn = button(header, "Search", "primary", 96, 36)
    searchBtn:Dock(RIGHT)
    searchBtn:DockMargin(8, 0, 0, 0)

    -- ---- filter row -------------------------------------------------------
    local filters = vgui.Create("DPanel", f)
    filters:Dock(TOP)
    filters:SetTall(32)
    filters:DockMargin(12, 4, 12, 2)
    filters.Paint = nil

    local sortBar, getSort = segmented(filters, SORTS, function()
        page = 1
        request()
    end, "task_count")
    sortBar:Dock(LEFT)
    sortBar:SetWide(250)

    local langCombo = vgui.Create("DComboBox", filters)
    langCombo:Dock(LEFT)
    langCombo:DockMargin(10, 1, 0, 0)
    langCombo:SetWide(160)
    langCombo:SetTall(26)
    for _, l in ipairs(LANGUAGES) do langCombo:AddChoice(l.label, l.value, l.value == "") end
    langCombo:SetValue("Any language")

    local builtinBtn = button(filters, "Free built-in voices", "ghost", 170, 26)
    builtinBtn:Dock(LEFT)
    builtinBtn:DockMargin(10, 1, 0, 0)

    local statusLbl = vgui.Create("DLabel", filters)
    statusLbl:Dock(FILL)
    statusLbl:DockMargin(14, 0, 0, 0)
    statusLbl:SetFont("AINPC_Small")
    statusLbl:SetTextColor(C.sub)
    statusLbl:SetContentAlignment(6)
    statusLbl:SetText("")

    -- ---- footer -----------------------------------------------------------
    local footer = vgui.Create("DPanel", f)
    footer:Dock(BOTTOM)
    footer:SetTall(46)
    footer:DockMargin(12, 4, 12, 10)
    footer.Paint = nil

    local prevBtn = button(footer, "< Prev", "ghost", 80, 32)
    prevBtn:Dock(LEFT)

    local pageLbl = vgui.Create("DLabel", footer)
    pageLbl:Dock(LEFT)
    pageLbl:DockMargin(12, 0, 12, 0)
    pageLbl:SetFont("AINPC_Small")
    pageLbl:SetTextColor(C.sub)
    pageLbl:SetContentAlignment(4)

    local nextBtn = button(footer, "Next >", "ghost", 80, 32)
    nextBtn:Dock(LEFT)

    local pickedLbl = vgui.Create("DLabel", footer)
    pickedLbl:Dock(FILL)
    pickedLbl:DockMargin(14, 0, 14, 0)
    pickedLbl:SetFont("AINPC_Small")
    pickedLbl:SetTextColor(C.sub)
    pickedLbl:SetContentAlignment(6)

    -- ---- result list ------------------------------------------------------
    local scroll = vgui.Create("DScrollPanel", f)
    scroll:Dock(FILL)
    scroll:DockMargin(12, 2, 12, 0)

    -- Rows live in a DListLayout inside the scroll canvas: docking straight into a
    -- DScrollPanel puts them on the panel instead of the canvas, so they would not
    -- scroll at all.
    local rowList
    local function resetList()
        scroll:Clear()
        rowList = vgui.Create("DListLayout")
        scroll:AddItem(rowList)
        rowList:Dock(TOP)
        rowList:DockPadding(0, 2, 0, 8)
        return rowList
    end

    -- ---- state (declared up top; see the forward declaration above) --------

    local updatePicked = function()
        if selectedLabel then
            pickedLbl:SetText("Selected: " .. selectedLabel)
            pickedLbl:SetTextColor(C.text)
        else
            pickedLbl:SetText("")
        end
    end

    local function addRow(layout, voice)
        local row = vgui.Create("DPanel")
        row:SetTall(58)
        layout:Add(row)
        row:DockMargin(0, 0, 4, 6)
        row.Paint = function(s, w, h)
            local sel = (selectedId == voice.id)
            draw.RoundedBox(7, 0, 0, w, h, sel and Color(40, 72, 122) or Color(32, 32, 38))
            if sel then
                draw.RoundedBox(7, 0, 0, 4, h, C.accent)
            elseif s:IsHovered() then
                surface.SetDrawColor(255, 255, 255, 10)
                surface.DrawRect(0, 0, w, h)
            end
        end

        local star = vgui.Create("DButton", row)
        star:Dock(LEFT)
        star:SetWide(24)
        star:SetText("")
        star.Paint = function(s, w, h)
            local pinned = AINPCS.IsVoicePinned(voice.modelId)
            draw.SimpleText(pinned and "★" or "☆", "AINPC_Body", w / 2, h / 2,
                pinned and C.warn or Color(110, 110, 124), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        star.DoClick = function()
            if voice.modelId then
                AINPCS.TogglePinVoice(voice.modelId, voice.label)
                star:InvalidateLayout(true)
                surface.PlaySound("ui/buttonclick.wav")
            end
        end

        -- Buttons first (docked right), then the text fills what is left.
        local useBtn = button(row, "Use", "primary", 66, 30)
        useBtn:Dock(RIGHT)
        useBtn:DockMargin(0, 14, 10, 14)
        useBtn.DoClick = function()
            selectedId = voice.id
            selectedLabel = voice.label
            updatePicked()
            onPick(voice.id, voice.label, voice)
            f:Close()
        end

        if voice.sample then
            local playBtn = button(row, "▶ Play", "good", 74, 30)
            playBtn:Dock(RIGHT)
            playBtn:DockMargin(0, 14, 6, 14)
            playBtn.DoClick = function()
                AINPCS.PlaySampleURL(voice.sample, 0.75)
            end
        elseif voice.id and Voices.FishModelId(voice.id) and AINPCS.Trim(AINPCS.Settings.fishKey or "") ~= "" then
            -- No pre-rendered sample: synthesize a short line (costs a little credit).
            local synthBtn = button(row, "▶ Test", "ghost", 74, 30)
            synthBtn:Dock(RIGHT)
            synthBtn:DockMargin(0, 14, 6, 14)
            synthBtn.DoClick = function()
                AINPCS.PreviewVoice(voice.id, voice.label and ("Hi, I'm " .. voice.label .. ".") or "Hello there.")
            end
        elseif voice.id and not Voices.FishModelId(voice.id) then
            local playBtn = button(row, "▶ Play", "ghost", 74, 30)
            playBtn:Dock(RIGHT)
            playBtn:DockMargin(0, 14, 6, 14)
            playBtn.DoClick = function()
                AINPCS.PreviewVoice(voice.id, "Hello. This is what I sound like.")
            end
        end

        local textCol = vgui.Create("DPanel", row)
        textCol:Dock(FILL)
        textCol:DockMargin(6, 6, 6, 6)
        textCol.Paint = nil

        local title = vgui.Create("DLabel", textCol)
        title:Dock(TOP)
        title:SetFont("AINPC_Card")
        title:SetTextColor(C.text)
        title:SetText(voice.label)
        title:SetTall(22)

        local meta = vgui.Create("DLabel", textCol)
        meta:Dock(TOP)
        meta:SetFont("AINPC_Meta")
        meta:SetTextColor(C.sub)
        meta:SetText(voice.meta or "")
        meta:SetTall(18)
        meta:SetText(voice.meta or "")

        return row
    end

    local function renderBuiltin()
        local lay = resetList()
        statusLbl:SetText("Free built-in voices — no account, no key, nothing to install.")

        local tab = {}
        for _, v in ipairs(Voices.list or {}) do
            if v.engine == "google" or v.engine == "sapi4" then
                if query == "" or string.find(string.lower(v.label), query, 1, true) then
                    tab[#tab + 1] = {
                        id      = v.id,
                        label   = v.label,
                        meta    = (v.engine == "google") and "Google TTS · free · keyless" or "Microsoft SAPI4 · free · keyless",
                    }
                end
            end
        end

        if #tab == 0 then
            local l = vgui.Create("DLabel")
            lay:Add(l)
            l:SetFont("AINPC_Body")
            l:SetTextColor(C.sub)
            l:SetText("No built-in voice matches that search.")
            l:SetTall(32)
            return
        end

        for _, voice in ipairs(tab) do addRow(lay, voice) end
        pageLbl:SetText(#tab .. " built-in voices")
        prevBtn:SetDisabled(true)
        nextBtn:SetDisabled(true)
    end

    request = function()
        local ticket = requested + 1
        requested = ticket

        statusLbl:SetText("Searching…")
        resetList()

        AINPCS.FishListVoices({
            query    = query,
            page     = page,
            sortBy   = sortBy,
            language = language,
            limit    = PAGE_SIZE,
        }, function(voices, err)
            if ticket ~= requested then return end   -- superseded
            if not IsValid(scroll) then return end

            if err or #voices == 0 then
                local lay = resetList()
                local l = vgui.Create("DLabel")
                lay:Add(l)
                l:SetFont("AINPC_Body")
                l:SetTextColor(err and C.bad or C.sub)
                l:SetWrap(true)
                l:SetText(err
                    and ("Fish Audio request failed: " .. tostring(err))
                    or (query ~= ""
                        and "No voices matched that search."
                        or "No voices came back. Try a search, or switch to the free built-in voices."))
                l:SetTall(44)
                statusLbl:SetText("")
                pageLbl:SetText("")
                prevBtn:SetDisabled(true)
                nextBtn:SetDisabled(true)
                return
            end

            local lay = resetList()

            -- The player's own shortlist goes first, so the pins they set in the
            -- browser are actually findable instead of competing with 100k voices.
            local pinnedModelIds = {}
            if query == "" and page == 1 then
                local anyPinned = false
                for _, p in ipairs(AINPCS.Settings.pinnedVoices or {}) do
                    if isstring(p.name) and isstring(p.label) and not pinnedModelIds[p.name] then
                        pinnedModelIds[p.name] = true
                        anyPinned = true
                        addRow(lay, {
                            id      = "fish:" .. p.name,
                            modelId = p.name,
                            label   = p.label,
                            meta    = "★ pinned — press Play to hear it, or search to compare",
                        })
                    end
                end

                if anyPinned then
                    local sep = vgui.Create("DLabel")
                    lay:Add(sep)
                    sep:SetTall(24)
                    sep:SetFont("AINPC_Meta")
                    sep:SetTextColor(C.sub)
                    sep:SetText("   Most used on Fish Audio")
                end
            end

            local shownCount = 0
            for _, v in ipairs(voices) do
                if not pinnedModelIds[v.id] then
                    shownCount = shownCount + 1
                    local bits = {}
                    if v.uses > 0 then bits[#bits + 1] = AINPCS.FormatCount(v.uses) .. " uses" end
                    if v.likes > 0 then bits[#bits + 1] = AINPCS.FormatCount(v.likes) .. " likes" end
                    local lt = langText(v.langs)
                    if lt ~= "" then bits[#bits + 1] = lt end
                    if v.sample then bits[#bits + 1] = "free sample" end

                    addRow(lay, {
                        id      = "fish:" .. v.id,
                        modelId = v.id,
                        label   = v.label,
                        sample  = v.sample,
                        meta    = table.concat(bits, "  ·  "),
                    })
                end
            end

            statusLbl:SetText(string.format("%d voices%s", shownCount,
                query ~= "" and (" matching \"" .. query .. "\"") or " — most used first"))
            pageLbl:SetText("page " .. page)
            prevBtn:SetDisabled(page <= 1)
            nextBtn:SetDisabled(page >= MAX_PAGE or #voices < 40)
        end)
    end

    -- ---- wiring -----------------------------------------------------------
    local function doSearch()
        query = string.lower(AINPCS.Trim(searchBox.entry:GetValue() or ""))
        page = 1
        showingBuiltin = false
        request()
    end

    searchBtn.DoClick = doSearch
    searchBox.entry.OnEnter = doSearch

    prevBtn.DoClick = function()
        if page > 1 then page = page - 1 request() end
    end
    nextBtn.DoClick = function()
        page = page + 1
        request()
    end

    langCombo.OnSelect = function(_, _, _, value)
        language = value or ""
        page = 1
        showingBuiltin = false
        request()
    end

    builtinBtn.DoClick = function()
        showingBuiltin = not showingBuiltin
        builtinBtn:SetLabel(showingBuiltin and "Back to Fish Audio" or "Free built-in voices")
        if showingBuiltin then renderBuiltin() else request() end
    end

    -- ---- boot -------------------------------------------------------------
    if currentVoice ~= "" then
        local v = Voices.Get(currentVoice)
        selectedLabel = (v and v.label) or currentVoice
        updatePicked()
    end

    if AINPCS.Trim(AINPCS.Settings.fishKey or "") == "" then
        statusLbl:SetText("No Fish Audio key yet — samples play free, but add a key in Settings to use a voice.")
        statusLbl:SetTextColor(C.warn)
    end

    request()
    return f
end
