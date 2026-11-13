--[[
    AI NPCs — Mantle interface

    Mantle is a separate Workshop addon (3126986993); cl_1_ainpcs_ui.lua gates it.
    This file is only ever reached through AINPCS.OpenMantle().

    Progress:
      Phase 0  shell (frame, tabs, header status pill)            done
      Phase 1  settings page                                      done
      Phase 2  library page                                       done
      Phase 3  create wizard                                      done
      Phase 4  chat window (cl_ainpcs_interact.lua)               pending
      Phase 5  HUD + toasts on RNDX                               pending

    Mantle element quirks this file has to respect (all confirmed in the installed
    build's source, not just the docs):
      * MantleComboBox calls OnSelect as a plain function: (index, text, data).
        It is NOT a colon method, unlike Derma's DComboBox (_, i, text, data).
      * MantleComboBox:SelectChoice() FIRES OnSelect. Use SetValue(text) to
        pre-select without side effects.
      * MantleComboBox has no Clear(), so a rebuild is remove + recreate.
      * MantleCheckBox:SetValue() fires OnChange, so wire OnChange after the
        initial SetValue.
      * MantlePanel/MantleEntry/MantleComboBox/MantleBtn all default to an 8px
        all-round DockMargin. Inside a fixed-height row that eats the control, so
        rows clear the margins explicitly.
      * A panel docked LEFT/RIGHT takes its height from the parent, not SetTall.
]]

AINPCS = AINPCS or {}

local UI        = AINPCS.UI or {}
local providers = AINPCS.Providers or { list = function() return {} end, get = function() end }
local Voices    = AINPCS.Voices or { list = {}, Get = function() end }

local FRAME_W, FRAME_H = 1040, 700

-- Controls are capped to this so the eye never tracks the full window width.
-- Same number the classic panel uses, scaled for the client instead of raw.
local CONTENT_W = 620

local PAGE_ORDER  = { "library", "create", "settings" }
local PAGE_TITLES = { library = "Library", create = "Create", settings = "Settings" }
local PAGE_ICONS  = {
    library  = "icon16/table.png",
    create   = "icon16/add.png",
    settings = "icon16/wrench.png",
}

-- =============================================================================
-- Shared components
-- =============================================================================

--- MantleText with the defaults we always want.
--- MantleText ships an 8px all-round DockMargin too (like MantlePanel, Entry,
--- ComboBox and Btn). Left in place inside a fixed-height row it silently eats
--- the sibling below it: that is what hid the status pill's second line.
local function label(parent, text, font, color, height)
    local l = vgui.Create("MantleText", parent)
    l:DockMargin(0, 0, 0, 0)
    l:SetPadding(0)
    l:SetFont(font or "Fated.16")
    if color then l:SetColor(color) end
    if height then l:SetTall(height) end
    l:SetText(text or "")
    return l
end

local function makeDot(parent)
    local dot = vgui.Create("EditablePanel", parent)
    dot:Dock(LEFT)
    dot:SetWide(12)
    dot._color = UI.sem.warn

    dot.Paint = function(s, w, h)
        local c = s._color or UI.sem.warn
        if RNDX then
            RNDX.Circle(w * 0.5, h * 0.5, 4):Color(c):Draw()
        else
            draw.RoundedBox(4, w * 0.5 - 4, h * 0.5 - 4, 8, 8, c)
        end
    end

    return dot
end

--- Voice-service status: coloured dot + headline + detail line.
--- Three states: not running / running without a key / ready.
function UI.StatusPill(parent, width)
    local box = vgui.Create("MantlePanel", parent)
    box:SetColorAlpha(2)
    box:SetRadius(10)
    box:SetWide(width or UI.w(400))
    box:SetTall(56)
    box:DockMargin(0, 0, 0, 0)
    box:DockPadding(12, 6, 12, 6)

    local dot = makeDot(box)

    local title = label(box, "voice service: checking...", "Fated.16", nil, 22)
    title:Dock(TOP)

    local sub = label(box, "", "Fated.14", UI.col("gray"), 20)
    sub:Dock(TOP)

    box.dot   = dot
    box.title = title
    box.sub   = sub

    --- info = the /health payload or nil; code = HTTP status, or a string when
    --- the request never completed. Distinguishing the two matters: a 400 is
    --- Windows' HTTP.sys rejecting the Host header (relay bound to "localhost",
    --- asked for 127.0.0.1), which used to be reported as "not running" and sent
    --- people restarting a service that was already up.
    function box:SetState(info, code)
        if not IsValid(self) then return end
        self.title:SetColor(UI.col("text"))

        if not info then
            self.dot._color = UI.sem.bad
            if type(code) == "number" then
                self.title:SetText("voice service: unreachable (HTTP " .. code .. ")")
                self.sub:SetText(code == 400
                    and "wrong host — use http://localhost:7171, not 127.0.0.1"
                    or "the relay answered, but not with /health JSON")
            else
                self.title:SetText("voice service: NOT running")
                self.sub:SetText("tried " .. tostring(AINPCS._relayTried or AINPCS.RelayBase()))
            end
        elseif info.local_blocked then
            -- Expected on a default install: Garry's Mod refuses client HTTP to
            -- loopback. Everything still works — the voice list and the key travel
            -- as files, and audio goes through sound.PlayURL (BASS, not the Lua HTTP
            -- shim), so this is a healthy state, not a warning.
            self.dot._color = UI.sem.ok
            self.title:SetText("voice service: ready (file mode)")
            self.sub:SetText("Garry's Mod blocks HTTP to loopback; voices and the key use files")
        elseif info.file_only then
            -- The relay's heartbeat file says it is up, but the game's own HTTP
            -- client could not reach it. That is a firewall/sandbox problem, not a
            -- "start the relay" problem, and the message says so.
            self.dot._color = UI.sem.warn
            self.title:SetText("voice service: up, but unreachable from the game")
            self.sub:SetText(string.format(
                "status file is %ss old; HTTP said %s — voice search and playback will fail",
                tostring(info.age), tostring(info.code)))
        elseif info.unparsed then
            -- 200 with a body we cannot parse: reachable, not broken.
            self.dot._color = UI.sem.warn
            self.title:SetText("voice service: running, unreadable status")
            self.sub:SetText("see ainpc_voice_diag in the console")
        elseif info.key_set then
            self.dot._color = UI.sem.ok
            self.title:SetText("voice service: ready")
            self.sub:SetText(string.format("credit %s   %s",
                type(info.credits) == "number" and string.format("%.2f", info.credits) or "?",
                AINPCS.RelayBase()))
        else
            self.dot._color = UI.sem.warn
            self.title:SetText("voice service: running, no key")
            self.sub:SetText("paste your Fish Audio key below")
        end
    end

    function box:Refresh()
        AINPCS.RelayHealth(function(info, code) self:SetState(info, code) end)
    end

    return box
