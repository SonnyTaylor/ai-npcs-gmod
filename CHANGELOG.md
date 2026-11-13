# Changelog

All notable changes to AI NPCs. Format loosely follows Keep a Changelog; this
addon is shipped through the Steam Workshop, so versions match Workshop updates.

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
