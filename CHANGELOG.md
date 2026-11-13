# Changelog

All notable changes to AI NPCs. Format loosely follows Keep a Changelog; this
addon is shipped through the Steam Workshop, so versions match Workshop updates.

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