end

local function pageHeading(page, title, sub)
    local head = label(page, title, "Fated.22b", nil, 28)
    head:Dock(TOP)

    if sub then
        local subLbl = label(page, sub, "Fated.14", UI.col("gray"), 22)
        subLbl:Dock(TOP)
    end
end

-- =============================================================================
-- Labels
-- =============================================================================

local function voiceLabel(id)
    if not id or id == "" then return "no voice" end
    local v = Voices.Get and Voices.Get(id)
    return v and v.label or id
end

local function classLabel(id)
    local reg  = list.Get("NPC") or {}
    local data = reg[id]
    return (data and data.Name) or id or "?"
end

local function repliesLabel(reasoning)
    if reasoning == "none" or not reasoning then return "instant" end
    return "thinking: " .. tostring(reasoning)
end

-- =============================================================================
-- Draft
--
-- The wizard (Phase 3) edits this table. Library Edit / New both go through the
-- functions below so there is exactly one place that decides what "editing"
-- means — the classic panel keeps its own local draft, which is why it cannot be
-- shared here.
-- =============================================================================

local function newDraft()
    return {
        id = nil, name = "", description = "", voiceId = "",
        class = "npc_citizen", reasoning = "none", speak = true,
    }
end

AINPCS.MantleDraft = AINPCS.MantleDraft or newDraft()

function AINPCS.NewCharacter()
    AINPCS.MantleDraft = newDraft()
    if AINPCS.ShowPage then AINPCS.ShowPage("create") end
    -- The wizard keeps its own step cursor; tell it to start over on the new draft.
    if isfunction(AINPCS.RebuildWizard) then AINPCS.RebuildWizard(1) end
end

function AINPCS.EditEntry(entry)
    AINPCS.MantleDraft = table.Copy(entry)
    if AINPCS.ShowPage then AINPCS.ShowPage("create") end
    if isfunction(AINPCS.RebuildWizard) then AINPCS.RebuildWizard(1) end
end

-- =============================================================================
-- Library page  (Phase 2)
-- =============================================================================

local function buildLibraryPage(page)
    pageHeading(page, "Library", "Saved characters, one click to spawn.")

    -- Footer before the table: a FILL sibling created first would eat the space.
    local footer = vgui.Create("EditablePanel", page)
    footer:Dock(BOTTOM)
    footer:SetTall(38)
    footer:DockMargin(0, 10, 0, 0)

    local newBtn = vgui.Create("MantleBtn", footer)
    newBtn:SetTxt("+  New character")
    newBtn:SetWide(UI.w(200))
    newBtn:DockMargin(0, 2, 0, 2)
    newBtn:Dock(LEFT)

    local hint = label(footer, "", "Fated.14", UI.col("gray"))
    hint:Dock(FILL)
    hint:DockMargin(12, 0, 0, 0)
    hint:SetVAlign("center")

    local tbl = vgui.Create("MantleTable", page)
    tbl:Dock(FILL)
    -- The built-in context menu offers "delete row", which would drop the row
    -- from the table without touching the saved JSON. We supply our own menu.
    tbl:SetContextMenuEnabled(false)

    tbl:AddColumn("Name",    UI.w(230), "left", true)
    tbl:AddColumn("Voice",   UI.w(210), "left", true)
    tbl:AddColumn("Body",    UI.w(180), "left", true)
    tbl:AddColumn("Replies", UI.w(130), "left", true)

    -- Empty state. MantleTable has no placeholder slot, so this label floats over
    -- it and follows the table's geometry each frame (the table is docked FILL,
    -- so its position is not known until layout runs).
    local empty = label(page, "Nothing saved yet — press “+ New character” to build one.",
        "Fated.16", UI.col("gray"))
    empty:SetAlign(TEXT_ALIGN_CENTER)
    empty:SetMouseInputEnabled(false)
    empty:SetVisible(false)
    empty.Think = function(s)
        if not IsValid(tbl) then return end
        s:SetPos(tbl:GetX(), tbl:GetY() + 48)
        s:SetSize(tbl:GetWide(), 30)
    end

    local function spawnEntry(entry)
        if not entry then return end
        UI.click()
        AINPCS.Spawn(entry)
    end

    local function deleteEntry(entry)
        if not entry then return end
        AINPCS.RemoveLibraryEntry(entry.id)
        AINPCS.RebuildLibrary()
        AINPCS.PushToast((entry.name or "Character") .. " deleted.", "info")
    end

    newBtn.DoClick = function()
        UI.click()
        AINPCS.NewCharacter()
    end

    -- OnAction/OnRightClick are plain functions: (rowData, rowIndex).
    tbl:SetAction(function(row) spawnEntry(row.entry) end)

    tbl:SetRightClickAction(function(row)
        local entry = row.entry
        if not entry then return end

        local menu = Mantle.ui.derma_menu()
        menu:AddOption("Spawn", function() spawnEntry(entry) end, "icon16/user_add.png")
        menu:AddOption("Edit", function()
            UI.click()
            AINPCS.EditEntry(entry)
        end, "icon16/pencil.png")
        menu:AddSpacer()
        menu:AddOption("Delete", function() deleteEntry(entry) end, "icon16/bin_closed.png")
    end)

    function AINPCS.RebuildLibrary()
        if not IsValid(tbl) then return end

        tbl:Clear()

        local count = #AINPCS.Library
        for _, entry in ipairs(AINPCS.Library) do
            local index = tbl:AddItem(
                entry.name or "?",
                voiceLabel(entry.voiceId),
                classLabel(entry.class),
                repliesLabel(entry.reasoning)
            )

            -- Rows are plain arrays keyed by table identity, so the entry rides
            -- along on the row instead of a side index that could go stale after
            -- a sort.
            local row = tbl:GetRow(index)
            if row then row.entry = entry end
        end

        empty:SetVisible(count == 0)
        hint:SetText(count == 0
            and "Saved characters can be spawned again any time."
            or string.format("%d saved. Click to spawn, right-click for Edit / Delete.", count))
    end

    AINPCS.RebuildLibrary()
