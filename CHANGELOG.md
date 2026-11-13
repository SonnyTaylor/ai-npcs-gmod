# Changelog

All notable changes to AI NPCs. Format loosely follows Keep a Changelog; this
addon is shipped through the Steam Workshop, so versions match Workshop updates.

## [4.2.0] — they remember you, and they cost less

### New — memory that survives

- **Persistent character profiles** (`data/ai_npc/profiles/<id>.json`). An NPC is
  keyed to a **stable profile id — the saved character's id, never the entity
  index** — so memories, opinions, notes and kill/death counts survive death,
  respawn, map changes and the duplicator. Writes are debounced (8s) and forced on
  removal and cleanup. `sanitizeProfile()` repairs older or hand-edited files
  instead of crashing on them.
- **Player personas** (`data/ai_npc/personas.json`): a Settings box where you say
  what NPCs should call you and a line about yourself. Included in every NPC's
  situation report, so they stop guessing from your Steam name.
- Kills and deaths are counted per profile and fed back to the model.
- `ainpc_spawn <name>` re-spawns a saved character from its profile, memory intact.

### New — your key stays on your PC

- **Client-side generation.** On a server you do not host, the server builds the
  prompt and sends it to *your* game, which makes the provider call with *your*
  key and returns only the finished line. The server never sees the key.
  Singleplayer and listen-server hosting are unchanged: the key never travels at
  all there, so generation stays server-side.
- `ainpc_fish_key` lets a dedicated-server owner supply the key used to render
  character voices, since those are rendered once for everyone.

### New — cost control

- `ainpc_max_rpm` (20/NPC) and `ainpc_global_rpm` (60/server) rate-limit requests;
  the automatic reactions (being attacked, witnessing a death) make calls nobody
  asked for.
- `ainpc_status` reports per-NPC provider/model, request rate, estimated tokens
  and whether the key is held server-side or client-side.
- A rejected key or missing model pauses unprompted calls for two minutes instead
  of retrying on every event.

### Fixed

- **A reply that failed to parse as JSON could be read aloud verbatim**, including
  the `{"thought": ...}` scaffolding — the most-reported bug in comparable addons.
  `AINPCS.CleanSpokenText()` now recovers the `say` field from truncated JSON and
  stays silent when there is nothing to say.
- **No navmesh produced silent failure.** Spawning on a map without one now says
  so instead of leaving NPCs unable to follow.
- `ainpc_debug` is its own convar (`1` prompts/replies, `2` full payloads) rather
  than requiring `developer`.

## [4.1.0] — voices work out of the box, NPCs know what is happening

### New — guided setup

- **First-run wizard** (`cl_ainpcs_setup.lua`). Opens the first time the panel is
  opened without a working AI key, and again any time from Settings → *Run setup
  again* (or `ainpc_setup`). Five steps: what is needed, pick a provider, get and
  **verify** the key, optionally connect Fish Audio, summary.
- Each key step links straight to that provider's key page (`console.groq.com/keys`,
  `openrouter.ai/keys`, `fish.audio/app/api-keys/`, …) and tests the pasted key
  against the provider before saving it, so a rejected key is reported as
  rejected instead of surfacing ten minutes later as a failed NPC reply.

### Changed — no more relay

- **The Python/PowerShell voice relay is gone.** Fish Audio runs entirely inside
  the game: the client searches and validates the key, and the server synthesises
  each spoken line and streams the mp3 to nearby players, so nobody needs a
  second program, a `.bat` file, or their own key to *hear* an NPC.
- Built-in Google/SAPI4 voices stay keyless, and `relay:<id>` voice ids from 2.x
  are normalised to `fish:<id>` so saved characters keep working.

### New — the NPC actually knows what is going on

- **Situation report** replaces the old single system prompt: health, burning,
  current activity, weapon in hand, nearby players with distance/direction/health
  and whether they are aiming at the NPC, nearby creatures with hostility, a
  timestamped event log (being shot, kills, gunfire, deaths) and a multi-speaker
  transcript.
