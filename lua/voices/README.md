# Voices

Two kinds of voice, both driven from inside the game. There is **no helper
program, no `.bat` file, and nothing to install**.

| Kind | Example id | Cost | Where the audio comes from |
|---|---|---|---|
| Built-in, keyless | `google:en`, `sapi4:Sam` | free | a public TTS URL streamed by each client (`sound.PlayURL`) |
| Fish Audio character | `fish:<32-hex model id>` | your Fish Audio credit | synthesised and streamed by the server (`sound.PlayFile`) |

The `relay:<id>` spelling from v2.x still resolves — it is normalised to
`fish:<id>` on load, so saved characters keep working.

---

## Built-in voices

These need nothing: no account, no key, no network round trip on our side.

```
google:en  google:de  google:ru  google:fr  google:es  google:it  google:pt
google:pl  google:nl  google:sv  google:da  google:tr  google:ja
sapi4:Sam  sapi4:Mike  sapi4:Mary
```

Google caps a single request at roughly 200 characters, so long lines are split
into ~180-character chunks by `Voices.Split` and queued back to back.

---

## Fish Audio voices (cloned / character voices)

You need your own Fish Audio key (`sk-fish-…`). Paste it once in **AI NPCs →
Settings → Fish Audio**. It is stored in `garrysmod/data/ai_npcs_settings.json`,
never written anywhere else, and it is the *server* or *client* that calls Fish
depending on what is being rendered:

| What | Who calls Fish | Why |
|---|---|---|
| voice search / library browsing | each client | the list is public and unauthenticated |
| credit balance + key validation | each client | instant feedback in the panel |
| a line an NPC speaks | the server, once | every nearby player then hears the same voice, and no player needs a key |

### How a spoken line reaches players

```
server: POST https://api.fish.audio/v1/tts  (Bearer <host's key>)
        -> mp3 bytes
        -> chunked net message  AINPC_TTSAudio   (28 KB pieces)
client: file.Write("ainpc_tts/stream_<id>.mp3")
        -> sound.PlayFile("data/ainpc_tts/...", "3d mono")
        -> positioned at the NPC's head, jaw driven by the channel's level
```

Rendered lines are cached in memory by `voice|text`, so a repeated bark costs
nothing the second time.

### Browsing voices

**AI NPCs → Create → Voice → Browse voices…** opens one searchable list of the
whole Fish Audio library:

* sorted by **most used** by default (`sort_by=task_count`), not by a hardcoded
  pin list;
* **duplicates collapsed** — `Rick Sanchez`, `Rick Sanchez (Text To Speech)` and
  `rick sanchez tts` are one row, keeping the most-used upload;
* every row with a pre-rendered sample has a **▶ Play** button that streams
  Fish's own sample — free, no credit spent;
* rows without a sample get **▶ Test**, which synthesises a short line (costs a
  little credit);
* ★ pins a voice for quick access; pinned voices appear first on the first page;
* language filter, and Prev/Next paging (50 per page).

Pasting a raw 32-hex Fish model id into the search box resolves it directly.

---

## Adding more engines

To add a new keyless URL engine, append to `V.list` in `voices/voices.lua` and
add a branch to `V.BuildURL`. To add a keyed engine, synthesise in
`playTTS()` (server, `sv_gmodainpc.lua`) and stream it with
`sendStreamedAudio(entity, bytes, "mp3"|"wav")`, which is what the Fish Audio
path already does.

Rules that matter:

- **Return wav or mp3.** `sound.PlayFile` is picky; ogg is not reliable in 3D.
- **Answer fast.** Long lines are already chunked; a chunk that takes seconds to
  arrive is a chunk the player hears late.
- **Never put a key in a client-visible URL.** Anything a client streams should
  be a public endpoint, which is why built-in voices use keyless services and
  Fish Audio goes through the server.
