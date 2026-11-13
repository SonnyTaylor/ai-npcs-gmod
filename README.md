# Garry's Mod AI NPCs

Spawn NPCs in Garry's Mod that you can actually talk to. Supports multiple AI providers including genuinely free options — Groq, OpenRouter free models, OpenAI, DeepSeek, and self-hosted Ollama.

![](https://img.shields.io/steam/subscriptions/3142705974?label=Steam%20Subscriptions&style=for-the-badge&logo=steam)

## What's new in v2.1

- **Voices actually work now.** The old default TTS provider (StreamElements) started returning `401`, so every NPC was silent. Voice playback is now built on engines that answer today, with 16 voices across 13 languages.
- **Voice comes out of the NPC** and follows them as they walk, with fade distance and a volume convar. Long lines are split into chunks and played back to back instead of being cut off mid-sentence.
- **A voice per NPC** — Barney gets a gruff English voice, the scientist gets another one. Optional cloned voices via a local relay (see `lua/voices/README.md`).
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

## Quickstart

1. Subscribe to the addon on the [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3142705974).
2. Launch Garry's Mod in a sandbox game.
3. Press **C** to open the context menu.
4. Click the **AI NPCs** icon on the right-hand side of the C menu.
5. On first launch, you'll get a welcome popup — click the **"Get free Groq key"** button, create an account (no credit card required), copy your key back into the panel, and hit Spawn NPC.
6. Walk up to the NPC and press **E** to open a chat window.

## Providers at a glance

| Provider | Free? | Region blocks | Get a key |
|---|---|---|---|
| **Groq** | Yes — daily rate limit on free tier, no credit card required | None known | https://console.groq.com/keys |
| **OpenRouter** | Many `:free` models available, ~50 req/day without credits, ~1000/day with a one-time $10 top-up | None known | https://openrouter.ai/keys |
| **OpenAI** | Paid only (~$5 minimum top-up) | Russia, China, Iran, others | https://platform.openai.com/api-keys |
| **DeepSeek** | Paid only (very cheap, ~$0.14/M tokens) | None known | https://platform.deepseek.com/api_keys |
| **Ollama** | Completely free (runs on your own computer) | N/A — self-hosted | https://ollama.com/download |

**TL;DR for free use**: pick Groq. For more model variety, pick OpenRouter. For total privacy, pick Ollama and point it at your own machine.

## How to use

1. Open C menu → AI NPCs.
2. Pick a provider from the dropdown (Groq is the default).
3. Click the **Get free key →** button to open the right signup page.
4. Paste your key into the **API Key** field.
5. Fill in **Character description** — e.g. "A grumpy Russian bartender who hates everyone but has a soft spot for cats".
6. Optionally give the NPC a name.
7. Pick the NPC class you want them to look like (citizen, combine, zombie, whatever).
8. Click **Spawn NPC**.
9. Walk up to the NPC and press **E**, or just type in regular chat when you're within ~250 units. You can also use `/say <message>` from anywhere.

## Voices

Pick a voice per NPC in the spawn panel. The server decides which voice speaks, every client plays it, so an NPC sounds identical to everyone in the server.

| Engine | What you get |
|---|---|
| `google:<lang>` | Keyless, 13 languages (en, de, ru, fr, es, it, pt, pl, nl, sv, da, tr, ja) |
| `sapi4:<voice>` | Retro Microsoft Sam / Mike / Mary |
| `relay:<id>` | The whole Fish Audio character library (Peter Griffin, Rick Sanchez, Metal Sonic, Hatsune Miku, TF2 Soldier, …) plus optional retro engines |

### Cloned / character voices (your own key)

Character voices need a voice model service, and those cost money — so **you supply your own key**. It is never bundled with the addon and never sent to a server you're playing on.

1. Get a [Fish Audio](https://fish.audio) API key.
2. Run the relay that ships in `relay/`:
   ```
   python relay/server.py
   ```
3. Open <http://127.0.0.1:7171>, paste your key, and pin the voices you want.
4. In game, use **Voice → Search voices**: type `peter griffin`, or paste a model id, and pick a result. Pinned voices are already in the dropdown.

`ainpc_voice_relay_url` (client) points at your relay; it defaults to `http://127.0.0.1:7171`. Searching and listing voices is free — only generating audio spends credits. Each chunk of a line is cached on disk, so a repeated bark costs nothing the second time.

`ainpc_voice_volume` (client) controls playback volume. "Test voice" in the panel previews the selected voice.

## Server admin convars

All of these are `FCVAR_ARCHIVE` so they persist across restarts.

| Convar | Default | Description |
|---|---|---|
| `ainpc_enabled` | 1 | Master kill switch |
| `ainpc_admin_only` | 0 | If 1, only admins can spawn AI NPCs |
| `ainpc_max_per_player` | 3 | Max concurrent AI NPCs per player |
| `ainpc_cooldown_seconds` | 5 | Cooldown between spawns per player |
| `ainpc_chat_cooldown_seconds` | 1.5 | Cooldown between chat requests per player |
| `ainpc_proximity_chat` | 1 | If 1, chat in range auto-routes to the nearest NPC |
| `ainpc_proximity_range` | 250 | Distance for proximity chat routing |
| `ainpc_interact_range` | 140 | Distance for press-E-to-talk |
| `ainpc_tts_allowed` | 1 | Allow clients to enable TTS |
| `ainpc_openrouter_autorefresh` | 1 | Auto-fetch OpenRouter free models daily |
| `ainpc_voice_relay` | `` (empty) | Server default for the voice relay (players can override with their own `ainpc_voice_relay_url`) |
| `ainpc_voice_volume` | 1 | Client-side voice volume (0–1) |

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

## Contributing

PRs welcome. If you find a bug, file an issue at [github.com/SonnyTaylor/AI-NPCs-GMod](https://github.com/SonnyTaylor/AI-NPCs-GMod/issues) with the exact error message (including stack trace if there is one).

## License

MIT.