end

-- =============================================================================
-- Create page  (Phase 3)
-- =============================================================================

--- Single-line text box.
---
--- Deliberately NOT MantleEntry. That widget paints the value itself:
---   * one unclipped draw.SimpleText, slid left by an animated offset, so past one
---     control-width of text the string renders outside the rounded box and over
---     whatever sits beside it;
---   * the caret is placed at GetTextSize(value) -- the end of the whole string --
---     instead of at the caret index, so editing mid-string snaps the view to the
---     end.
--- GMod's own DTextEntry already does scrolling, clipping, caret, selection,
--- Ctrl+A/C/V and update-on-type correctly, so the engine control stays and we
--- only own the chrome (rounded box + focus ring).
local function textEntry(parent, width, placeHolder, height)
    local box = vgui.Create("MantlePanel", parent)
    box:SetCustomColor(UI.col("focus_panel"))
    box:SetRadius(12)
    box:DockMargin(0, 2, 0, 2)
    box:SetTall(height or 34)
    if width then box:SetWide(width) end

    local te = vgui.Create("DTextEntry", box)
    te:Dock(FILL)
    te:DockMargin(8, 0, 8, 0)
    te:SetFont("Fated.18")
    te:SetTextColor(UI.col("text"))
    te:SetHighlightColor(UI.col("theme"))
    te:SetCursorColor(UI.col("text"))
    te:SetDrawBackground(false)
    te:SetPlaceholderText(placeHolder or "")
    -- Without this, OnValueChange only fires on Enter or focus loss. A Mantle
    -- button does not always take keyboard focus, so the last thing typed was
    -- silently dropped and the field rebuilt empty on the next step change.
    te:SetUpdateOnType(true)

    box.textEntry = te
    box._focus = 0

    box.PaintOver = function(s, w, h)
        local editing = IsValid(te) and te:IsEditing()
        s._focus = Mantle.func.approachExp(s._focus, editing and 1 or 0, 12, FrameTime())
        if s._focus < 0.02 then return end

        local c = UI.col("theme")
        RNDX.Rect(0, 0, w, h):Rad(12)
            :Color(Color(c.r, c.g, c.b, math.floor(190 * s._focus)))
            :Outline(1)
        :Draw()
    end

    function box:SetValue(value) if IsValid(te) then te:SetText(tostring(value or "")) end end
    function box:GetValue() return IsValid(te) and te:GetText() or "" end
    function box:SetPlaceholder(text) if IsValid(te) then te:SetPlaceholderText(text or "") end end

    -- Preserve DTextEntry's own lose-focus hook, then report the value.
    local baseLoseFocus = te.OnLoseFocus
    te.OnLoseFocus = function(entry)
        if baseLoseFocus then baseLoseFocus(entry) end
        if box.action then box.action(entry:GetValue()) end
    end

    return box
end

--- Multiline text box. Mantle has no multiline entry (MantleEntry wraps a
--- single-line DTextEntry at a fixed 32px), and the character description is the
--- one field that genuinely needs paragraphs. Built on MantlePanel so it inherits
--- the card look; the inner DTextEntry is a raw engine control on purpose.
local function multilineEntry(parent, titleText, placeHolder, height)
    local box = vgui.Create("MantlePanel", parent)
    box:SetColorAlpha(1)
    box:SetRadius(12)
    box:DockMargin(0, 0, 0, 0)
    box:SetTall(height or 120)
    box:DockPadding(8, 6, 8, 6)

    local title = label(box, titleText or "", "Fated.14", UI.col("gray"), 20)
    title:Dock(TOP)

    local te = vgui.Create("DTextEntry", box)
    te:Dock(FILL)
    te:SetMultiline(true)
    te:SetFont("Fated.16")
    te:SetTextColor(UI.col("text"))
    te:SetHighlightColor(UI.col("theme"))
    te:SetCursorColor(UI.col("text"))
    te:SetDrawBackground(false)
    te:SetPlaceholderText(placeHolder or "")
    te:SetUpdateOnType(true)   -- same reason as textEntry: no lost last keystroke

    box.textEntry = te
    box._focus = 0

    box.PaintOver = function(s, w, h)
        local editing = IsValid(te) and te:IsEditing()
        s._focus = Mantle.func.approachExp(s._focus, editing and 1 or 0, 12, FrameTime())
        if s._focus < 0.02 then return end

        local c = UI.col("theme")
        RNDX.Rect(0, 0, w, h):Rad(12)
            :Color(Color(c.r, c.g, c.b, math.floor(190 * s._focus)))
            :Outline(1)
        :Draw()
    end

    return box
