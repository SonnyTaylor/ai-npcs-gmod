# Porting the AI NPCs UI to Mantle — plan

Target: `v4.0.0`. Library: [darkfated/mantle](https://github.com/darkfated/mantle) (MIT),
docs at <https://darkfated.github.io/mantle/>, Workshop `3126986993`.
Prerequisite font: Montserrat, Workshop `2924839375` (Mantle requests it itself).

---

## 1. Where we are today

The v3.1 cut already separated **state** from **views**, which is what makes this
port cheap:

| File | LOC | Role | Touch in this port? |
|---|---|---|---|
| `lua/autorun/client/cl_0_ainpcs_shared.lua` | 292 | settings, library, relay helpers, model cache, spawn | **no logic changes** (only expose a palette) |
| `lua/autorun/client/cl_ainpcs_panel.lua` | 907 | Library / Create wizard / Settings, hand-rolled tab strip | **replaced** |
| `lua/autorun/client/cl_ainpcs_interact.lua` | 472 | toasts, E-to-talk chat window, voice engine | chat window + toasts restyled |
| `lua/autorun/client/cl_ainpcs_hud.lua` | 140 | 3D2D nametag, thinking bubble, press-E prompt | **leave alone** (see §4.4) |
| `lua/autorun/server/sv_gmodainpc.lua` | 649 | spawn/chat/TTS | untouched |

Two facts that shape the plan:

* Every widget in `cl_ainpcs_panel.lua` is a raw `DPanel`/`DButton`/`DTextEntry`
  with a hand-written `Paint`. There is no shared widget layer to preserve — so
  Mantle wholesale replaces them, it does not fight them.
* All the panel's layout scars (documented in its own header comment: "scrolling
  pages get a DScrollPanel + DListLayout docked TOP…") are bugs Mantle already
  solved. `MantleScrollPanel`, `MantleTabs`, `MantleTable` remove the whole class
  of collapse bugs.

## 2. Why Mantle is a good fit

* `MantleScrollPanel` handles docking, rubber-band, wheel and inertia itself —
  the `DListLayout` width-0 trap disappears.
* `MantleTabs` (modern + classic styles) replaces the custom tab strip *and* the
  wizard's step bar can reuse the same visual language.
* `MantleTable` gives the Library and Voice list sortable columns, row pooling,
  hover, and a right-click menu for free.
* `Mantle.ui.model_selector` is a modal catalogue **with an interactive 3D
  preview** (drag to rotate, wheel to dolly, reset, auto-rotate) — exactly the
  Body step the wizard currently fakes with a `DListView` + `DModelPanel`.
* `MantleSlideBox:SetConvar("ainpc_voice_volume")` replaces our manual
  `RunConsoleCommand` plumbing; `MantleCheckBox:SetConvar` does the same for flags.
* Shaders (RNDX: rounded rects, Kawase blur, acrylic, shadows) are embedded in
  `mantle/modules/rndx.lua` as a base64 GMA and mounted at runtime — **no shader
  compilation needed** for manual installs. Colours are theme-driven
  (`Mantle.color.theme`, `panel_alpha[1..3]`, `text`, `gray`, …) with 11 built-in
  themes and `mantle_theme`/`mantle_smooth`/`mantle_blur` convars.

## 3. Constraints that decide the architecture

**C0 — verified against the installed build.** The Workshop copy on this machine
(`steamapps/workshop/content/4000/3126986993/gmod-wstool.gma`, addon name
"Mantle - Gmod Library") ships every element and service the plan uses:
`MantleFrame/Tabs/ScrollPanel/Table/ComboBox/CheckBox/SlideBox/Entry/Text/Panel/Btn`,
`MantleRadialPanel` + `radial_menu`, `model_selector`, `draw_ent_text`,
`panel_alpha` / `focus_panel` / `hover_overlay` / `text_muted`, and the
`rndx_shaders_*` GMA. The Montserrat font item (`2924839375`) is installed too,
so `Fated.*` renders real Montserrat rather than a fallback face.

Callback conventions confirmed in that source, because they differ from Derma:

| Element | Fires as | Gotcha |
|---|---|---|
| `MantleComboBox` | `OnSelect(index, text, data)` | plain function, **no `self`** (Derma passes `_, i, text, data`) |
| `MantleComboBox:SelectChoice(i)` | **fires `OnSelect`** | pre-select with `SetValue(text)` instead |
| `MantleComboBox` | — | no `Clear()`: rebuild = remove + recreate |
| `MantleCheckBox` | `OnChange(self, value)` | `SetValue` fires it — wire `OnChange` after the initial `SetValue` |
| `MantleSlideBox` | `OnValueChanged(self, value)` | `SetConvar` reads the convar and fires once |
| `MantleEntry` | `action(value)` | focus loss / Enter only — persist keys from `textEntry.OnValueChange` |
| `MantleFrame` | `Notify(text, dur, col)` | no `SetDeleteOnClose`; `Close()` animates then removes |
| `MantleText`, `MantleBtn` | — | **also** default to an 8px all-round `DockMargin`; inside a fixed-height row that margin silently eats the sibling below (this hid the status pill's second line in-game) |
| `MantleEntry` | `action(value)` on focus loss | **do not use it.** It paints the value as one unclipped `draw.SimpleText` slid by an animated offset, and places the caret at `GetTextSize(whole value)` — the end of the string — so long text bleeds out of the box and mid-string edits jump. We wrap a raw `DTextEntry` in a `MantlePanel` instead (`textEntry()`). |
| `DTextEntry` | `OnValueChange(self, value)` | fires only on Enter / focus loss unless `SetUpdateOnType(true)`. Nothing set it, so typed values could be dropped when a button click did not move focus. |



**C1 — Mantle is a separate Workshop addon.** Workshop does not install
dependencies. A hard requirement would leave every current subscriber (3k+) with
a dead C-menu entry until they notice and subscribe. That is a worse regression
than a slightly inconsistent UI.

**C2 — Vendoring Mantle into the addon is not safe.** MIT allows it, but if a
player already has the official addon both copies `vgui.Register` the same class
names and both mount the shader GMA. Whichever loads last wins, silently, at
whatever version mix. Not worth it.

**C3 — Mantle has no multiline entry and no combo `Clear()`.** Two real gaps we
must fill ourselves (§6).

**C4 — Mantle is 2D-only.** RNDX blur reads the screen render target; it is not
usable inside `cam.Start3D2D`. The nametag/bubble HUD stays hand-drawn.

### Decision: Mantle-first with the Derma panel kept as a frozen fallback

* One gate at load time; if `Mantle` is present we open the Mantle UI, otherwise
  the existing panel opens unchanged plus a one-time hint.
* The v3.1 Derma panel is **frozen** — no further feature work, bug fixes only if
  they affect non-Mantle users. It is the compatibility path, not a second UI to
  maintain in parallel.
* `ainpc_ui 0|1|2` convar (`auto` / `derma` / `mantle`) so we — and players with
  broken shader support — can force either path.

This keeps the v3.1 file as-is, so it is also the rollback.

## 4. Design decisions

### 4.1 Detection

```lua
-- cl_1_ainpcs_ui.lua
AINPCS.UI = AINPCS.UI or {}

AINPCS.UI.hasMantle = istable(Mantle)
    and istable(Mantle.ui)
    and istable(Mantle.color)
    and isfunction(Mantle.func and Mantle.func.w)

local cv = CreateClientConVar("ainpc_ui", "0", true, false,
    "0 = auto (Mantle when installed), 1 = classic Derma, 2 = force Mantle")

function AINPCS.UI.useMantle()
    local mode = cv:GetInt()
    if mode == 1 then return false end
    if mode == 2 then return AINPCS.UI.hasMantle end
    return AINPCS.UI.hasMantle
end
```

`CreateClientConVar` (not `CreateConVar`) because this is a display choice.

### 4.2 Palette

Do not hardcode a second colour set. Two layers:

* **Structure/accents** come from Mantle (`Mantle.color.theme`, `panel_alpha[n]`,
  `text`, `gray`, `hover_overlay`, `focus_panel`) so theme switching and
  `mantle_smooth` "just work".
* **Semantics** stay ours and stay fixed, because they carry meaning:
  `ok = Color(90,200,120)`, `bad = Color(235,90,90)`, `warn = Color(235,190,90)`,
  `speech = Color(255,210,120)`. Expose as `AINPCS.UI.sem` and have the Derma
  panel read from it too, so the two paths can't drift.

Do **not** register a Mantle theme for the addon — it would fight `mantle_theme`
and surprise anyone who set theirs. If we later want the blue accent as default,
do it with `MantleBtn:SetColor`, not a global theme.

### 4.3 Fonts

Mantle lazily creates `Fated.<size>` / `Fated.<size>b` (Montserrat Medium/Bold)
through a `surface.SetFont` hook. Inside Mantle UI use `Fated.16`, `Fated.18b`,
`Fated.20b`… and delete the old `AINPC_*` Roboto usage from that path.
The Roboto fonts stay registered for the Derma fallback and the 3D HUD.

**Verify in game**: if Montserrat is absent, Mantle fonts fall back to the
engine's default face. Check on first launch and `ErrorNoHaltOnce` a hint telling
the player to subscribe to `2924839375`. Cheap, prevents "the UI looks wrong"
reports.

### 4.4 What does *not* get Mantle

* `cl_ainpcs_hud.lua` — 3D2D nametag, thinking bubble, subtitle bubble (C4).
  Structure stays; colours and plates move to RNDX when available (§5.3), and
  `draw_ent_text` is explicitly not adopted (§5.5).
* Voice engine in `cl_ainpcs_interact.lua` — zero UI.
* Toasts: keep the custom `HUDPaint` stack. `Mantle.notify` is a *server* chat
  notice, not a client overlay — so it replaces server-side `chat.AddText` calls
  in `sv_gmodainpc.lua`, and the overlay keeps serving client-local feedback
  (saved, voice failure, spawn result).

## 5. Component mapping

| Today (Derma) | Mantle | Notes |
|---|---|---|
| `DFrame` + custom `Paint` | `MantleFrame` | `SetTitle`, `SetCenterTitle`, `ShowAnimation`, `:Notify(text, dur)` replaces our toast for in-panel confirmations |
| hand-rolled tab strip + `showPage()` | `MantleTabs` + `AddTab({title, icon}, page)` | `SetActiveTab(id, silent)` for programmatic jumps (Library → Create on Edit) |
| `DScrollPanel` + `DListLayout` | `MantleScrollPanel` + `Dock(TOP)` children | methods live on the shared `scroll` base: `AddItem/Clear/SetScroll/GetScroll` |
| library card `DPanel` | `MantleTable` (Name / Voice / Body / Replies) + row action | + `SetAction` = spawn, `SetRightClickAction` = edit/delete, `+ New` in a docked footer `MantleBtn` |
| `styledButton()` | `MantleBtn` | `SetColor(Hover)/SetRadius/SetIcon/SetRipple/SetTxt` |
| `DTextEntry` (single line) | `MantleEntry` | `SetTitle/SetPlaceholder/GetValue/SetValue`, raw box at `.textEntry` |
| multiline description | **`AINPCS.UI.MultilineEntry`** (§6.1) | Mantle gap |
| `DComboBox` | `MantleComboBox` | `AddChoice(text, data)`, `OnSelect(i, text, data)`; **no `Clear()`** (§6.2) |
| `DCheckBoxLabel` | `MantleCheckBox` | `SetTxt`, `GetBool`, `SetConvar` |
| `DNumSlider` (volume) | `MantleSlideBox` | `SetRange(0, 1, 2)` + `SetConvar("ainpc_voice_volume")` |
| NPC list + `DModelPanel` (step 3) | **`Mantle.ui.model_selector`** | modal; feed `{ model, name, description }`, callback → class id |
| `DLabel` text blocks | `MantleText` | `SetFont/SetColor/SetAlign/SetVAlign/SetPadding`, real word wrap |
| voice results `DListView` | `MantleTable` | columns: Voice, Language, Engine |
| chat window `DFrame` + `DScrollPanel` | `MantleFrame` + `MantleScrollPanel` + `MantleText` bubbles + `MantleEntry` + `MantleBtn` | |
| separator / spacer panels | `MantlePanel:SetColorAlpha(2)`, `SetRadius` | |

Stable service API worth learning once: `Mantle.color`, `Mantle.func.w/h`,
`Mantle.func.sound`, `Mantle.func.approachExp`, `Mantle.func.LerpColor`,
`Mantle.func.animate_appearance`, `Mantle.func.ClampMenuPosition`.

### 5.1 Extra surface — the in-game side

Mantle is not only a window toolkit. Six more APIs change the plan:

| API | Where it lands |
|---|---|
| `Mantle.ui.radial_menu(opts)` | **New capability** — an in-game action wheel for the NPC you're looking at (§5.2) |
| `RNDX.Rect/Circle` + `:Rad/:Color/:Outline/:Shadow/:Blur/:KBlur/:Acrylic/:Fade/:Clip/:Angles` | toasts, press-E prompt, thinking bubble, chat bubbles, scroll edges (§5.3) |
| `Mantle.func.sound([path])` | click/hover feedback on primary actions (§5.4) |
| `Mantle.notify(pl, color, header, text)` | **server-side** chat notices (spawn denied, TTS off, admin gate) — replaces ad-hoc `chat.AddText` on the server |
| `Mantle.func.draw_ent_text(ent, text, posY)` | *not* adopted as-is (§5.5) |
| `Mantle.func.animate_appearance` / `ClampMenuPosition` | `frame:ShowAnimation()` wrapper; keep chat windows on screen |

Two `Mantle.ui.*` facts that matter: **they are singletons**. `radial_menu`,
`model_selector` and `text_box` each `Remove()` the previously created instance
before making a new one. Never open two at once, and nil out our reference in the
panel's `OnRemove`.

### 5.2 Radial menu — the real feature unlock

Today, `E` on an NPC does exactly one thing: open a chat window. A radial menu
makes the NPC an object you can *operate*:

```lua
local menu = Mantle.ui.radial_menu({
    title = npcName,
    desc  = "AI NPC",
    radius = 300, inner_radius = 110,
    hover_sound = false, -- we already have voice; two sounds is noise
})

menu:AddOption("Talk",        openChat,  "icon16/comment.png",   "Open the chat window")
menu:AddOption("Repeat last", repeatLast, "icon16/sound.png",    "Replay the previous line")
local voice = menu:CreateSubMenu("Voice", "Change how they sound")
-- one option per AINPCS.Voices entry, relay voices included
menu:AddSubMenuOption("Voice", voice, "icon16/user.png", voiceLabel(npc))
menu:AddOption("Despawn",     despawn,   "icon16/bin_closed.png", "Remove this NPC")
```

* `1`–`9` select, `ESC`/click-outside closes, clicking the centre goes back a
  level (works with `:CreateSubMenu`), `:SetCenterText` updates the hub live.
* Needs mouse+keyboard capture, so it is mutually exclusive with the chat
  window. Proposed input model: **tap E = chat window (unchanged), hold E =
  radial**. Implement the hold with `hook.Add("KeyPress"/"KeyRelease")` and a
  0.25 s threshold, and only when the existing `AINPC_UsePrompt` trace already
  finds an AI NPC in range — no new tracing.
* Voice actions need a net message the server does not have yet (per-NPC voice
  change, despawn). That is a server-side addition, not a UI port: keep it in its
  own phase so the port can ship first.

### 5.3 RNDX — restyling the HUD without Derma

`RNDX` is a client-only global created by Mantle's autorun, so every use is
`if RNDX then … else draw.RoundedBox(…) end`. Concrete uses:

* **Toasts** — `RNDX.Rect(x,y,w,h):Rad(10):Color(Mantle.color.panel_alpha[2]):Shadow(20, 2, 0, 4)`
  plus an accent bar `:Radii(10, 0, 0, 10)` for `sem.ok/bad/warn`.
* **Press-E prompt** — `:Rad(16):Blur(2)` (or `:Acrylic{…}` for the fancy variant)
  instead of a flat `draw.RoundedBox`.
* **Thinking bubble** — replace the three `●` glyphs with a rotating arc:
  `RNDX.Circle(cx, cy, r):Angles(a, a + 90):Color(sem.speech)`, `a` advanced with
  `Mantle.func.approachExp`. Same information, far better read at distance.
* **Chat bubbles** — `:Radii(14, 14, 0, 14)` for the NPC and `:Radii(14, 14, 14, 0)`
  for the player, `:Clip(panel)` on the scroll canvas so bubbles can't bleed over
  the input row.
* **Scroll edges** — `:Fade(1, 0)` at the top of `MantleScrollPanel` gives the
  "content continues" cue the Derma panel never had.

Cost rule: `:Blur` / `:KBlur` / `:Acrylic` read the screen render target and are
per-frame expensive. Budget: **at most two per frame** (frame/chat-window
backdrop + prompt). Never inside `MantleTable` rows or a 5-item toast stack.

### 5.4 UI sound

`Mantle.func.sound()` plays `mantle/btn_click.ogg` client-side. Use it on
committing actions only — save, spawn, open, delete-confirm — not on hover and
not on every button. Gate it behind a client convar `ainpc_ui_sfx 1` so players
who keep their UI silent can turn it off, and never on the same frame as a TTS
line.

### 5.5 `draw_ent_text` — measured, and rejected

It looks like a drop-in replacement for our hand-rolled 3D2D nametag, but:

* hard-capped at **380 units** (ours draws to 1200 — the cross-map nametag is a
  feature people use);
* **one line only** (we need name + "AI NPC" + thinking + the live subtitle);
* fixed plate geometry and a `pp/blurscreen`-style plate drawn inside `cam.Start3D2D`,
  which is exactly where blur is unreliable;
* it owns the billboard yaw and bob, which would fight our existing subtitle offset.

Verdict: keep `cl_ainpcs_hud.lua`'s 3D2D structure, adopt only its *techniques* —
plate with `:Radii`, `surface.SetAlphaMultiplier` fade, `approachExp` eased scale,
and `Mantle.color.panel_alpha`/`text` so the tag matches the windows.

## 6. Components we must build (Mantle gaps)

### 6.1 `AINPCS.UI.MultilineEntry`

The description field is the single biggest text input and Mantle has no
multiline entry. Build one on `MantlePanel` + a raw `DTextEntry:SetMultiline(true)`
docked inside, reusing Mantle's look:

* `Mantle.color.focus_panel` fill, `Mantle.color.theme` 1px outline at
  `approachExp`-lerped alpha while editing (mirror `MantleEntry:_paintEntry`).
* `SetTitle`, `GetValue`, `SetValue`, `OnValueChange` — same surface as
  `MantleEntry` so the wizard code is symmetric.
* Keep it in our addon, not a Mantle fork; if Mantle later adds multiline we swap
  the constructor and delete ~60 lines.

### 6.2 `AINPCS.UI.RebuildCombo(row, items)`

`MantleComboBox` cannot be emptied. Provider switch today rebuilds the model
combo (`AINPCS.BuildModelCombo`). Solution: keep the combo in a fixed-height row
panel and `row.ref:Remove()` + recreate. Wrap it once so no caller improvises.

### 6.3 `AINPCS.UI.StatusPill` / `StepBar`

* **StatusPill** — the header's "voice service: ready / NOT running" line. A
  `MantlePanel` row with a colour dot (`Mantle.func.LerpColor` for the on-change
  transition) + `MantleText` sub-label. Used in the header and in Settings.
* **StepBar** — wizard 1..5 indicator: `RNDX.Rect` pills, current step in
  `Mantle.color.theme`, completed in `hover_overlay`, upcoming in `panel_alpha[1]`,
  clickable to jump back.

### 6.4 Body step, concretely

`Mantle.ui.model_selector` takes model **paths**, we store NPC **classes**.

1. Build the catalogue from `list.Get("NPC")`: `{ model = data.Model, name = data.Name, description = id }`
   and remember `modelToClass[model] = id`.
2. Classes whose registry entry has no `Model` (`npc_zombie` variants, modded NPCs)
   are excluded from the selector and reachable from a "More bodies…" `MantleTable`
   fallback, which calls the existing `AINPC_ModelPreview` net round-trip to learn
   the model.
3. Wizard step 3 shows: current body name + model + an inline `DModelPanel` in a
   `MantlePanel` (idle rotate), a `MantleBtn` "Browse bodies" that opens the
   selector, and a small "Show all NPC classes" `MantleTable` for the long tail.
4. Selected class stays `draft.class`; nothing about the spawn payload changes.

Rationale: the selector is modal and returns exactly one model, so it cannot be
the *only* affordance — we still want a persistent preview inside the step.

## 7. Phases

Each phase ends in a state that can ship. Phase 0 first, because without the gate
nothing else is safe to merge on `master`.

### Phase 0 — gate + skeleton (½ day)
- [x] `cl_1_ainpcs_ui.lua`: detection, `ainpc_ui` convar, palette (`sem`), `ainpc_ui_sfx` convar, `col()`/`panel()` accessors with fallbacks.
- [x] `cl_2_ainpcs_open.lua`: single `AINPCS.Open()` router; concommand + `DesktopWindows` icon moved here so the classic panel is a pure view.
- [x] `cl_ainpcs_mantle_panel.lua`: `MantleFrame` shell, `MantleTabs` with three placeholder pages, header `StatusPill` + Refresh, `AINPCS.ShowPage(name)` parity, `OnRemove` clears the panel ref.
- [x] `cl_ainpcs_panel.lua`: `AINPCS.Open` → `AINPCS.OpenClassic` (frozen), entry points removed.
- [ ] `resource.AddWorkshop("3126986993")` — Workshop collection/docs note (README, release task).
- **Accept:** `ainpc_ui 1` gives the identical v3.1 window; `ainpc_ui 0` on a machine without Mantle gives the v3.1 window; on a machine with Mantle the shell opens, tabs switch, nothing errors in console.

### Phase 1 — Settings in Mantle (1 day)
Highest value, lowest risk: mostly form controls, no custom drawing.
- [x] `MantleScrollPanel` page, sections Provider / Model / Key / Voice service / Fallback voice / Volume.
- [x] Provider + model `MantleComboBox`; free-only `MantleCheckBox` driving `AINPCS.BuildModelCombo` replacement via a `rebuildModelCombo()` closure (Mantle's combo cannot be cleared).
- [x] API key `MantleEntry` persisting on `textEntry.OnValueChange` (focus-loss `action` alone would drop the key when the window is closed); Ollama hostname entry.
- [x] Volume `MantleSlideBox:SetRange(0,1,2)` + `SetConvar("ainpc_voice_volume")`; manual `RunConsoleCommand` gone.
- [x] Fish key + Save `MantleBtn`, `UI.StatusPill` + Refresh, `RelayHealth`; classic-name parity kept for `AINPCS.RebuildKeyField`, `AINPCS.OnModelsChanged`, `AINPCS.RefreshPill`, `AINPCS.RefreshSettingsService`.
Detour from the plan: section headings, notes and the status pill span the full
canvas while *controls* are capped at `CONTENT_W` — a capped head over a full-width
divider looks intentional, a capped band floating in a wider page does not.
- **Accept:** every value round-trips through `AINPCS.Settings` and `data/ai_npcs_settings.json`; changing provider/model/free-only behaves as before.

### Phase 2 — Library in Mantle (1 day)
- [x] `MantleTable` (Name / Voice / Body / Replies) + `SetAction` = spawn, `SetRightClickAction` = our own `Mantle.ui.derma_menu()` with Spawn / Edit / Delete.
- [x] Built-in table context menu **disabled** (`SetContextMenuEnabled(false)`): its "delete row" would drop the row from the table without touching the saved JSON.
- [x] Docked footer: `MantleBtn` "+ New character" + a hint line that doubles as the empty state and the row count.
- [x] `AINPCS.RebuildLibrary()` preserved as the single refresh entry point; the entry rides on the row (`row.entry`) so a column sort cannot desync it from a side index.
- [x] `AINPCS.MantleDraft` + `AINPCS.NewCharacter()` / `AINPCS.EditEntry(entry)`, because the classic panel's `draft` is a file-local it cannot share.
- **Accept:** spawn from the table, edit prefills every wizard field, delete removes the row and the JSON entry.

### Phase 3 — Create wizard in Mantle (1.5–2 days)
- [x] `StepBar` (§6.3) drawn with `RNDX.Rect` pills, clickable up to the furthest step visited; `MantleBtn` Back / Next / Save & spawn.
- [x] Step 1: `MantleEntry:SetTitle("Name")` + `AINPCS.UI`-style `multilineEntry` (§6.1) for the description, both persisting on `textEntry.OnValueChange`.
- [x] Step 2: `MantleEntry` search + `MantleTable` voice results + Preview `MantleBtn`, with the same searching / no-matches / selected states.
- [x] Step 3: inline `DModelPanel` in a `MantlePanel` + "Browse bodies" via `Mantle.ui.model_selector`, plus a full class `MantleTable` for classes the selector cannot represent.
- [x] Step 4: reply-speed `MantleComboBox`, Speak `MantleCheckBox`.
- [x] Step 5: review rows + Save to library / Save & spawn now.
- **Accept:** full parity walkthrough: create → save → library → spawn → edit → save → spawn.

Two deviations worth knowing:
* The wizard body step needs **both** paths. `model_selector` returns exactly one
  model, but the registry maps many classes onto shared models and some classes
  carry no `Model` at all — so the modal is the pretty path and the class table is
  the completeness path. First id wins in `modelToClass`.
* `multilineEntry` is a `MantlePanel` + raw `DTextEntry:SetMultiline(true)`. It has
  no focus-ring animation (MantlePanel owns `Paint`); adding one would mean an
  overlay child drawing `RNDX.Rect:Outline` from the entry's `IsEditing()`.

### Phase 4 — chat window (1 day)
- [ ] `AINPCS.OpenChatWindow` → `MantleFrame:SetCenterTitle("Talking to <name>")`; `MantleScrollPanel` with `MantleText` bubbles ("You" accent, NPC speech colour, error colour).
- [ ] `MantleEntry` + Send `MantleBtn`; send on Enter (`entry.textEntry.OnEnter`) and button — **not** on focus loss (`entry.action`), or a tab-out would fire a message.
- [ ] Keep `ScrollToChild`-equivalent: after append, `scroll:SetScroll(max)`. Verify against the real `GetScroll` semantics.
- [ ] Position/size via `Mantle.func.w/h` clamped so it fits a 1280×720 client.
- [ ] Toasts: RNDX rounded rects under `if RNDX`.
- **Accept:** two NPCs, two windows, reply routing and history replay still correct; window removal clears `AINPCS.ChatWindows[idx]`.

### Phase 5 — HUD + toasts on RNDX (½ day)
- [ ] `if RNDX then` restyle pass on toasts, press-E prompt, thinking arc, chat
      bubbles, scroll fade (§5.3). `draw.RoundedBox` remains the fallback branch.
- [ ] Server-side `chat.AddText` for spawn-denied / admin-gate / TTS-off routed
      through `Mantle.notify` when the server has Mantle (§5.1).
- **Accept:** with `RNDX` nil everything still draws; with it, no panel blurs more
  than the budget in §5.3 and framerate is unchanged at 1080p.

### Phase 6 — radial menu (new capability, 1–1.5 days)
Ships after the port, not with it — it needs new net messages.
- [ ] Net: `AINPC_SetVoice`, `AINPC_Despawn` (server-validated: owner or admin,
      same gates as spawn).
- [ ] Hold-E detection next to the existing `AINPC_UsePrompt` trace; tap-E keeps
      opening the chat window exactly as now.
- [ ] `Mantle.ui.radial_menu` with Talk / Repeat last / Voice (submenu) / Despawn.
- [ ] Derma fallback: a simple `DPanel` list, or gate the feature behind
      `AINPCS.UI.useMantle()` — acceptable for a brand-new feature.
- **Accept:** no double-open with the chat window; `ESC` always closes; NPC died
  mid-menu → menu closes without erroring.

### Phase 7 — polish, parity, release (½–1 day)
- [ ] `MantleFrame:Notify` where the Derma panel pushes toasts; keep toasts for cross-panel events (spawn result, voice failure).
- [ ] Theme sanity: `dark`, `dark_mono`, `blue` at minimum; `mantle_smooth 0`; `mantle_blur 0`; `mantle_depth_ui 0` must not break layout.
- [ ] `ainpc_ui 1` parity diff against v3.1, then decide whether the Derma panel stays (recommended: yes, for one release, then retire with a startup notice).
- [ ] `AINPCS.Version = "4.0.0"`, CHANGELOG entry, README "Requires Mantle (optional — classic UI otherwise)", `WORKSHOP_DESCRIPTION.md` + collection note, `addon.json` ignore list gets `MANTLE_PLAN.md`.
- [ ] `luacheck` pass on the new files.

## 8. Risks / known unknowns

| Risk | Mitigation |
|---|---|
| Mantle missing → user sees old UI and wonders why screenshots differ | one-time toast: "Install Mantle for the new interface" with the Workshop id |
| Montserrat missing → default font, looks off | runtime font check + hint; Montserrat id in docs |
| RNDX shader mount fails on odd setups | everything degrades to `ainpc_ui 1`; document the convar in README troubleshooting |
| Another addon rebinds `vgui.Register("Panel", …)` (Mantle uses plain `'Panel'` pages) | create pages as `'EditablePanel'` where we can, and smoke-test with a heavy addon set |
| `mantle_smooth`/blur cost on low-end GPUs | verify no per-frame `RNDX.Rect` in a `Paint` that also blurs; point users at `mantle_blur 0` |
| `MantleEntry` focus timing (`RequestFocus` needs a `timer.Simple`, as in Mantle's own `text_box`) | mirror Mantle's 0.1s pattern in the chat window |
| `Mantle.ui.model_selector` loads ~100 preview models | curate the initial catalogue (humanoid/citizen/combine/zombie sets), long tail behind "Show all NPC classes" |
| `Mantle.ui.radial_menu` / `model_selector` are singletons | one at a time by design; nil our references in `OnRemove` |
| Hold-E vs tap-E misfires (player taps, menu flashes) | 0.25 s threshold + open only if the aim trace already has an AI NPC; close on `OnMouseReleased` of the keybind |
| RNDX blur cost stacking (frame + chat + toasts) | hard budget of two blur draws per frame; no blur in list rows |
| `Mantle.func.sound()` clashing with TTS | `ainpc_ui_sfx` convar, commit-only sounds, never the same frame as `sound.PlayURL` |
| Mantle version drift (`Mantle.color` keys renamed across releases) | detection checks the keys we use; wrap reads in small accessors with fallbacks |
| **API key is rendered in plaintext** (classic panel too) | Phase 7: masked entry with a reveal toggle. Cosmetic only — the key still goes to the server, see ROADMAP v2.7 |
| Default 8px `DockMargin` on *every* Mantle element | one helper per widget type (`label`, `entry`, `combo`, `btn`) so the margin is cleared in one place |

### In-game findings so far (v0.1 of the port)

Confirmed working on this machine with the Workshop Mantle build: frame + tabs +
header, Settings page end to end — provider/model combos with the live OpenRouter
catalog (400 models), free-only toggle, API key + hostname entries, status pill
state machine, scrolling.

Fixed from the first screenshot:
- **Status pill sub-line was invisible.** Cause: `MantleText` defaults to an 8px
  all-round `DockMargin`; inside the 48px pill the title consumed 20 + 16 of
  margin and the sub-label was left with 2px. Every docked `MantleText` now goes
  through one `label()` helper that clears margin + padding, and the pill/header
  grew to 56px to fit a 22px title over a 20px sub.
- Button vertical margins cleared in docked rows (a `MantleBtn` in a 38px row was
  rendering 22px tall).
- **Typing fields glitched past a certain length, and text came back blank after a
  step change.** Two separate causes: `MantleEntry`'s manual text painter (no
  clipping, caret pinned to the end of the string) and `DTextEntry`'s default
  update-on-type being off, so values typed into a field that never lost focus were
  dropped and the wizard rebuilt the step from a stale draft. Single-line fields
  are now a raw `DTextEntry` inside a `MantlePanel` with our own focus ring, all
  fields commit per keystroke, and settings writes are debounced.

## 9. Manual test matrix

No headless coverage exists for GMod UI, so this is a checklist, not a suite:

1. No Mantle installed → `ainpc_ui 0` opens v3.1 exactly.
2. Mantle installed → `ainpc_ui 2` opens Mantle UI; `ainpc_ui 1` still opens v3.1.
3. Resolutions 1920×1080, 2560×1440, 1366×768 (scaling via `Mantle.func.w/h`).
4. Themes `dark`, `blue`; `mantle_smooth 0`; `mantle_blur 0`.
5. Existing `data/ai_npcs_settings.json` + `ai_npcs_library.json` from v3.1 load unchanged.
6. Voice relay down / up / no key → StatusPill in all three states.
7. Spawn from Library, from wizard, edit an entry, delete an entry.
8. Chat window: send via Enter, via button, receive reply, error reply, window on dead NPC.
9. Dedicated server: client without Mantle, client with Mantle, both at once.
10. Hold-E opens the radial menu, tap-E opens chat, never both; `1`–`9` and `ESC`
    behave; voice change applies to the NPC everyone hears.

## 10. Effort

Roughly **6–8 focused days** for phases 0–7, with the wizard (Phase 3) and the
chat window (Phase 4) carrying the uncertainty. Phase 0 alone already makes the
port mergeable, and Phase 1 alone is a shippable "new settings screen".
Phase 6 (radial menu) is optional and independently shippable — it delivers the
ROADMAP's v2.5 "actions" direction without touching tool calling.

## 11. Decisions (locked by @SonnyTaylor)

1. **Dependency posture** — **soft**. Mantle-first, the v3.1 Derma panel frozen as
   the compatibility path and the rollback, routed by `AINPCS.UI.useMantle()` and
   overridable with `ainpc_ui 1|2`. Vendoring rejected (register/shader collision
   with a parallel official install).
2. **Retirement date for the Derma panel** — keep for one release; revisit after
   4.0.0 has been on the Workshop for a few weeks.
3. **Library as table vs cards** — `MantleTable` (sortable, row pooling, free
   right-click menu).
4. **Wizard vs single-page form** — **keep the 5-step wizard**. Same content and
   flow as today, maps onto the existing `draft` / `BuildStep` code.
5. **Radial menu** — **Phase 6, after the port ships.** Needs two new server net
   messages (`AINPC_SetVoice`, `AINPC_Despawn`) and a hold-E input model.
6. **UI sound** — on by default (`ainpc_ui_sfx 1`), commit-only actions, never on
   hover and never in the same frame as a TTS line.
