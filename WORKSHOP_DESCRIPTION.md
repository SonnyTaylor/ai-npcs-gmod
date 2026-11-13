# Steam Workshop Description — AI NPCs (v4.0)

Paste the block below into the Steam Workshop description field. It uses Steam's BBCode variants (`[h1]`, `[h2]`, `[h3]`, `[list]`, `[olist]`, `[b]`, `[i]`, `[url=...]`, `[hr]`).

Before you paste, upload a new screenshot/GIF showing the E-to-talk chat window and the glowing nametag above the NPC. The old screenshots are misleading.

---

[h1]AI NPCs — talk to NPCs in Garry's Mod, for free[/h1]

[h2]What's new in v4.0[/h2]
[list]
[*][b]A proper interface.[/b] The C menu is now a library of saved characters, a guided five-step maker with a live 3D body preview, and a settings page that is not a wall of controls. Built on [url=https://github.com/darkfated/mantle]Mantle[/url] — [b]optional[/b], subscribe to [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3126986993]Mantle[/url] and its [url=https://steamcommunity.com/sharedfiles/filedetails/?id=2924839375]Montserrat font[/url] to get it. Without them you get the old panel, which still works; nothing is a hard dependency.
[*][b]Fixed: "voice service: NOT running" when it is running.[/b] Windows rejected the address the addon was using, which silently broke voice search, playback and key saving too. Fixed, and there is now a console command that says exactly what the addon sees.
[*][b]Fixed: typed text disappearing.[/b] Names and descriptions commit as you type instead of only on Enter, so a field can no longer come back blank.
[/list]

Spawn an NPC with a custom personality and actually have a conversation with it. Supports multiple AI providers, including two with genuinely free tiers. The old hardcoded "free" API key was long-dead and never worked — v2.0 replaces it with a real onboarding flow that walks you through grabbing your own free key in about 30 seconds.

[h2]What v2.0 fixes[/h2]
[list]
[*][b]Free tier actually works.[/b] Click "Get free Groq key" in the panel, sign up with Google, paste your key back. No credit card required, no region blocks.
[*][b]Press E to talk[/b] instead of typing [i]/say[/i] every time. You can also just speak in chat when you're near an NPC and it'll respond automatically.
[*][b]Live 3D nametags[/b] above every AI NPC with a glowing "thinking…" indicator while it waits for a response.
[*][b]The crashes are gone[/b] ([i]attempt to index nil[/i], [i]pairs expected table got nil[/i], silent [i]/say[/i] failures). Every crash reported in the comments section has been fixed.
[*][b]Ollama, finally working properly.[/b] The old version silently ignored [i]max_tokens[/i] and [i]temperature[/i]. New version uses the OpenAI-compatible endpoint so all options work.
[*][b]Multiplayer-safe:[/b] admin gate, per-player NPC cap, spawn/chat cooldowns, and API keys never leak into chat errors.
[/list]

[h2]Supported providers[/h2]
[list]
[*][b]Groq[/b] — [i]free tier, no credit card, very fast, not region-blocked[/i]. Recommended for most people. [url=https://console.groq.com/keys]Get a key[/url]
[*][b]OpenRouter[/b] — [i]huge variety of free [code]:free[/code] models, including reasoning and uncensored ones[/i]. The addon auto-fetches the current free model list daily so you always have fresh options. [url=https://openrouter.ai/keys]Get a key[/url]
[*][b]OpenAI[/b] — GPT-5, GPT-4.1, GPT-4o, o4-mini. [i]Paid, blocked in several regions.[/i] [url=https://platform.openai.com/api-keys]Get a key[/url]
[*][b]DeepSeek[/b] — DeepSeek Chat V3 and Reasoner R1. [i]Cheap paid API.[/i] [url=https://platform.deepseek.com/api_keys]Get a key[/url]
[*][b]Ollama[/b] — [i]run entirely on your own computer, completely free and private[/i]. Great for RP because you pick the model and there's no rate limit. [url=https://ollama.com/download]Install Ollama[/url]
[/list]

[h2]How to use[/h2]
[olist]
[*]Subscribe to the addon.
[*]Launch Garry's Mod in a sandbox game.
[*]Press [b]C[/b] to open the context menu.
[*]Click the [b]AI NPCs[/b] icon on the right side of the C menu.
[*]On first launch, hit the [b]Get free Groq key[/b] button and sign up (takes 30 seconds). Paste your key into the API Key field.
[*]Describe your character — e.g. [i]"A grumpy Russian bartender who hates everyone but has a soft spot for cats"[/i].
[*]Pick an NPC class (citizen, combine, zombie, Alyx, whoever you want them to look like).
[*]Click [b]Spawn NPC[/b].
[*]Walk up to the NPC. A golden nametag appears above them.
[*]Press [b]E[/b] to open a chat window, or just type in chat when you're nearby.
[/olist]

[h2]I'm in Russia / Iran / a region blocked by OpenAI[/h2]

Use [b]Groq[/b] or [b]OpenRouter[/b] instead. Neither blocks any country we know of. The old "not available in your region" error was an OpenAI thing — the new version defaults to Groq to avoid it entirely.

[h2]Server admin options[/h2]

Convars (all [code]FCVAR_ARCHIVE[/code], persist across restarts):
[list]
[*][code]ainpc_enabled[/code] — master kill switch
[*][code]ainpc_admin_only[/code] — restrict spawning to admins
[*][code]ainpc_max_per_player[/code] — concurrent NPCs per player (default 3)
[*][code]ainpc_cooldown_seconds[/code] — spawn cooldown (default 5)
[*][code]ainpc_chat_cooldown_seconds[/code] — chat cooldown (default 1.5)
[*][code]ainpc_proximity_chat[/code] — nearby chat auto-routes to the closest NPC (default on)
[*][code]ainpc_proximity_range[/code] — distance for proximity chat (default 250)
[*][code]ainpc_interact_range[/code] — distance for E-to-talk (default 140)
[*][code]ainpc_openrouter_autorefresh[/code] — auto-update OpenRouter free models daily (default on)
[/list]

[h2]Got an error? Read this first[/h2]

[list]
[*][b]"No AI NPC spawned"[/b] — Press C → AI NPCs → Spawn one.
[*][b]"API key required"[/b] — The old free-key button was a dead hardcoded key that doesn't work any more. You need to get your own free key. Click the big button in the panel, it's a 30-second signup.
[*][b]"... can't respond right now: HTTP error 401"[/b] — Your API key is wrong. Paste it again.
[*][b]"... can't respond right now: HTTP error 429"[/b] — You've hit the rate limit. Wait a few minutes, or switch providers.
[*][b]Pressing E doesn't open the chat window[/b] — Make sure the NPC has the golden nametag above its head. If not, it's a regular NPC, not an AI one.
[/list]

[h2]Links[/h2>
[list]
[*][url=https://github.com/SonnyTaylor/AI-NPCs-GMod]GitHub repo[/url]
[*]Report bugs in the Discussions tab, not the comments — we actually read the Discussions tab.
[/list]

---

## Repository rename suggestion

The GitHub repo is currently named `AI-NPCs-GMod`. That's fine but a few tweaks would help:

1. Rename to **`gmod-ai-npcs`** (lowercase, dash-prefixed by platform — matches the common `gmod-*` convention for GMod addons on GitHub). This also improves discoverability when someone searches "gmod ai".
2. Update the Workshop addon title to **"AI NPCs"** (drop "ChatGPT" — it's misleading now that the addon supports five providers, and "ChatGPT" in the title keeps driving the false expectation that typing the word "API" is the setup instruction — see the YoshiGamerLover777 comment).
3. Set the GitHub repo description to: *"Spawn AI-powered NPCs in Garry's Mod. Supports free providers (Groq, OpenRouter), OpenAI, DeepSeek, and self-hosted Ollama."*
4. Add topics: `garrys-mod`, `gmod`, `gmod-addon`, `lua`, `ai`, `llm`, `chatbot`, `roleplay`.

## Things to update on the Workshop page itself (outside the description)

- **Title**: change from "ChatGPT NPCs" to **"AI NPCs"**.
- **Tags**: add "Addon" (in addition to existing fun/roleplay).
- **Screenshots**: the current ones show the old UI. Take new ones showing:
  1. The config panel with the provider dropdown open
  2. The golden nametag above an NPC
  3. The press-E chat window mid-conversation
  4. The onboarding modal ("Get free Groq key")
- **Change notes** for this update: paste the "What v2.0 fixes" section from the description.
- **Pin a comment** saying: *"v2.0 released — the free tier actually works now, and every crash from the old version is fixed. If you had a bad experience before, unsubscribe and resubscribe to grab the new version."*
