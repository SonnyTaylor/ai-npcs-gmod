# Voice relay (cloned voices)

GMod can only play audio from a **URL**, and it must never hold an API key. So
anything that needs a key or a model — ElevenLabs cloning, OpenAI TTS, XTTS,
Piper — lives in one small local service, and the addon just points at it:

```
ainpc_voice_relay "http://127.0.0.1:7171"
```

Once that convar is set, the config panel grows a `relay:<name>` voice for every
voice the relay advertises, and the audio still comes out of the NPC's mouth like
any built-in voice.

## Contract

The addon talks to three endpoints. Keep responses small and fast; it is on the
hot path of a chat reply.

| Method | Path | Response |
|---|---|---|
| `GET` | `/health` | `{"ok": true, "engine": "xtts-v2"}` |
| `GET` | `/voices` | `{"voices": [{"name": "barney", "label": "Barney — HL2"}]}` |
| `GET` | `/tts?voice=<name>&text=<text>` | raw audio, one chunk, `audio/wav` |
| `POST` | `/clone` | `{"name": ..., "label": ..., "samples": ["<path or b64>"]}` → `{"ok": true}` |

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

- `relay:<name>` voice ids, ordered after the built-in ones in the panel.
- `ainpc_voice_relay` convar, replicated to clients via a global string so the
  "Test voice" button hits the same host.
- Per-NPC voice selection at spawn time, broadcast to every client so all players
  hear the same thing.
- Chunked playback with 3D positioning, fade distance, and follow-the-NPC
  re-positioning every frame.
