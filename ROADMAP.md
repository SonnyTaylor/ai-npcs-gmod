# AI NPCs — Roadmap

Driven by the Steam Workshop comment wall. Two themes dominate it:

1. *"Is it even working?"* — silent failures, no feedback, dead model lists
2. *"Where's the voice / can it sound like Barney?"* — no positional audio, one
   robotic voice, no cloning

Free-tier convenience is **not** a priority. AI isn't free, pretending otherwise
just produces a broken default. Providers stay configurable; the free path keeps
working where it genuinely does.

---

## v4.0 — the interface (this update)

The C menu becomes a real app instead of one scroll of controls. Spec and phase
plan: [`MANTLE_PLAN.md`](MANTLE_PLAN.md).

- [x] **Mantle as an optional backend.** Mantle is a separate Workshop addon and
      Workshop does not install dependencies, so the v3.1 Derma panel stays as a
      frozen fallback instead of becoming a hard requirement. Routed by
      `AINPCS.UI.useMantle()` and overridable with `ainpc_ui 1|2`.
- [x] **Library** as a sortable table with right-click Spawn / Edit / Delete.
- [x] **Create** as a five-step wizard: identity, voice search, body, behaviour,
      review, with a live 3D preview and Mantle's modal model picker.
- [x] **Settings** rebuilt from Mantle controls, including the voice-service
      status pill and a themed volume slider bound to `ainpc_voice_volume`.
- [x] **Bug fixes found by using it**: the relay host mismatch (HTTP.sys rejects
      `127.0.0.1` for a `localhost` listener), values not committing while typing,
      and cloned voices being unplayable when the server relay convar is unset.
- [ ] Chat window on `MantleFrame` + `MantleScrollPanel` with bubble styling.
- [ ] Nametag, thinking bubble and toasts moved to RNDX.
- [ ] Radial action menu on hold-E (`Mantle.ui.radial_menu`): talk, repeat last,
      change voice, despawn. Needs two new server net messages.
- [ ] Retire the classic panel once 4.0 has been on the Workshop for a while.

## v2.1 — "it actually works" (this update)

### Audio that exists, is positional, and follows the NPC
- [x] **The default voice engine was dead.** StreamElements' public endpoint now
      returns `401` for real sentences, so every NPC was silent. Voice registry
      moved to engines that answer today (Google TTS, SAPI4) plus `relay:` for
      cloned voices.
- [x] **Server picks the voice, clients play it** — everyone in the server hears
      the same NPC the same way, no keys involved in playback.
- [x] **Chunked playback.** Lines are split at sentence/word boundaries into
      ~180-char chunks (engine limits) and played back to back, instead of being
      silently truncated at 400 characters.
- [x] **3D audio glued to the NPC**: `SetPos` every frame, fade distance, volume
      convar (`ainpc_voice_volume`), stop on death/removal, interrupted by a new
      line, and recycled entity indices can't inherit an old voice.
- [x] **16 voices** across 13 languages (the German request is already covered),
      plus `relay:<name>` for cloned voices.
- [x] "Test voice" button in the panel; playback failures now surface as a toast
      instead of the addon looking broken.
- [x] Subtitle bubble on the NPC while its voice plays.

### UI
- [x] **Fixed footer with the Spawn button** — it used to live inside a scroll
      panel, which is why people reported "there is no Spawn NPC button".
- [x] **Status line** that always states provider • model • voice, and turns red
      with "API key required" when it is.
- [x] **Model filter box** (provider lists are 20–40 entries now).
- [x] Voice picker per NPC, with a live test button.

### Never fail silently
- [x] **Request timeout.** `Defaults.RequestTimeout` was dead code; a hung call
      left the NPC on "thinking…" forever. Now a timer clears state, rolls the
      unanswered turn out of history, and reports the timeout.
- [x] Late callbacks from timed-out requests can't deliver stale replies.
- [x] API keys are scrubbed out of provider error text before it reaches chat.
- [x] Empty model id falls back to the provider's first model instead of a 400.

### Interaction correctness
- [x] **Replies went to the NPC's owner, not the asker.** Another player's
      conversation got no answer while the owner got replies to a chat they never
      had. Replies now go to asker + owner.
- [x] **`/say` bypassed the chat cooldown**, burning quota and earning 429s.
- [x] Concurrent questions to one NPC are rejected instead of interleaving history.
- [x] `AINPC_ModelPreview` is rate-limited (was an entity create/remove vector).

