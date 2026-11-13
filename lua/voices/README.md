# Voice relay (character + cloned voices)

GMod can only play audio from a **URL**, and it must never hold an API key. So
anything that needs a key or a model lives in one small local service that **each
player runs themselves**, with **their own** Fish Audio key:

```
ainpc_voice_relay_url "http://127.0.0.1:7171"
```

A working implementation ships in [`relay/server.py`](../../relay/server.py)
(Python 3 standard library only, no install step).

Once that convar is set, the config panel grows a `relay:<name>` voice for every
voice the relay advertises, and the audio still comes out of the NPC's mouth like
any built-in voice.

## Contract

The addon talks to three endpoints. Keep responses small and fast; it is on the
hot path of a chat reply.

| Method | Path | Response |
|---|---|---|
| `GET` | `/` | Setup page: paste key, pin voices, browse library |
| `GET` | `/health` | `{"ok": true, "key_set": true, "presets": 10, ...}` |
| `GET` | `/voices` | `{"voices": [{"name": "<id>", "label": "Rick Sanchez"}]}` — pinned first |
| `GET` | `/voices?q=peter%20griffin` | server-side title search across the whole library |
| `GET` | `/voices?id=<model id>` | one model by id (for pasted ids) |
| `GET` | `/tts?voice=<id>&text=<text>` | raw `audio/wav`, one chunk, disk cached |
| `POST` | `/config` | `{"key": "sk-fish-..."}` — validated against the API |
| `POST` | `/presets` | `{"id": "<model id>"}` or `{"id": ..., "remove": true}` |

Rules that matter:

- **Return `audio/wav`.** GMod's `sound.PlayURL` is picky; wav is the safest
  container, mp3 is usually fine, ogg is not.
- **Answer in well under 2s** for a ~15 word line. Stream the file, don't wait for
  a batch job. The addon already chunks long lines to ~180 characters, and it
  treats three consecutive failures as "host is down" and stops trying.
- **No auth on the LAN.** Bind to `127.0.0.1` or the LAN interface. If you expose
  it to the internet, put a token in front of it and send it as a query param —
  the addon only does GETs with no headers.
- `voice` may be anything you like (`barney`, `kleiner`, `breen`). The addon does
  no validation beyond `^%w+$` before the colon.

## Fish Audio specifics (what the shipped relay does)

- **Listing and search cost nothing.** `GET /model?title=<q>` is a real server-side
  search across the whole library — the plain listing only exposes a 1000-model
  window, which is why filtering that window locally missed half the characters.
  Only `/v1/tts` spends credits, and every rendered chunk is cached on disk by
  `sha256(voice + text)`, so repeat lines are free.
- **The key never touches the addon.** `FISH_API_KEY` from the environment is not
  written to `config.json`; a key pasted into the setup page is, with `0600` where
  the OS supports it. `config.json` and `cache/` are gitignored.
- **Voices are just model ids.** Any 32-hex id from fish.audio works — pin it in the
  setup page, or paste it into the in-game "Search voices" box.

## Cloned voice library — the interesting part

The reason to clone is that GMod already ships the voices you want to hear. The
game's VPKs contain thousands of short, clean character lines:

```
garrysmod/garrysmod_dir.vpk  →  sound/vo/npc/barney/*.wav
                                sound/vo/npc/male01/*.wav
                                sound/vo/npc/vortigaunt/*.wav
                                sound/vo/Citizen/*.wav
```

Plan for the library:

1. **Extract** reference samples per character (10–30s of clean speech, no
   music/SFX, no overlapping lines) into `samples/<character>/`.
2. **Pick an engine** (this is the one real decision):
   - **XTTS-v2** — best zero-shot cloning that runs locally, ~6s of reference audio
     is enough, GPU strongly preferred, Apache-ish licence for the weights.
   - **Piper** — fastest by far (CPU, realtime), but each voice needs a training
     step, so it suits a fixed cast rather than arbitrary cloning.
   - **ElevenLabs** — best quality, instant cloning, costs money and requires
     uploading samples to a third party.
   - **OpenAI TTS** — excellent quality, **no cloning**, but worth having as the
     "high quality, no setup" fallback.
3. **Store** `voices/<character>.json` = `{ engine, model, reference: [...], label }`.
   `/tts` looks up the character, renders, and caches by
   `hash(voice, text)` on disk — repeated barks ("Get out of here!") then cost
   nothing.
4. **Normalise** output: 22050 Hz mono wav, light gain normalisation, trim silence
   at both ends. That makes every character sit at the same perceived volume.

Do not ship cloned Valve character voices in the Workshop upload. Point at the
local service, let each user build their own library from their own game files.

## What the addon already does

- `relay:<id>` voice ids registered from the relay, with in-panel search (title or
  pasted model id) and pinned voices listed first.
- `ainpc_voice_relay_url` client convar, so each player uses their own relay/key —
  the server only supplies a default.
- `ainpc_voice_relay` convar, replicated to clients via a global string so the
  "Test voice" button hits the same host.
- Per-NPC voice selection at spawn time, broadcast to every client so all players
  hear the same thing.
- Chunked playback with 3D positioning, fade distance, and follow-the-NPC
  re-positioning every frame.
