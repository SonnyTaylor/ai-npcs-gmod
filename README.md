# Garry's Mod AI NPCs

Spawn NPCs in Garry's Mod that you can actually talk to. Supports multiple AI providers including genuinely free options — Groq, OpenRouter free models, OpenAI, DeepSeek, and self-hosted Ollama.

![](https://img.shields.io/steam/subscriptions/3142705974?label=Steam%20Subscriptions&style=for-the-badge&logo=steam)

## What's new in v4.2

- **They remember you between sessions.** An NPC's memories, opinions and notes
  are keyed to a stable profile id (the saved character's id, not the entity), so
  they survive death, respawn, map changes and the duplicator. Files live in
  `garrysmod/data/ai_npc/profiles/`.
- **Tell them who you are.** New "How AI NPCs see you" box in Settings — your name
  and a line about yourself, given to every AI NPC on the server.
- **Your API key never leaves your PC.** When you join someone else's server, your
  game makes the model call and only the finished line is sent back. Hosting
  (singleplayer or listen server) still does it server-side, where the key never
  travels anyway.
- **Cost control.** `ainpc_max_rpm` / `ainpc_global_rpm` cap requests per minute
  per NPC and for the server, `ainpc_status` shows estimated token use, and a
  rejected key pauses autonomous calls for two minutes instead of retrying forever.
- **No more reading JSON aloud.** A reply that fails to parse as JSON is now
  stripped of its scaffolding instead of being spoken verbatim.
- **Navmesh warning** when you spawn on a map with no navmesh, instead of NPCs
  silently failing to walk.

## What's new in v4.1

- **A guided setup.** The first time you open the panel without a key, a wizard
  walks you through it: pick a provider, it opens that provider's key page, you
  paste the key and it **checks the key with the provider before saving it**.
  Fish Audio is the optional second step. Run it again any time from
  Settings → *Run setup again* (or `ainpc_setup`).
- **No more relay program.** Character voices no longer need a Python or
  PowerShell helper and a `.bat` file. The addon talks to Fish Audio directly:
  searching and key checking happen in your game, and the server synthesises each
  spoken line and streams it to everyone nearby, so other players hear it without
  needing a key of their own.
- **The NPC knows what is happening.** It is told its own health, whether it is on
  fire, what it is doing, what it is holding, who is nearby (with distance,
  direction, health, whether they are aiming at it), what creatures are around,
  a timestamped log of recent events (being shot, kills, gunfire, deaths) and the
  recent conversation with speaker names.
- **It can act.** Follow, stay, come, wander, attack, stop attacking, flee, switch
  weapon, drop weapon, open doors and gesture — the model asks for them in its
  reply and the NPC does them.
- **Mouth and face move with the voice**, using the same flexes as
  `GM:MouthMoveAnimation`, and the emotion the model picks drives the face.
- **Text appears when the voice starts** rather than racing ahead of it.
- **One body browser** (NPC bodies *and* playermodels, searchable, paged, 3D
  preview) and **one voice browser** (searches all of Fish Audio, sorted by most
  used, duplicates collapsed, free ▶ sample on every row, ★ pins).
- **Chat window keeps history** per NPC and gained Follow / Stay / Calm / Clear /
  Edit buttons, plus an in-game character editor.
- Fixed: NPCs were named after their spawn class instead of your chosen name; your
  own chat line showed twice; modal backgrounds were invisible over Mantle windows.

## What's new in v4.0

- **A new interface, built on Mantle.** The C menu is now a proper app: a sortable
  library, a guided five-step character maker with a live 3D body preview, and a
  settings page that is not a wall of controls. [Mantle](https://github.com/darkfated/mantle)
  is a separate addon — if you do not install it, you keep the old panel. See
  [Interface](#interface).
- **Fixed: "voice service: NOT running" while the service was running.** The relay
  answers `localhost` but Windows rejects `127.0.0.1` for it with `400 Invalid
  Hostname`, and the addon asked for the latter. Voice search, playback and key
  saving were all affected. The addon and the relay now accept either spelling,
  and the health check remembers which one works.
- **Fixed: typed text vanishing from the fields.** Values used to commit only on
  Enter or focus loss, so a name typed and then followed by a click could be
  dropped and the field rebuilt empty. Everything commits as you type now.
- **`ainpc_voice_diag`** prints exactly what the addon sees when it asks the voice
  service for its status.

## What's new in v2.1

- **Voices actually work now.** The old default TTS provider (StreamElements) started returning `401`, so every NPC was silent. Voice playback is now built on engines that answer today, with 16 voices across 13 languages.
- **Voice comes out of the NPC** and follows them as they walk, with fade distance and a volume convar. Long lines are split into chunks and played back to back instead of being cut off mid-sentence.
- **A voice per NPC** — Barney gets a gruff English voice, the scientist gets another one. Optional cloned voices via Fish Audio (see [Voices](#voices)).
- **Subtitle bubble** above the NPC while it speaks.
- **The Spawn button can't be scrolled away any more** — it lives in a fixed footer next to a status line that tells you exactly what will be sent (provider • model • voice), red when your key is missing.
- **Model filter box**, because provider model lists are long.
- Fixed: replies went to the NPC's owner instead of whoever asked; `/say` ignored the chat cooldown; a hung request left the NPC stuck on "thinking…" forever; OpenRouter's live free-model list never applied (the JSON exceeded GMod's default parse limit) and every hardcoded fallback model had been delisted.

## What's new in v2.0

- Free tier actually works — no more dead hardcoded API key. First launch walks you through getting a free key from Groq or OpenRouter in about 30 seconds.
- **Press E to talk** to an NPC instead of typing `/say` every time. You can also just speak in chat when you're near an NPC and it'll respond automatically.
- 3D nametag above every AI NPC with a live "thinking…" indicator while it waits for a reply.
- Live OpenRouter free-model list — the addon fetches the current free models daily so you don't have to update it when the free lineup rotates.
- Proper multiplayer safety: admin gate, per-player NPC cap, spawn/chat cooldowns, and API keys never appear in chat errors.
- Fixed the crashes people were hitting (`pairs(nil)`, `attempt to index nil`, silent `/say` failures).
- Rewritten Ollama support that actually honours `max_tokens` and `temperature`.
- Added DeepSeek provider.

## Interface

The C menu has two implementations behind the same three pages — Library, Create,
Settings:

| | |
|---|---|
| **Mantle** (preferred) | Acrylic frame, real tabs, sortable tables, Mantle's modal model picker with a drag-to-rotate preview. Requires the free [Mantle](https://steamcommunity.com/sharedfiles/filedetails/?id=3126986993) addon ([source](https://github.com/darkfated/mantle)) plus its [Montserrat font](https://steamcommunity.com/sharedfiles/filedetails/?id=2924839375). |
| **Classic** | The v3.1 Derma panel. Always available, no dependencies, frozen apart from bug fixes. |

The addon uses Mantle when it is installed and falls back to the classic panel
otherwise — Workshop does not install dependencies, so nothing breaks if you never
install it. Both can be forced:

```
ainpc_ui 0        // auto: Mantle when installed (default)
ainpc_ui 1        // classic Derma panel
ainpc_ui 2        // Mantle, if present
ainpc_ui_sfx 0    // silence interface click sounds
```

The chat window, the nametag/thinking bubble above an NPC and the toast messages
are still drawn the v3 way and will move to Mantle in a later update.

## Quickstart

1. Subscribe to the addon on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3142705974).
2. Launch Garry's Mod in a sandbox game.
3. Press **C** → **AI NPCs** (right-hand side of the C menu).
4. The **setup wizard** opens the first time. Choose **Groq** (free, no credit
   card), press *Open key page*, make an account, paste the key back and press
   **Test & save** — it tells you immediately whether the key works.
5. Optional: connect **Fish Audio** in the next step for cloned character voices.
   Skip it and AI NPCs still speak with the free built-in voices.
6. Build a character (Library → *+ New character*), then **Spawn**.
7. Walk up and press **E**, or just type in chat when you are within ~350 units.
   `/say <message>` works from anywhere.

## Providers at a glance

| Provider | Free? | Region blocks | Get a key |
|---|---|---|---|
| **Groq** | Yes — daily rate limit on free tier, no credit card required | None known | https://console.groq.com/keys |
| **OpenRouter** | Many `:free` models available, ~50 req/day without credits, ~1000/day with a one-time $10 top-up. Tick "Free models only" off to see the paid catalog — the default for paying users is `deepseek/deepseek-v4.1-flash-1017` ($0.15/M in, $0.60/M out, 1M context) | None known | https://openrouter.ai/keys |
| **OpenAI** | Paid only (~$5 minimum top-up) | Russia, China, Iran, others | https://platform.openai.com/api-keys |
| **DeepSeek** | Paid only (very cheap, ~$0.14/M tokens) | None known | https://platform.deepseek.com/api_keys |
| **Ollama** | Completely free (runs on your own computer) | N/A — self-hosted | https://ollama.com/download |

**TL;DR for free use**: pick Groq. For more model variety, pick OpenRouter. For total privacy, pick Ollama and point it at your own machine.

## How to use

1. Open C menu → AI NPCs.
2. **Library → + New character** (or *Run setup again* in Settings to change keys).
3. Step 1 — **Identity**: name and an optional description ("A grumpy Russian
   bartender who hates everyone but has a soft spot for cats").
4. Step 2 — **Voice**: *Browse voices…* searches all of Fish Audio (every row with
   a free sample can be previewed instantly), or pick one of the free built-in
   voices.
5. Step 3 — **Body**: one browser for NPC classes and playermodels, with a live 3D
   preview.
6. Step 4 — **Behaviour**: reply speed, speak out loud, starting weapon.
7. Step 5 — **Review**, then Save / Save & spawn.
8. Walk up and press **E**, or type in chat nearby. `/say <message>` works anywhere.

Everything about a spawned NPC can be changed in game: press **E** → *Edit NPC*
(name, personality, voice, weapon), or use the Follow / Stay / Calm / Clear chat
buttons in the same window.

## Voices

Pick a voice per NPC. The server decides which voice speaks, so an NPC sounds
identical to everyone on the server.

| Engine | What you get | Cost |
|---|---|---|
| `google:<lang>` | Keyless Google TTS, 13 languages (en, de, ru, fr, es, it, pt, pl, nl, sv, da, tr, ja) | Free |
| `sapi4:<voice>` | Retro Microsoft Sam / Mike / Mary | Free |
| `fish:<id>` | The whole Fish Audio voice library (Rick Sanchez, Peter Griffin, GLaDOS, Metal Sonic, …) | Your Fish credit |

`relay:<id>` from older versions still resolves — it is normalised to `fish:<id>`,
so saved characters keep working.

### Character voices (Fish Audio)

1. Create a key at <https://fish.audio/app/api-keys/> (Fish charges credit per
   character spoken, so add a little credit).
2. In game: **Settings → Fish Audio → paste the key → Save** (or run the setup
   wizard, which does the same thing and verifies the key first).
3. **Create → Voice → Browse voices…**, search a character, press **▶ Play** to
   hear the free pre-rendered sample, then **Use**.

The voice browser is search-first:

- the default list is Fish Audio's **most used** voices, not a hardcoded pin list;
- **duplicate uploads collapse** — `Rick Sanchez`, `Rick Sanchez (Text To Speech)`
  and `rick sanchez tts` are one row, keeping the most-used one;
- every row with a sample has a **▶ Play** button that streams Fish's own sample —
  free, no credit spent. Rows without one get **▶ Test**, which synthesises a short
  line and costs a little;
- **★** pins a voice; pinned voices appear first on the first page;
- language filter, 50 per page, and pasting a raw 32-hex model id resolves it.

Your key is stored in `garrysmod/data/ai_npcs_settings.json` on your machine only,
and the model call is made on your machine too when you are playing on someone
else's server.
Search and key checks run in your game; **spoken lines are rendered by the server**
and streamed to nearby players, so nobody else needs a key to hear the NPC. Rendered
lines are cached per `voice|text`, so a repeated line is free the second time.

`ainpc_voice_volume` (client) controls playback volume.

## Server admin convars

All of these are `FCVAR_ARCHIVE` so they persist across restarts.

| Convar | Default | Description |
|---|---|---|
| `ainpc_enabled` | 1 | Master kill switch |
| `ainpc_admin_only` | 0 | If 1, only admins can spawn AI NPCs |
| `ainpc_max_per_player` | 5 | Max concurrent AI NPCs per player |
| `ainpc_cooldown_seconds` | 3 | Cooldown between spawns per player |
| `ainpc_chat_cooldown_seconds` | 1.2 | Cooldown between chat requests per player |
| `ainpc_proximity_chat` | 1 | If 1, chat in range auto-routes to the addressed/nearest NPC |
| `ainpc_proximity_range` | 350 | Distance for proximity chat routing |
| `ainpc_interact_range` | 160 | Distance for press-E-to-talk |
| `ainpc_tts_allowed` | 1 | Allow AI NPCs to speak out loud |
| `ainpc_allow_actions` | 1 | Allow NPCs to follow, stay, attack, flee, use doors, gesture, … |
| `ainpc_allow_pvp` | 1 | Allow NPCs to fight players when provoked or told to |
| `ainpc_reactive_events` | 1 | NPCs react in character when they are attacked |
| `ainpc_mute_hl2_voice` | 1 | Suppress stock HL2 voice lines on AI NPCs so they do not talk over the AI |
| `ainpc_openrouter_autorefresh` | 1 | Auto-fetch OpenRouter's free model list daily |
| `ainpc_max_rpm` | 20 | Max AI requests per minute per NPC (0 = unlimited) |
| `ainpc_global_rpm` | 60 | Max AI requests per minute for the whole server (0 = unlimited) |
| `ainpc_fish_key` | `` (empty) | Fish Audio key used by the **server** to render character voices. Players' own Fish keys are only used when they host |
| `ainpc_debug` | 0 | 1 = print prompts/replies to console, 2 = also print full request payloads |

### Client convars

| Convar | Default | Description |
|---|---|---|
| `ainpc_ui` | 0 | `0` auto (Mantle when installed), `1` classic panel, `2` Mantle |
| `ainpc_ui_sfx` | 1 | Interface click sounds |
| `ainpc_voice_volume` | 1 | Voice volume (0–1) |

Commands: `ainpc_open` (the panel), `ainpc_setup` (the guided setup),
`ainpc_status` (per-NPC state, request and token usage, navmesh — admin or console),
`ainpc_spawn <name>` (bring back a saved character), `ainpc_voice_diag` (what the
addon sees for Fish Audio), `ainpc_debug 1` (watch the prompts and replies).

## Manual installation

If you're not using the Workshop:

1. Clone this repo.
2. Rename the folder to `ai-npcs` (optional, but nicer).
3. Move it into your Garry's Mod `garrysmod/addons/` folder.
4. Restart Garry's Mod.

## Troubleshooting

**"No AI NPC nearby"** — You need to spawn one first. Press C → AI NPCs.

**"API key required"** — The free API button isn't a magic hardcoded key any more (the old one was long-dead and fake). You need to sign up for an actual free key. Click the big "Get free key" button in the panel.

**NPC says "... can't respond right now: HTTP error 401"** — Your API key is wrong or expired. Paste it again, or generate a new one from the provider's dashboard.

**NPC says "... can't respond right now: HTTP error 429"** — You're rate-limited. Wait a bit or top up credits.

**I'm in Russia / Iran / a region blocked by OpenAI** — Use Groq or OpenRouter instead. Neither is region-blocked in any country we know of.

**I want an uncensored NPC for RP** — Use OpenRouter and pick the Venice Uncensored model from the dropdown, or run Ollama locally with an uncensored model like `dolphin-mixtral`.

**Pressing E doesn't open the chat window** — Make sure you're within ~140 units of the NPC and that it has the golden nametag above its head (if not, it's a regular NPC, not an AI one).

**"Fish Audio: no key (built-in voices only)"** — that is fine, not an error. You
get the free Google/SAPI voices. Add a key in Settings (or run the setup wizard) for
cloned character voices.

**"Fish Audio: key rejected"** — Fish refused the key. Copy it again from
<https://fish.audio/app/api-keys/> and press Save; a key with no credit still shows
as valid, but speaking a line will fail.

**"A cloned voice is silent but `google:` voices work"** — character voices are
charged per character by Fish Audio. Zero credit means cloned lines fail while the
keyless ones keep working. `ainpc_voice_diag` prints the key state and the credit
balance the addon can see.

**"Voice search is empty"** — check the language filter and that you are online.
Searching Fish Audio is free and does not need a key; the list is capped at the
1000 models Fish exposes publicly, so keep search terms specific (`rick`, `barney`).

**"I want the new interface"** — subscribe to Mantle (`3126986993`) and its
Montserrat font (`2924839375`), then reopen the menu. Already subscribed and still
seeing the old panel? `ainpc_ui 2` will tell you whether the addon can see Mantle
at all. Nothing is broken either way: the classic panel is the fallback, not a
lesser mode.

**"`relay:` voices are silent but `google:` ones work"** — character voices are
charged per character by Fish Audio, and the relay reports `credits` in its own
window. Zero credit means every cloned line fails while the keyless Google/SAPI
voices keep working.

## Contributing

PRs welcome. If you find a bug, file an issue at [github.com/SonnyTaylor/AI-NPCs-GMod](https://github.com/SonnyTaylor/AI-NPCs-GMod/issues) with the exact error message (including stack trace if there is one).

## License

MIT.