### Free-tier reliability (kept, not chased)
- [x] OpenRouter live fetch parsed with `ignoreLimits` — the 15,000-key JSON cap
      silently rejected the ~29,000-key `/v1/models` payload, so the refresh never
      applied.
- [x] Fallback model list regenerated from the live catalog; **all 8 previous
      fallback ids were delisted**, which is why OpenRouter users got errors.
      Non-text (audio) models are filtered out.
- [x] Provider loads at boot: `hook.Add("Initialize")` inside a lazily-included
      provider file never fired, so the 24h refresh never started.
- [x] Client can request the model list when the panel opens.

---

## v2.2 — voice: the relay and a cloned cast

Spec: [`lua/voices/README.md`](lua/voices/README.md) (already implements the
GMod side: `relay:` voices, `ainpc_voice_relay`, per-NPC voice, chunked playback).

- [x] **Relay service** (`relay/server.py`, stdlib only): `/health`, `/voices`
      (search + id lookup), `/tts`, `/config`, `/presets`, disk cache keyed by
      `hash(voice, text)`.
- [x] **Character voices from the Fish Audio library**, with in-panel search and
      pinned voices; each player supplies their own key via `ainpc_voice_relay_url`.
- [x] **Key hygiene**: env-supplied keys are never written to disk, `config.json`
      and `cache/` are gitignored, the key never enters GMod.
- [ ] **Engine decision** — XTTS-v2 (local zero-shot cloning) vs Piper (fast, per
      voice training) vs ElevenLabs (best, paid, third-party). One decision, then
      the service is small.
- [ ] **Retro engines**: DECtalk / SAM / espeak-ng behind the relay (stubs detect
      the binaries today; DECtalk wiring still to do).
- [ ] **Sample extraction tool** for a cloned cast: pull `sound/vo/npc/*` out of
      `garrysmod_dir.vpk` / HL2 VPKs, pick clean 10–30s references per character,
      normalise to 22050 mono wav.
- [ ] **Voice library UI**: list relay voices with labels, per-NPC assignment,
      "clone from sample folder" flow that doesn't require leaving the game.
- [ ] Per-NPC pitch/rate and mouth movement (`SetFlexWeight`) while speaking.
- [ ] Instant replay/regenerate of the last line with the same voice (cheap, from
      the relay's cache).

## v2.3 — mic input

Users ask for it; be honest about the difficulty. GMod has no audio capture API.

- [ ] Spike: push-to-talk record → relay → STT (whisper.cpp local, or hosted) →
      the transcript opens in the chat window for confirmation/editing.
- [ ] Ship it only if the spike lands under ~2s round trip. Otherwise document why.

## v2.4 — UI polish

- [ ] Proper chat window: avatar, thinking animation, streaming tokens, message
      timestamps, `/` command hints.
- [ ] Spawn presets ("Barney the bartender", "paranoid scientist") that fill name,
      description and voice in one click.
- [ ] Character/model preview that animates and speaks the chosen voice.
- [ ] Colour-coded chat per NPC so multi-NPC scenes stay readable.

## v2.5 — actions, not just words

Requires tool calling; Groq/OpenRouter free models already advertise support, and
`provider.tool_support` is tracked but unused.

- [ ] Tools: `follow_player`, `stop`, `attack_target`, `walk_to`, `give_item`,
      `play_sound`. Validated server-side, gated on `ainpc_allow_actions`.
- [ ] Action budget per NPC per minute; no entity-removal class tools.

## v2.6 — i18n

- [ ] `lua/lang/*.lua` for UI strings (de, ru, es, fr, pt-br, zh), auto-detected
      from `gmod_language`.
- [ ] Tell the model to answer in the player's language (TTS already has the
      languages; the reply text is what's missing).

## v2.7 — server-operator quality

- [ ] Keys stay client-side: optional proxy mode so players never hand their key to
      a stranger's server (today the server sees every key, and it is stored in
      plaintext in `data/ai_npcs_settings.json`).
- [ ] Per-player token budget + usage readout.
- [ ] Persist personalities as named presets.
- [ ] "Test key" button with real diagnostics (401/402/403/429 → plain English).

---

## Engineering hygiene

- [ ] `luacheck` + CI on push. (Right now every file is only `loadfile`-checked.)
- [ ] `CHANGELOG.md` per Workshop update.
- [ ] Scripted Workshop upload (`gmad` + `gmpublish`).
- [ ] Close stale issue #6 (fixed by #7; `drawaihud` no longer exists).
- [ ] Delete stale branch `Reverse-Proxy` (dead `api.pawan.krd` proxy).