- **Per-player memory and affinity** — NPCs remember facts about players and how
  they feel about them, and the relationship is shown back to the model.
- **LLM actions**: `follow`, `stay`, `come`, `wander`, `attack`, `stop_attacking`,
  `flee`, `switch_weapon`, `drop_weapon`, `use`, `gesture`. Actions are declared in
  the reply JSON and executed on the NPC's own AI.
- **Mouth movement and facial expressions.** Speech drives the same flexes as
  `GM:MouthMoveAnimation` (`jaw_drop`, `left_part`, `right_part`, …) in time with
  the audio channel's level, and the model's chosen emotion drives the face.
- **Native HL2 voice lines are suppressed** on AI NPCs so a Citizen's stock
  dialogue no longer talks over the AI.

### Changed — chat and pickers

- **Text now appears when the voice starts.** Replies are held client-side until
  the audio channel for that NPC is actually playing (or ~4s if the voice host is
  down), instead of the text racing ahead of the speech.
- **One body browser** replaces the duplicate list + "browse bodies" pair: a
  searchable, paged icon grid over NPC bodies *and* playermodels, with a live 3D
  preview. Body choice is stored per character and applied after spawn.
- **Voice picker rebuilt** around search: the default view is Fish Audio's most
  used voices (not a hardcoded pin list), duplicate uploads of the same character
  collapse into one row, rows carry a free pre-rendered **▶ Play** sample,
  language filter and paging, and ★ pins float to the top of the first page.
- **Chat window keeps history** per NPC (including lines sent with `/say` or
  proximity chat), and gained Follow / Stay / Calm / Clear chat / Edit NPC
  buttons plus a live in-game character editor.
- Weapon selection added to the Create wizard (Behaviour step).

### Fixed

- **NPCs were named after their spawn class.** The display name is now a single
  source of truth (`AINPCS.NPCName`), kept on the networked var *and* `SetName()`,
  with no fallback to the NPC class.
- **The player's own line appeared twice** in the chat window: the local append and
  the server echo both landed. Echoes are now matched against what this client
  sent.
- **Modal backgrounds were invisible** over Mantle's translucent windows — an
  alpha-252 `draw.RoundedBox` composited to nothing. Frame fills are opaque
  `surface.DrawRect` now.
- **The body list could be permanently small**: the catalogue was cached on first
  build and `util.IsValidModel` rejects addon models that are not mounted yet.
- Model parameters are re-learned per provider/model on a 400 (temperature,
  `max_tokens` vs `max_completion_tokens`, reasoning), with one automatic retry.

## [4.0.0] — Mantle interface