end

local STEP_NAMES = { "Identity", "Voice", "Body", "Behaviour", "Review" }

local function buildCreatePage(page)
    pageHeading(page, "Create", "Guided maker. Everything here is saved to the library.")

    local step       = 1
    local maxVisited = 1
    local rebuildStep   -- forward declaration: the step bar clicks call it

    -- ---- nav footer (created before the FILL host) -------------------------
    local nav = vgui.Create("EditablePanel", page)
    nav:Dock(BOTTOM)
    nav:SetTall(40)
    nav:DockMargin(0, 10, 0, 0)

    local backBtn = vgui.Create("MantleBtn", nav)
    backBtn:SetTxt("Back")
    backBtn:SetWide(110)
    backBtn:DockMargin(0, 2, 0, 2)
    backBtn:Dock(LEFT)

    local nextBtn = vgui.Create("MantleBtn", nav)
    nextBtn:SetTxt("Next")
    nextBtn:SetWide(UI.w(200))
    nextBtn:DockMargin(0, 2, 0, 2)
    nextBtn:Dock(RIGHT)

    -- ---- step indicator ----------------------------------------------------
    local stepBar = vgui.Create("EditablePanel", page)
    stepBar:Dock(TOP)
    stepBar:SetTall(26)
    stepBar:DockMargin(0, 8, 0, 10)

    stepBar.Paint = function(s, w, h)
        local n   = #STEP_NAMES
        local gap = 8
        local pw  = (w - gap * (n - 1)) / n

        for i = 1, n do
            local x      = (i - 1) * (pw + gap)
            local active = (i == step)
            local done   = (i < step)
            local col    = active and UI.col("theme") or (done and UI.panel(3) or UI.panel(1))

            RNDX.Rect(x, 0, pw, h):Rad(h * 0.5):Color(col):Draw()
            draw.SimpleText(i .. ".  " .. STEP_NAMES[i], "Fated.14",
                x + pw * 0.5, h * 0.5,
                active and color_white or UI.col("text"),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    end

    stepBar.OnMousePressed = function(s, key)
        if key ~= MOUSE_LEFT then return end

        local n   = #STEP_NAMES
        local gap = 8
        local pw  = (s:GetWide() - gap * (n - 1)) / n
        local x   = s:CursorPos()

        for i = 1, math.min(n, maxVisited) do
            local left = (i - 1) * (pw + gap)
            if x >= left and x <= left + pw then
                step = i
                if rebuildStep then rebuildStep() end
                return
            end
        end
    end

    local host = vgui.Create("EditablePanel", page)
    host:Dock(FILL)

    -- =========================================================================
    -- Body catalogue (built once; the NPC registry does not change mid-session)
    -- =========================================================================

    local classById    = {}
    local classIds     = {}
    local catalogue    = {}      -- model_selector entries
    local modelToClass = {}
    local DEFAULT_MODEL = "models/humans/group01/male_07.mdl"

    do
        local reg = list.Get("NPC") or {}
        for id in pairs(reg) do classById[id] = reg[id]; classIds[#classIds + 1] = id end
        table.sort(classIds)

        for _, id in ipairs(classIds) do
            local data = classById[id]
            if data and data.Model then
                catalogue[#catalogue + 1] = {
                    model = data.Model,
                    name = data.Name or id,
                    description = id,
                }
                -- Two classes can share a model; first id wins, the long-tail
                -- table below is the escape hatch for the rest.
                modelToClass[data.Model] = modelToClass[data.Model] or id
            end
        end
    end

    local function classModel(id)
        local data = classById[id]
        return (data and data.Model) or DEFAULT_MODEL
    end

    -- =========================================================================
    -- Step builders
    -- =========================================================================

    local function buildIdentity(draft)
        local nameLabel = label(host, "Name", "Fated.14", UI.col("gray"), 20)
        nameLabel:Dock(TOP)

        local row = vgui.Create("EditablePanel", host)
        row:Dock(TOP)
        row:SetTall(40)

        local name = textEntry(row, UI.w(CONTENT_W), "e.g. Rick Sanchez")
        name:Dock(LEFT)
        name:SetValue(draft.name or "")
        name.textEntry.OnValueChange = function(_, value) draft.name = value end

        local desc = multilineEntry(host, "Description (optional)",
            "Leave blank for a character from a game or film. Add notes for an original one.",
            130)
        desc:Dock(TOP)
        desc.textEntry:SetText(draft.description or "")
        desc.textEntry.OnValueChange = function(_, value) draft.description = value end
    end

    local function buildVoice(draft)
        local searchRow = vgui.Create("EditablePanel", host)
        searchRow:Dock(TOP)
        searchRow:SetTall(40)

        local search = textEntry(searchRow, UI.w(CONTENT_W) - 116, "rick sanchez")
        search:Dock(LEFT)

        local searchBtn = vgui.Create("MantleBtn", searchRow)
        searchBtn:SetTxt("Search")
        searchBtn:SetPos(UI.w(CONTENT_W) - 108, 2)
        searchBtn:SetSize(108, 34)

        local status = label(host, "", "Fated.14", UI.col("gray"), 22)
        status:Dock(TOP)

        local previewRow = vgui.Create("EditablePanel", host)
        previewRow:Dock(BOTTOM)
        previewRow:SetTall(40)

        local previewBtn = vgui.Create("MantleBtn", previewRow)
        previewBtn:SetTxt("Preview selected voice")
        previewBtn:SetWide(UI.w(230))
        previewBtn:DockMargin(0, 2, 0, 2)
        previewBtn:Dock(LEFT)

        local tbl = vgui.Create("MantleTable", host)
        tbl:Dock(FILL)
        tbl:DockMargin(0, 6, 0, 6)
        tbl:SetContextMenuEnabled(false)
        tbl:AddColumn("Voice", UI.w(CONTENT_W), "left", true)

        local function fill(voices)
            tbl:Clear()
            for _, v in ipairs(voices or {}) do
                local index = tbl:AddItem(v.label or v.name or "?")
                local row = tbl:GetRow(index)
                if row then row.voiceId = "relay:" .. tostring(v.name) end
            end

            local count = #(voices or {})
            status:SetText(count == 0
                and "no matches — is the voice service running?"
                or (count .. " matches, click one"))
        end

        tbl:SetAction(function(row)
            if not row.voiceId then return end
            draft.voiceId = row.voiceId
            status:SetText("selected: " .. voiceLabel(draft.voiceId))
        end)

        local function doSearch()
            status:SetText("searching...")
            AINPCS.RelayVoices(AINPCS.Trim(search:GetValue() or ""), fill)
        end

        searchBtn.DoClick = function() UI.click() doSearch() end
        search.textEntry.OnEnter = doSearch
        previewBtn.DoClick = function()
            if not draft.voiceId or draft.voiceId == "" then return end
            UI.click()
            local who = AINPCS.Trim(draft.name or "") ~= "" and draft.name or "an NPC"
            AINPCS.PreviewVoice(draft.voiceId, "Hello, I am " .. who .. ".")
        end

        doSearch()
    end

    local function buildBody(draft)
        local row = vgui.Create("EditablePanel", host)
        row:Dock(FILL)

        local previewBox = vgui.Create("MantlePanel", row)
        previewBox:SetColorAlpha(2)
        previewBox:SetRadius(12)
        previewBox:Dock(LEFT)
        previewBox:SetWide(UI.w(240))
        previewBox:DockMargin(0, 0, 10, 0)

        local preview = vgui.Create("DModelPanel", previewBox)
        preview:Dock(FILL)
        preview:SetModel(classModel(draft.class))
        preview:SetFOV(46)
        preview.LayoutEntity = function(self, ent)
            self:RunAnimation()
            ent:SetAngles(Angle(0, RealTime() * 60, 0))
        end

        local right = vgui.Create("EditablePanel", row)
        right:Dock(FILL)

        local btnRow = vgui.Create("EditablePanel", right)
        btnRow:Dock(TOP)
        btnRow:SetTall(40)

        local browse = vgui.Create("MantleBtn", btnRow)
        browse:SetTxt("Browse bodies")
        browse:SetWide(UI.w(200))
        browse:DockMargin(0, 2, 0, 2)
        browse:Dock(LEFT)

        local bodyStatus = label(right, "current: " .. classLabel(draft.class),
            "Fated.14", UI.col("gray"), 22)
        bodyStatus:Dock(TOP)

        local tbl = vgui.Create("MantleTable", right)
        tbl:Dock(FILL)
        tbl:DockMargin(0, 6, 0, 0)
        tbl:SetContextMenuEnabled(false)
        tbl:AddColumn("Body", UI.w(320), "left", true)
        tbl:AddColumn("Class", UI.w(200), "left", true)

        local function setClass(id)
            draft.class = id
            preview:SetModel(classModel(id))
            bodyStatus:SetText("current: " .. classLabel(id))
        end

        for _, id in ipairs(classIds) do
            local index = tbl:AddItem(classLabel(id), id)
            local rowData = tbl:GetRow(index)
            if rowData then rowData.classId = id end
        end

        tbl:SetAction(function(rowData)
            if rowData.classId then setClass(rowData.classId) end
        end)

        -- The modal selector is the pretty path: interactive preview, drag to
        -- rotate, wheel to dolly. It returns only a model, so classes sharing a
        -- model resolve through modelToClass and the table above covers the rest.
        browse.DoClick = function()
            UI.click()
            Mantle.ui.model_selector(catalogue, function(model)
                local id = modelToClass[model]
                if id then setClass(id) end
            end)
        end
    end

    local function buildBehaviour(draft)
        local speedRow = vgui.Create("EditablePanel", host)
        speedRow:Dock(TOP)
        speedRow:SetTall(38)

        local speed = vgui.Create("MantleComboBox", speedRow)
        speed:Dock(LEFT)
        speed:SetWide(UI.w(CONTENT_W))
        speed:DockMargin(0, 2, 0, 2)
        speed:SetPlaceholder("reply speed")

        local choices = {
            { "Instant (no reasoning)", "none" },
            { "A little thinking",       "low" },
            { "Balanced",                "medium" },
        }
        local labelFor = {}
        for _, pair in ipairs(choices) do
            labelFor[pair[2]] = pair[1]
            speed:AddChoice(pair[1], pair[2])
        end
        if labelFor[draft.reasoning] then speed:SetValue(labelFor[draft.reasoning]) end

        speed.OnSelect = function(index, text, value) draft.reasoning = value end

        local speedNote = label(host,
            "Instant skips reasoning entirely: the NPC starts talking immediately.",
            "Fated.14", UI.col("gray"), 22)
        speedNote:Dock(TOP)

        local speakRow = vgui.Create("EditablePanel", host)
        speakRow:Dock(TOP)
        speakRow:SetTall(34)
        speakRow:DockMargin(0, 12, 0, 0)

        local speak = vgui.Create("MantleCheckBox", speakRow)
        speak:Dock(LEFT)
        speak:SetWide(UI.w(CONTENT_W))
        speak:DockMargin(0, 2, 0, 2)
        speak:SetTxt("Speak out loud")
        speak:SetValue(draft.speak ~= false)
        speak.OnChange = function(_, value) draft.speak = value end
    end

    local function saveAndMaybeSpawn(spawnNow)
        local draft = AINPCS.MantleDraft
        if AINPCS.IsBlank(draft.name or "") then draft.name = "NPC" end
        if draft.voiceId == "" then draft.voiceId = AINPCS.Settings.fallbackVoice end

        local saved = AINPCS.UpsertLibraryEntry(table.Copy(draft))
        draft.id = saved.id

        AINPCS.RebuildLibrary()

        if spawnNow then
            AINPCS.Spawn(draft)
        else
            AINPCS.PushToast((draft.name or "Character") .. " saved.", "success")
            if AINPCS.ShowPage then AINPCS.ShowPage("library") end
        end
    end

    local function buildReview(draft)
        local summary = {
            { "Name",        (not AINPCS.IsBlank(draft.name or "")) and draft.name or "(none)" },
            { "Voice",       voiceLabel(draft.voiceId) },
            { "Body",        classLabel(draft.class) },
            { "Replies",     repliesLabel(draft.reasoning) },
            { "Speaks",      draft.speak and "yes" or "no" },
            { "Description", (not AINPCS.IsBlank(draft.description or "")) and draft.description or "from the name" },
        }

        for _, pair in ipairs(summary) do
            local r = vgui.Create("EditablePanel", host)
            r:Dock(TOP)
            r:SetTall(24)

            local key = label(r, pair[1], "Fated.14", UI.col("gray"))
            key:Dock(LEFT)
            key:SetWide(UI.w(130))

            local value = label(r, tostring(pair[2]), "Fated.16")
            value:Dock(FILL)
        end

        local actions = vgui.Create("EditablePanel", host)
        actions:Dock(TOP)
        actions:SetTall(40)
        actions:DockMargin(0, 16, 0, 0)

        local saveBtn = vgui.Create("MantleBtn", actions)
        saveBtn:SetTxt("Save to library")
        saveBtn:SetWide(UI.w(200))
        saveBtn:DockMargin(0, 2, 0, 2)
        saveBtn:Dock(LEFT)
        saveBtn.DoClick = function() UI.click() saveAndMaybeSpawn(false) end

        local saveSpawnBtn = vgui.Create("MantleBtn", actions)
        saveSpawnBtn:SetTxt("Save & spawn now")
        saveSpawnBtn:SetWide(UI.w(200))
        saveSpawnBtn:SetPos(UI.w(212), 0)
        saveSpawnBtn.DoClick = function() UI.click() saveAndMaybeSpawn(true) end
    end

    -- =========================================================================
    -- Step switching
    -- =========================================================================

    rebuildStep = function()
        local draft = AINPCS.MantleDraft

        host:Clear()

        backBtn:SetVisible(step > 1)
        nextBtn:SetTxt(step == #STEP_NAMES and "Save & spawn" or "Next")

        if step == 1 then buildIdentity(draft)
        elseif step == 2 then buildVoice(draft)
        elseif step == 3 then buildBody(draft)
        elseif step == 4 then buildBehaviour(draft)
        else buildReview(draft) end
    end

    AINPCS.RebuildWizard = function(n)      -- classic-name parity
        step = math.Clamp(n or 1, 1, #STEP_NAMES)
        maxVisited = math.max(maxVisited, step)
        rebuildStep()
    end

    local function goStep(n)
        step = math.Clamp(n, 1, #STEP_NAMES)
        maxVisited = math.max(maxVisited, step)
        rebuildStep()
    end

    backBtn.DoClick = function()
        if step > 1 then UI.click() goStep(step - 1) end
    end

    nextBtn.DoClick = function()
        if step == #STEP_NAMES then
            UI.click()
            saveAndMaybeSpawn(true)
            return
        end

        if step == 1 and AINPCS.IsBlank(AINPCS.MantleDraft.name or "") then
            AINPCS.PushToast("Give the NPC a name first.", "info")
            return
        end

        UI.click()
        goStep(step + 1)
    end

    rebuildStep()
end

-- =============================================================================
-- Settings page  (Phase 1)
-- =============================================================================

local function buildSettingsPage(page)
    local S = AINPCS.Settings
    if not istable(S.apiKeys) then S.apiKeys = {} end

    -- The frame is fixed-size, so the cap is resolved once.
    local cw = UI.w(CONTENT_W)

    local scroll = vgui.Create("MantleScrollPanel", page)
    scroll:Dock(FILL)

    local canvas = scroll:GetCanvas()

    -- Values now commit on every keystroke, so do not hit the disk on every
    -- keystroke: coalesce writes and let the last one win.
    local SAVE_TIMER = "AINPC_MantleSaveSettings"
    local function persist()
        timer.Create(SAVE_TIMER, 0.4, 1, function()
            if AINPCS.SaveSettings then AINPCS.SaveSettings() end
        end)
    end

    -- ---- layout helpers -----------------------------------------------------
    -- Children dock TOP into the canvas. Controls inside a row are docked LEFT
    -- with a capped width, or absolutely positioned at the right edge of the cap;
    -- a row never relies on inventing its own width.

    local function gap(height)
        local p = vgui.Create("EditablePanel", canvas)
        p:Dock(TOP)
        p:SetTall(height or 10)
    end

    local function note(text, height)
        local l = label(canvas, text, "Fated.14", UI.col("gray"), height or 22)
        l:Dock(TOP)
        return l
    end

    local function section(title, sub)
        gap(10)

        local head = label(canvas, title, "Fated.18b", nil, 26)
        head:Dock(TOP)

        if sub then note(sub, 22) end
    end

    local function row(height)
        local r = vgui.Create("EditablePanel", canvas)
        r:Dock(TOP)
        r:SetTall(height or 40)
        r:DockMargin(0, 0, 0, 4)
        return r
    end

    local function entry(parent, width, placeholderText)
        local e = textEntry(parent, width or cw, placeholderText)
        e:Dock(LEFT)
        return e
    end

    local function combo(parent, width)
        local c = vgui.Create("MantleComboBox", parent)
        c:Dock(LEFT)
        c:SetWide(width or cw)
        c:DockMargin(0, 2, 0, 2)
        return c
    end

    local function btn(parent, label, width, dockRight)
        local b = vgui.Create("MantleBtn", parent)
        b:SetTxt(label)
        b:SetWide(width or 110)
        b:DockMargin(8, 4, 0, 4)
        if dockRight then b:Dock(RIGHT) end
        return b
    end

    -- =========================================================================
    -- Provider
    -- =========================================================================

    section("AI provider", "Used for every NPC. You set this once.")

    local provRow   = row(38)
    local provCombo = combo(provRow)
    local provLabel = {}   -- provider id -> the exact label we added

    for _, p in ipairs(providers.list()) do
        provLabel[p.id] = p.label
        provCombo:AddChoice(p.label, p.id)
    end

    -- SetValue, not SelectChoice: SelectChoice fires OnSelect, which would persist
    -- and rebuild the model list while the page is still being constructed.
    if provLabel[S.provider] then provCombo:SetValue(provLabel[S.provider]) end

    local keyHint = note("", 34)

    -- =========================================================================
    -- Model
    -- =========================================================================

    section("Model")

    local freeRow = row(30)
    local freeChk = vgui.Create("MantleCheckBox", freeRow)
    freeChk:Dock(LEFT)
    freeChk:SetWide(cw)
    freeChk:DockMargin(0, 2, 0, 2)
    freeChk:SetTxt("Free models only")
    freeChk:SetValue(S.freeOnly ~= false)   -- OnChange is wired below: SetValue fires it

    local modelRow  = row(38)
    local modelNote = note("", 18)

    local modelCombo

    --- Single entry point for rebuilding the model list: a provider switch, a
    --- free-only toggle and the live OpenRouter catalog all land here.
    local function rebuildModelCombo()
        if IsValid(modelCombo) then modelCombo:Remove() end
        modelCombo = combo(modelRow)

        local order, models = AINPCS.ModelList(S.provider)
        local labelFor, shown, firstId = {}, 0, nil

        for _, id in ipairs(order or {}) do
            local m = models[id]
            if m then
                local isFree = (m.free ~= false)
                if S.provider ~= "openrouter" or not S.freeOnly or isFree then
                    local label = m.label or id
                    if not isFree then
                        label = string.format("%s  ($%.2f/$%.2f per M)", label,
                            tonumber(m.price_in) or 0, tonumber(m.price_out) or 0)
                    end
                    modelCombo:AddChoice(label, id)
                    labelFor[id] = label
                    firstId = firstId or id
                    shown = shown + 1
                end
            end
        end

        -- The stored model fell off the list (provider switch, delisted model):
        -- fall back to the provider default, then to the first *visible* entry —
        -- order[1] may be filtered out by the free-only toggle.
        if not labelFor[S.model] and shown > 0 then
            local p = providers.get(S.provider)
            local preferred = p and p.defaultModel
            if preferred and labelFor[preferred] then
                S.model = preferred
            else
                S.model = firstId or ""
            end
        end

        if labelFor[S.model] then modelCombo:SetValue(labelFor[S.model]) end

        -- Plain function, NOT a colon method: MantleComboBox calls
        -- OnSelect(index, text, data).
        modelCombo.OnSelect = function(index, text, id)
            S.model = id
            persist()
        end

        modelNote:SetText(shown == 0 and "no models for this provider" or (shown .. " models"))

        if S.provider == "openrouter" and not AINPCS.LiveOpenRouter then
            AINPCS.RequestModels()
        end
    end

    -- The shared file calls this when the live OpenRouter catalog arrives.
    AINPCS.OnModelsChanged = function() rebuildModelCombo() end

    freeChk.OnChange = function(_, value)
        S.freeOnly = value
        persist()
        rebuildModelCombo()
    end

    -- =========================================================================
    -- Key
    -- =========================================================================

    section("API key")

    local keyRow   = row(38)
    local keyEntry = entry(keyRow, cw, "paste your provider key")

    -- Persist on every keystroke, like the classic panel: relying on focus loss
    -- throws the key away if the player just closes the window.
    keyEntry.textEntry.OnValueChange = function(_, value)
        S.apiKeys[S.provider] = AINPCS.Trim(value or "")
        persist()
    end

    function AINPCS.RebuildKeyField()
        if IsValid(keyEntry) then keyEntry:SetValue(S.apiKeys[S.provider] or "") end
    end

    local hostRow   = row(38)
    local hostEntry = entry(hostRow, cw, "Ollama hostname (Ollama only): 127.0.0.1:11434")
    hostEntry:SetValue(S.hostname or "")
    hostEntry.action = function(value)     -- fires on focus loss / Enter
        S.hostname = AINPCS.Trim(value or "")
        persist()
    end

    local function refreshKeyHint()
        local p = providers.get(S.provider)
        keyHint:SetText(string.format("%s    Get a key: %s",
            (p and p.note) or "", (p and p.getKeyUrl) or ""))
    end

    provCombo.OnSelect = function(index, text, id)
        S.provider = id
        S.model = ""
        persist()
        refreshKeyHint()
        rebuildModelCombo()
        AINPCS.RebuildKeyField()
    end

    -- =========================================================================
    -- Voice service
    -- =========================================================================

    section("Voice service (Fish Audio)",
        "Character voices need a local helper with your own Fish key. Start it with relay/start.bat.")

    local pill = UI.StatusPill(canvas, cw)
    pill:Dock(TOP)
    pill:DockMargin(0, 0, 0, 6)

    local pillRow     = row(34)
    local pillRefresh = btn(pillRow, "Refresh status", 150, true)
    pillRefresh.DoClick = function()
        UI.click()
        pill:Refresh()
    end

    local fishRow   = row(38)
    local fishEntry = entry(fishRow, cw - 106, "Fish Audio API key (sk-fish-...)")

    local fishSave = vgui.Create("MantleBtn", fishRow)
    fishSave:SetTxt("Save")
    fishSave:SetPos(cw - 98, 0)
    fishSave:SetSize(98, 36)
    fishSave.DoClick = function()
        local key = AINPCS.Trim(fishEntry:GetValue() or "")
        if key == "" then return end
        UI.click()
        AINPCS.RelaySaveKey(key, function(ok, code, body)
            AINPCS.PushToast(ok and "Fish key saved."
                or ("Rejected: " .. tostring((istable(body) and body.error) or code)),
                ok and "success" or "error")
            pill:Refresh()
        end)
    end

    local libRow = row(36)
    local libBtn = btn(libRow, "Open voice library", 200, false)
    libBtn.DoClick = function()
        UI.click()
        gui.OpenURL(AINPCS.RelayBase() .. "/")
    end

    -- =========================================================================
    -- Fallback voice
    -- =========================================================================

    section("Fallback voice",
        "Used when an NPC has no character voice, or when the voice service is down.")

    local fbRow   = row(38)
    local fbCombo = combo(fbRow)
    local fbLabel = {}

    for _, v in ipairs(Voices.list or {}) do
        if not string.match(v.id, "^relay:") then
            fbLabel[v.id] = v.label
            fbCombo:AddChoice(v.label, v.id)
        end
    end

    if fbLabel[S.fallbackVoice] then fbCombo:SetValue(fbLabel[S.fallbackVoice]) end

    fbCombo.OnSelect = function(index, text, id)
        S.fallbackVoice = id
        persist()
    end

    -- =========================================================================
    -- Volume
    -- =========================================================================

    section("Volume")

    local volRow = row(56)
    local vol    = vgui.Create("MantleSlideBox", volRow)
    vol:Dock(LEFT)
    vol:SetWide(cw)
    if vol.DockMargin then vol:DockMargin(0, 2, 0, 2) end
    vol:SetText("Voice volume")
    vol:SetRange(0, 1, 2)
    -- SetConvar reads the current value and writes on change, replacing the
    -- manual RunConsoleCommand plumbing.
    vol:SetConvar("ainpc_voice_volume")

    gap(16)

    -- ---- boot ----
    refreshKeyHint()
    rebuildModelCombo()
    AINPCS.RebuildKeyField()
    pill:Refresh()
end

--- Classic-name parity: the relay status in the open window refreshes whichever
--- interface is showing.
function AINPCS.RefreshSettingsService()
    if AINPCS.RefreshPill then AINPCS.RefreshPill() end
end

-- =============================================================================
-- Open
-- =============================================================================

function AINPCS.OpenMantle()
    if not UI.hasMantle then return AINPCS.OpenClassic() end

    if IsValid(AINPCS.MantlePanel) then
        AINPCS.MantlePanel:MakePopup()
        return AINPCS.MantlePanel
    end

    local frame = vgui.Create("MantleFrame")
    if not IsValid(frame) then return AINPCS.OpenClassic() end

    frame:SetSize(UI.w(FRAME_W), UI.h(FRAME_H))
    frame:Center()
    frame:MakePopup()
    frame:SetTitle("AI NPCs")
    frame:SetCenterTitle("v" .. tostring(AINPCS.Version or "?"))
    frame:ShowAnimation()

    AINPCS.MantlePanel = frame
    frame.OnRemove = function() AINPCS.MantlePanel = nil end

    -- ---- header: voice service status + refresh ----
    local header = vgui.Create("EditablePanel", frame)
    header:Dock(TOP)
    header:SetTall(56)   -- matches StatusPill: a RIGHT-docked panel takes its height from here
    header:DockMargin(0, 0, 0, 8)

    local refresh = vgui.Create("MantleBtn", header)
    refresh:SetWide(96)
    refresh:SetTxt("Refresh")
    refresh:Dock(RIGHT)

    local pill = UI.StatusPill(header, UI.w(420))
    pill:Dock(RIGHT)

    refresh.DoClick = function()
        UI.click()
        pill:Refresh()
    end

    AINPCS.RefreshPill = function() if IsValid(pill) then pill:Refresh() end end

    -- ---- tabs ----
    local tabs = vgui.Create("MantleTabs", frame)
    tabs:Dock(FILL)

    for _, name in ipairs(PAGE_ORDER) do
        local page = vgui.Create("EditablePanel", tabs)
        page:DockPadding(16, 12, 16, 12)

        if name == "library" then buildLibraryPage(page)
        elseif name == "create" then buildCreatePage(page)
        else buildSettingsPage(page) end

        tabs:AddTab({ title = PAGE_TITLES[name], icon = Material(PAGE_ICONS[name]) }, page)
    end

    -- Other code (Edit / New character / spawn-then-return) jumps pages by name,
    -- so the classic switched(name) contract is preserved here.
    AINPCS.ShowPage = function(name)
        if not IsValid(tabs) then return end
        for index, pageName in ipairs(PAGE_ORDER) do
            if pageName == name then
                tabs:SetActiveTab(index)
                return
            end
        end
    end

    pill:Refresh()

    return frame
end