The C menu is now built on [Mantle](https://github.com/darkfated/mantle), a UI and
renderer library for Garry's Mod. Mantle is a separate Workshop addon, and Workshop
does not install dependencies, so the v3.1 Derma panel ships alongside it: the
addon uses Mantle when it is present and falls back to the old panel otherwise.
Nothing breaks for anyone who never installs it.

### New — the interface

- **Mantle panel** (`lua/autorun/client/cl_ainpcs_mantle_panel.lua`): frame, tabs,
  Library as a sortable table, the five-step Create wizard with a live 3D body
  preview and Mantle's modal model picker, and the full Settings form.
- **Library actions you can actually find.** Clicking a row selects it; the footer
  offers Spawn / Edit / Delete (right-click is the same menu). Delete arms on the
  first press and confirms on the second, because a footer button is easy to hit
  by accident. Previously clicking a row spawned immediately, so deleting a
  character meant spawning it first or knowing about a hidden right-click menu.
- **Routing** in `cl_2_ainpcs_open.lua`: one `AINPCS.Open()` for the concommand,
  the C-menu icon and the desktop icon. `AINPCS.OpenClassic()` is the v3.1 panel,
  unchanged apart from bug fixes.
- **`ainpc_ui`** (client, default `0` = auto): `1` forces the classic panel, `2`
  forces Mantle. **`ainpc_ui_sfx`** (default `1`) controls interface click sounds.
- Body picking uses NPC registry models, so the modal selector covers only classes
  whose registry entry carries a `Model`; a full class table covers the rest.

### Not in this release

The chat window, the 3D nametag/thinking bubble and the toasts still use their v3
rendering, and the radial action menu is not built yet. See `MANTLE_PLAN.md` for
the remaining phases.


### Fixed — the NPC treated your nickname as something you said

Player messages were sent as `"[salami nipples]: hi"`, so the nickname arrived
inside the utterance and models answered it literally ("did you just say salami
nipples?"). The name is now kept out of the message body entirely: it goes into the
system prompt as "you are talking to a player whose account name is …", with an
instruction not to repeat or react to it, and it is sanitised so a crafted
nickname cannot fake a second speaker.

### Fixed — voice search crashed with "attempt to call global 'readDataTable'"

The file helpers that replaced the HTTP voice list were declared after their first
user, so the local was out of scope and Lua resolved a nil global. Voice search in
the Create wizard threw on every step change.

### Fixed — the actual root cause: Garry's Mod blocks HTTP to loopback

`Requests to local resources are not allowed`. That is the engine refusing the
request before it leaves the process — not the relay, not Windows, not the host
name. Garry's Mod blocks client-side HTTP to private networks (`127.0.0.1`,
`localhost`, `10.`, `172.16.`, `192.168.`) unless the game is launched with
**`-allowlocalhttp`**. No amount of host spelling or port juggling was ever going
to fix it, and `/voices` and `/config` could never have worked.

Both control operations now travel as files in `garrysmod/data`, which needs no
network and no launch options:

| Operation | Before | Now |
|---|---|---|
| Voice list | `GET /voices` | the relay publishes `ainpc_relay_voices.json` (pinned voices first, then the library, refreshed every 10 min); the panel filters it locally |
| Save Fish key | `POST /config` | the panel writes `ainpc_relay_command.json`; the relay validates the key against Fish Audio and publishes the verdict in its heartbeat file, which the panel polls |

Detection was already file-based, so nothing about "is it running" depends on the
network now.

**Audio is unaffected.** `sound.PlayURL` is BASS, not the Lua HTTP shim, so it is
not subject to the private-network block — cloned voices still stream from the
relay. If you *do* add `-allowlocalhttp` to the launch options, the HTTP paths
become available again and are used as a fallback.

The status pill gained a matching state: **"ready (file mode)"**, green, for the
normal default install where HTTP is refused but everything else works.
`ainpc_http_test` tries the candidate URL spellings and reports which the engine
accepts, so this is one command away from being proved again on any machine.

### Changed — the relay now says it is alive with a file, not a request

Asking the game to prove the relay is up over HTTP was the wrong shape of
question: on Windows an `HttpListener` is served by HTTP.sys (which 400s any
spelling of the address other than the one it registered), and a local firewall can
block the loopback round trip entirely, so "not running" was reported for a service
that was healthy.

Both relays now publish `garrysmod/data/ainpc_relay_status.json` and refresh it
every two seconds while idle:

```json
{"ok":true,"engine":"powershell","url":"http://localhost:7171","port":7171,
 "key_set":true,"presets":10,"tts_model":"s2.1-pro-free","credits":0,
 "heartbeat":1794534308}
```

The client reads it with `file.Read` — no network, no host-name guessing — treats a
heartbeat older than 20 seconds as "not running", and adopts the published `url`
for `/voices`, `/tts` and `/config`. The relay removes the file when its window
closes.

A single `HTTP` probe still runs alongside it, because `/voices` and `/tts` need
working HTTP. When the file says the relay is up but the probe fails, the panel now
says **"up, but unreachable from the game"** instead of "not running" — that is a
firewall problem, and restarting the relay will never fix it.

`ainpc_voice_diag` prints the status file's age and published URL alongside the HTTP
results.

### Fixed — the Python relay ignored the PowerShell relay's config

`relay.ps1` writes `config.json` with a UTF-8 BOM; `server.py` read it as plain
`utf-8`, rejected it, and reported `key_set: false` on a key that was configured.
It reads with `utf-8-sig` now.

### Fixed — "voice service: NOT running" while the service is running

The relay (`relay/relay.ps1`) creates a .NET `HttpListener`, which on Windows is
served by HTTP.sys. HTTP.sys matches listener prefixes against the request's
**Host header**, and the relay only registered `http://localhost:7171/`. The addon
requested `http://127.0.0.1:7171/health`, so Windows itself answered
`400 Bad Request — Invalid Hostname` before PowerShell ever saw the request. That
HTML error page parsed as nil, and the panel reported the service as down.

Because the same base URL is used for `/voices`, `/tts` and `/config`, this broke
voice search, playback and saving the Fish key too — not just the status line.

- The client default is now `http://localhost:7171` (works for both the PowerShell
  and Python relays).
- `relay.ps1` additionally registers `127.0.0.1` and `[::1]` prefixes when Windows
  permits it, falling back to the `localhost` prefix alone. An elevated `urlacl`
  is needed to bind a raw IP, so the fallback is the normal case.
- `AINPCS.RelayHealth` now passes the HTTP status through, and both panels
  distinguish "nothing is listening" from "something answered but it is not the
  relay", naming the wrong-host case explicitly.
- The health probe tries the configured host and the other spelling of the same
  loopback host, then remembers which one answered. A stale archived
  `ainpc_voice_relay_url` pointing at `127.0.0.1` therefore repairs itself.
- New console command `ainpc_voice_diag` prints the configured and effective base
  plus the real result for each candidate host (HTTP status, byte count, whether
  the body is JSON, and the transport error when nothing answered).
- Cloned voices in `relay:` now fall back to the client's own relay address when
  the server's `ainpc_voice_relay` convar is empty, which previously left
  `V.relay` blank and made every character voice unplayable on a local relay.

### Fixed — typed text disappearing from the character fields

`DTextEntry.OnValueChange` only fires on Enter or on focus loss, and nothing in
the addon ever called `SetUpdateOnType(true)`. A click on a button does not
reliably move keyboard focus, so typing a name and going straight to Next could
leave the draft empty: the step then rebuilt from that empty draft (the field
looked wiped) and saving fell back to an unnamed "NPC".

Every text field — name, description, voice search, provider key, Ollama
hostname — now commits while you type. The settings file is written on a short
debounce instead of once per keystroke.

## [3.0.0] — UI rebuild

The old panel was one screen with every control on it: provider, model, tokens,
temperature, reasoning, key, voice, voice search, body, description, spawn. Nobody
could tell what they were supposed to do first, and voice lists mixed keyless
Google voices with Fish Audio character voices in the same dropdown.

### New structure: three pages

**Library** — every NPC you saved, with name, voice, body and reply speed, plus
Spawn / Edit / delete. Stored in `data/ai_npcs_library.json`.

**Create** — a guided 4-step maker with a step bar and Back/Next:
1. *Identity* — name; description optional (a known character name is enough)
2. *Voice* — search your voice service, click a result, preview it
3. *Body* — pick the model, with a 3D preview
4. *Behaviour* — reply speed (instant / a little thinking / balanced) and "speak out loud"
5. *Review* — summary, then Save to library or Save & spawn

**Settings** — the technical stuff, touched once: provider, model (free-only
toggle), API key, Ollama hostname, Fish Audio key + service status, fallback
voice, volume. The NPC maker never asks about tokens, temperature or model ids.

### Changed
- Voice lists are no longer mixed: the maker only offers character voices from the
  voice service; keyless Google/SAPI4 voices became the "fallback voice" in
  Settings, used when an NPC has no character voice or the service is down.
- Saved NPCs are reusable, so the same character no longer has to be rebuilt.
- Rewritten on `DListLayout`/`DPropertySheet`, which also removes the class of
  "docked panel with no height" bugs behind the earlier collapsed-sections report.
- Client code split: `cl_0_ainpcs_shared.lua` (settings, library, voice service,
  model cache, spawn) and `cl_ainpcs_panel.lua` (UI only).

## [2.5.0]

### Added
- **Reasoning can be switched off.** Reasoning models now offer "Off - fastest
  reply" in the effort dropdown and it becomes the default, so the NPC starts
  answering immediately instead of thinking first. Per provider:
  OpenRouter sends `reasoning.effort: "none"` (a real value there), OpenAI is
  mapped to `minimal` (the fastest it allows), Groq is mapped to `low` with hidden
  thinking.
- **Thinking bubble** above the NPC: a rounded "thinking ● ● ●" panel with an
  animated dot cycle, readable at distance (replaces three floating dots).
- `ainpc_probe_localaudio` console command: synthesises a test tone in Lua, writes
  it to `data/`, and tries to play it back. This answers whether GMod can ever
  play audio it fetched itself — if it can, the voice service can eventually be
  dropped for Fish Audio too.

## [2.4.0]

### Added
- **Quick spawn**: type a character (`rick sanchez`) -> *Find voice + name*. It
  searches the Fish Audio library, sets that voice, names the NPC, and fills a
  one-line description. No biography required: the system prompt now tells the
  model to imitate a known character's speech from the name alone.
- **Voice service card in the panel**: shows running / key set / remaining credit,
  and lets you paste your Fish Audio key **inside the game** (it is POSTed to the
  local service, never stored in GMod's settings).
- **Body filter** for the NPC class dropdown (citizen, zombie, combine...).
- `relay/start.bat` + `relay/relay.ps1`: the voice service no longer needs Python.
  Double-click, done. Same API as `relay/server.py`.

### Fixed
- **No voice at all.** `IGModAudioChannel:IsPlaying` is missing in current GMod
  builds, so the voice Think hook threw every frame (thousands of errors) and no
  chunk ever advanced. Channel state now goes through a version-tolerant helper
  (`IsPlaying` -> `GetState` -> `GetTime`/`GetLength`).
- **Key validation accepted any string**: Fish's `/model` listing is
  unauthenticated. Both relays now validate against `/wallet/self/api-credit`,
  which 401s on a bad key, and report the remaining credit.
- Better model diagnostics (`models: N visible, selected X` / `nothing visible
  (order=N, filter=..., freeOnly=...)`) instead of a silent "no model selected".

## [2.3.1]

### Fixed
- **Every section of the spawn panel was collapsed to its title row.** The cards
  were `DPanel`s docked `TOP`, and a docked-TOP panel has no intrinsic height in
  GMod, so the provider/model/NPC/settings controls were clipped out of view.
  Cards now live on the scroll panel's canvas (`AddItem`) and are measured with
  `SizeToChildren` once populated, with a fallback that sums child heights.
- `populateModels` is now wrapped in `pcall` and reports failures as a toast +
  console line instead of silently leaving "no model selected".

## [2.3.0]

### Added
- **Paid models on OpenRouter.** The live catalog now includes paid models, not just
  `:free` ones, with per-million-token prices in the dropdown.
- **"Free models only" toggle** (default on) in the model section. Unticking it is
  the "I'm happy to pay" switch: it reveals the paid catalog and preselects the
  provider's `defaultModel`.
- `provider.defaultModel` — OpenRouter's is `deepseek/deepseek-v4.1-flash-1017`
  ($0.15/M in, $0.60/M out, 1M context), kept in the static model list too so it is
  selectable before the first live fetch.

## [2.2.0]

### Added
- **Voice relay** (`relay/server.py`, Python standard library only, no install
  step): a local service that turns the addon's text into audio through your own
  Fish Audio key. Endpoints: `/` setup page, `/health`, `/voices` (library listing,
  title search, single-id lookup, pinned first), `/tts` (WAV, disk-cached),
  `/config`, `/presets`.
- **Character voices**: anything in the Fish Audio library — Peter Griffin, Rick
  Sanchez, Metal Sonic, Genshin characters, TF2 cast — selectable per NPC.
- **In-game voice search**: type a name or paste a 32-hex model id in the spawn
  panel; results are registered as `relay:<id>` voices immediately. Pinned voices
  preload into the dropdown.
- `ainpc_voice_relay_url` client convar, so every player uses their own relay and
  their own key. The server convar is only a default now.
- `relay/` docs covering the API contract, key handling, and the planned cloned
  voice library (VPK sample extraction, XTTS/Piper/ElevenLabs tradeoffs).

### Changed
- Keys supplied through `FISH_API_KEY` are never written to `relay/config.json`;
  keys pasted into the setup page are stored `0600` where supported.
  `relay/config.json` and `relay/cache/` are gitignored.
- Only `/v1/tts` spends credits; listing and searching the library is free, and
  every rendered chunk is cached by `sha256(voice + text)`.

## [2.1.0]

### Fixed — audio (why NPCs were silent)
- **The default TTS engine was dead.** StreamElements' public endpoint returns
  `401` for real sentences. Playback now uses engines that answer today: Google
  TTS (13 languages, keyless), SAPI4 retro voices, and `relay:` for cloned voices.
- Voices are chosen by the server and broadcast, so everyone in a server hears the
  same NPC the same way, with no API keys involved in listening.
- Long lines are split at sentence/word boundaries into ~180-char chunks and played
  back to back, instead of being truncated mid-sentence.
- Audio is 3D, re-positioned every frame (it follows a walking NPC), with fade
  distance, `ainpc_voice_volume`, stop-on-death, and protection against recycled
  entity indices inheriting an old voice.
- A stalled `PlayURL` can no longer freeze an NPC's speech queue.

### Fixed — free tier
- OpenRouter's live free-model list never applied: `util.JSONToTable` caps at
  15,000 keys and the `/v1/models` payload is ~29,000. Parsed with `ignoreLimits`.
- All eight hardcoded OpenRouter fallback models had been delisted by the provider;
  the list is regenerated from the live catalog and filtered to text-output models.
- The OpenRouter provider is loaded at boot — its `Initialize` hook lived in a
  lazily-included file and never fired, so the daily refresh never ran.
- Clients can request the model list when the panel opens.

### Fixed — interaction
- Replies went to the NPC's owner rather than whoever asked; now asker + owner.
- `/say` bypassed the chat cooldown; the cooldown covers every input path.
- Requests now time out: state clears, the unanswered turn is rolled out of
  history, and the player is told, instead of "thinking…" forever.
- Late callbacks from superseded requests can't deliver stale replies.
- API keys are scrubbed from provider error text before it reaches chat.
- An empty model id falls back to the provider's first model instead of a 400.
- `AINPC_ModelPreview` is rate-limited (previously an entity create/remove vector).

### Changed — UI
- Spawn button moved to a fixed footer. It lived inside a scroll panel, which is
  why users reported "there is no Spawn NPC button".
- Status line showing provider • model • voice, red with "API key required".
- Model filter box; per-NPC voice picker with a test button.
- Subtitle bubble above an NPC while its voice plays.

## [2.0.0]

- Provider rewrite: Groq, OpenRouter, OpenAI, DeepSeek, Ollama; free-tier key
  onboarding; press-E chat; nametag with thinking indicator; multiplayer safety
  (admin gate, per-player cap, cooldowns, key redaction).
