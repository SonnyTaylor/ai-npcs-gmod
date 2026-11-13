#!/usr/bin/env python3
"""
AI NPCs — voice relay
=====================

GMod can only play audio from a URL and must never hold an API key, so this tiny
local service sits in between:

    GMod  --GET /tts?voice=<id>&text=<line>-->  relay  --Bearer <your key>-->  Fish Audio

Each user runs their own copy and supplies their own Fish Audio key. The key never
leaves this machine, never appears in GMod, and is never written to the addon.

    python relay/server.py                 # http://127.0.0.1:7171
    python relay/server.py --port 7171 --host 127.0.0.1

Endpoints
    GET  /                    setup + voice library browser (open in a browser)
    GET  /health              {"ok": true, ...}
    GET  /voices?q=&limit=    voice models from your Fish Audio account/library
    GET  /tts?voice=&text=    WAV audio for one chunk of text (disk cached)
    POST /config              {"key": "sk-fish-..."}  save + validate a key

Zero dependencies: Python 3.8+ standard library only.
"""

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FISH_API = "https://api.fish.audio"
FISH_TTS_MODEL = os.environ.get("FISH_TTS_MODEL", "s2.1-pro-free")
CACHE_TTL = 60 * 60          # voice list cache, seconds
MAX_TTS_CHARS = 400          # one request; GMod already chunks to ~180
VOICE_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

HERE = os.path.dirname(os.path.abspath(__file__))


# ----------------------------------------------------------------------------- config

class Config:
    def __init__(self, path):
        self.path = path
        self.key_from_env = bool(os.environ.get("FISH_API_KEY"))
        self.key_explicit = False
        self.data = {
            "fish_key": os.environ.get("FISH_API_KEY", ""),
            "default_voice": "",
            "presets": [],          # [{"id": "<fish model id>", "label": "Rick Sanchez"}]
        }
        self._load()

    def _load(self):
        try:
            with open(self.path, "r", encoding="utf-8") as fh:
                disk = json.load(fh)
            if isinstance(disk, dict):
                for k in ("fish_key", "default_voice"):
                    if disk.get(k):
                        self.data[k] = disk[k]
                if isinstance(disk.get("presets"), list):
                    self.data["presets"] = [
                        p for p in disk["presets"]
                        if isinstance(p, dict) and VOICE_RE.match(str(p.get("id", "")))
                    ][:200]
        except FileNotFoundError:
            pass
        except Exception as exc:                      # noqa: BLE001
            log("config: ignoring unreadable %s (%s)" % (self.path, exc))

    def save(self):
        # A key supplied through FISH_API_KEY stays in the environment: it is never
        # written to disk, so a shared/zipped relay folder can't leak it.
        out = dict(self.data)
        if self.key_from_env and not self.key_explicit:
            out["fish_key"] = ""

        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(out, fh, indent=2)
        os.replace(tmp, self.path)
        try:
            os.chmod(self.path, 0o600)
        except OSError:
            pass                                  # windows

    @property
    def key(self):
        return self.data.get("fish_key") or ""

    def set_key(self, key):
        self.data["fish_key"] = key
        self.key_explicit = True
        self.save()


def log(msg):
    sys.stderr.write("[relay] %s\n" % msg)
    sys.stderr.flush()


# ----------------------------------------------------------------------------- fish api

class FishError(Exception):
    pass


def fish_request(path, payload=None, timeout=60, retries=2):
    """GET when payload is None, POST otherwise. Returns raw bytes."""
    if not CONFIG.key:
        raise FishError("no_api_key")

    url = FISH_API + path
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {
        "Authorization": "Bearer " + CONFIG.key,
        "Accept": "application/json",
    }
    if body is not None:
        headers["Content-Type"] = "application/json"
        headers["model"] = FISH_TTS_MODEL

    last = None
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, data=body, headers=headers,
                                     method="POST" if body is not None else "GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = exc.read().decode("utf-8", "replace")[:300]
            except Exception:                     # noqa: BLE001
                pass
            last = "http %s %s" % (exc.code, detail)
            # 401/402/404 are permanent; 429/5xx are worth one more try.
            if exc.code in (401, 402, 403, 404, 422):
                break
            time.sleep(1.5 * (attempt + 1))
        except Exception as exc:                  # noqa: BLE001
            last = "network %s" % exc
            time.sleep(1.0 * (attempt + 1))
    raise FishError(last or "unknown")


_voices_lock = threading.Lock()
_voices_cache = {"at": 0.0, "items": []}


def normalise_models(batch):
    """Fish model objects -> miniature voice entries, skippable garbage removed."""
    out = []
    for m in batch or []:
        if m.get("state") not in (None, "trained"):
            continue
        if m.get("type") not in (None, "tts"):
            continue
        mid = m.get("_id") or ""
        if not VOICE_RE.match(mid):
            continue
        out.append({
            "name": mid,
            "label": (m.get("title") or mid)[:60],
            "tags": (m.get("tags") or [])[:6],
        })
    return out


def fetch_model(model_id):
    """Look up one model id directly (used when someone pastes an id)."""
    raw = fish_request("/model/" + urllib.parse.quote(model_id), timeout=30)
    parsed = json.loads(raw.decode("utf-8", "replace"))
    found = normalise_models([parsed])
    return found[0] if found else None


def preset_entries():
    """Pinned voices, always served first so the in-game dropdown opens useful."""
    out = []
    for p in CONFIG.data.get("presets", []):
        out.append({"name": p["id"], "label": (p.get("label") or p["id"])[:60], "tags": ["pinned"]})
    return out


def add_preset(model_id):
    found = fetch_model(model_id)
    if not found:
        raise FishError("model not found: " + model_id)
    presets = CONFIG.data.setdefault("presets", [])
    presets = [p for p in presets if p.get("id") != model_id]
    presets.insert(0, {"id": model_id, "label": found["label"].strip()})
    CONFIG.data["presets"] = presets[:200]
    CONFIG.save()
    return found


def remove_preset(model_id):
    CONFIG.data["presets"] = [p for p in CONFIG.data.get("presets", []) if p.get("id") != model_id]
    CONFIG.save()


_search_lock = threading.Lock()
_search_cache = {}                               # query -> (timestamp, items)


def search_voices(query, limit=60):
    """Fish's `title` query parameter is a real server-side search across the whole
    library — the plain listing only exposes a 1000-model window, which is why
    searching the window locally misses half the characters people want."""
    query = query.strip()
    if not query:
        return []

    key = query.lower()
    with _search_lock:
        hit = _search_cache.get(key)
        if hit and time.time() - hit[0] < 300:
            return hit[1][:limit]

    path = "/model?page_size=100&page_number=1&title=%s" % urllib.parse.quote(query)
    raw = fish_request(path, timeout=40)
    parsed = json.loads(raw.decode("utf-8", "replace"))
    items = normalise_models(parsed.get("items"))

    # Fish's search is fuzzy: keep exact-ish prefix matches first.
    items.sort(key=lambda v: (not v["label"].lower().startswith(key), v["label"].lower()))
    with _search_lock:
        _search_cache[key] = (time.time(), items)
    return items[:limit]


def fetch_voices(force=False):
    """Every TTS model on the account, newest pages first, cached for an hour."""
    with _voices_lock:
        if not force and _voices_cache["items"] and (time.time() - _voices_cache["at"] < CACHE_TTL):
            return _voices_cache["items"]

    items, page = [], 1
    while page <= 10:                             # hard ceiling: 1000 voices
        raw = fish_request("/model?page_size=100&page_number=%d" % page, timeout=40)
        parsed = json.loads(raw.decode("utf-8", "replace"))
        batch = parsed.get("items") or []
        if not batch:
            break
        items.extend(normalise_models(batch))
        if len(batch) < 100:
            break
        page += 1

    items.sort(key=lambda v: v["label"].lower())
    with _voices_lock:
        _voices_cache["items"] = items
        _voices_cache["at"] = time.time()
    return items


# ----------------------------------------------------------------------------- tts

def cache_path(key):
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
    return os.path.join(CACHE_DIR, digest + ".wav")


def prune_cache(max_bytes=512 * 1024 * 1024):
    try:
        files = [(os.path.getmtime(os.path.join(CACHE_DIR, f)), os.path.getsize(os.path.join(CACHE_DIR, f)),
                  os.path.join(CACHE_DIR, f))
                 for f in os.listdir(CACHE_DIR) if f.endswith(".wav")]
    except OSError:
        return
    total = sum(f[1] for f in files)
    if total <= max_bytes:
        return
    for _, size, path in sorted(files):
        try:
            os.remove(path)
            total -= size
        except OSError:
            pass
        if total <= max_bytes:
            break


def fish_tts(voice, text):
    payload = {
        "text": text,
        "reference_id": voice,
        "format": "wav",
        "sample_rate": 44100,
        "normalize": True,
        "latency": "normal",
        "prosody": {"speed": 1, "volume": 0, "normalize_loudness": True},
    }
    audio = fish_request("/v1/tts", payload, timeout=90)
    if len(audio) < 512 or not audio[:4] == b"RIFF":
        raise FishError("not_wav:%d" % len(audio))
    return audio


# Optional retro engines: if the binary exists, its voices show up in the library.
RETRO = {
    "retro-espeak": ["espeak-ng", "-v", "en", "--stdout"],
    "retro-sam":    ["sam", "-wav", "-"],
}


def retro_available():
    return [name for name, argv in RETRO.items() if shutil.which(argv[0])]


def retro_tts(name, text):
    argv = RETRO.get(name)
    if not argv:
        raise FishError("unknown_retro_voice")

    if name == "retro-espeak":
        proc = subprocess.run(argv + [text], capture_output=True, timeout=30)
        if proc.returncode != 0 or not proc.stdout:
            raise FishError("espeak failed")
        return proc.stdout

    if name == "retro-sam":
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out.wav")
            proc = subprocess.run(["sam", "-wav", out, text], capture_output=True, timeout=30)
            if proc.returncode != 0 or not os.path.exists(out):
                raise FishError("sam failed")
            with open(out, "rb") as fh:
                return fh.read()

    raise FishError("unknown_retro_voice")


def synth(voice, text):
    """Return WAV bytes for (voice, text), using the disk cache when possible."""
    text = " ".join((text or "").split())[:MAX_TTS_CHARS]
    if not text:
        raise FishError("empty_text")

    path = cache_path(voice + "\x00" + text)
    if os.path.exists(path):
        with open(path, "rb") as fh:
            return fh.read()

    audio = retro_tts(voice, text) if voice.startswith("retro-") else fish_tts(voice, text)

    try:
        with open(path, "wb") as fh:
            fh.write(audio)
        threading.Thread(target=prune_cache, daemon=True).start()
    except OSError as exc:
        log("cache write failed: %s" % exc)
    return audio


# ----------------------------------------------------------------------------- html

def setup_page():
    voices, error = [], ""
    try:
        voices = fetch_voices()
    except FishError as exc:
        error = str(exc)

    preview_text = urllib.parse.quote_plus("Hello, I am an AI NPC in Garry's Mod.")

    def voice_row(v, extra=""):
        return ('<li><b>%s</b> <code>%s</code> <a href="/tts?voice=%s&text=%s" target="_blank">preview</a> %s</li>'
                % (html.escape(v["label"]), html.escape(v["name"][:8]), html.escape(v["name"]), preview_text, extra))

    pins = "".join(
        voice_row(p, '<form method="post" action="/presets" style="display:inline">'
                     '<input type="hidden" name="id" value="%s"><input type="hidden" name="remove" value="1">'
                     '<button class="ghost">unpin</button></form>' % html.escape(p["name"]))
        for p in preset_entries()
    ) or "<li><i>nothing pinned yet</i></li>"

    library = "".join(voice_row(v) for v in voices[:300]) or "<li><i>no voices found</i></li>"

    key_state = "a key is configured" if CONFIG.key else "<b>no key configured</b>"
    return """<!doctype html><meta charset="utf-8"><title>AI NPCs — voice relay</title>
<style>
 body{font:14px/1.5 system-ui,sans-serif;background:#1b1b1f;color:#e6e6e6;margin:0;padding:28px}
 h1{font-size:20px;margin:0 0 4px} .sub{color:#9a9a9a;margin-bottom:20px}
 section{background:#242429;border-radius:8px;padding:16px;margin-bottom:16px;max-width:900px}
 input{background:#1b1b1f;border:1px solid #3a3a41;color:#e6e6e6;padding:8px;border-radius:5px;width:420px}
 button{background:#3b6fd4;color:#fff;border:0;padding:8px 14px;border-radius:5px;cursor:pointer}
 button.ghost{background:#3a3a41;padding:2px 8px;font-size:12px}
 code{color:#8fb8ff} ul{padding-left:18px;max-height:320px;overflow:auto}
 li{margin:3px 0} a{color:#7fd48b} .err{color:#ff8b8b} .note{color:#8c8c8c;font-size:12px}
</style>
<h1>AI NPCs — voice relay</h1>
<div class="sub">Fish Audio key: %s. The key is stored in <code>relay/config.json</code> on this machine and never leaves it.</div>

<section>
  <p>Paste your own Fish Audio API key (fish.audio → Settings → API keys):</p>
  <form method="post" action="/config">
    <input type="password" name="key" placeholder="sk-fish-...">
    <button type="submit">Save key</button>
  </form>
  <p class="err">%s</p>
  <p class="note">Then in game: <code>ainpc_voice_relay_url "http://%s:%d"</code> (or leave it empty to use this default).</p>
</section>

<section>
  <p><b>Pinned voices</b> — these appear first in the in-game voice dropdown. Paste any model id from the Fish Audio library:</p>
  <form method="post" action="/presets">
    <input name="id" placeholder="32-character model id (e.g. d2e75a3e3fd6419893057c02a375a113)">
    <button type="submit">Pin</button>
  </form>
  <ul>%s</ul>
</section>

<section>
  <p><b>Voice library</b> — %d models on this account. Searching and listing are free; the <i>preview</i> links generate audio and spend your Fish credits.</p>
  <ul>%s</ul>
</section>
""" % (key_state, html.escape(error), HOST, PORT, pins, len(voices), library)


# ----------------------------------------------------------------------------- http

class Handler(BaseHTTPRequestHandler):
    server_version = "AINPCVoiceRelay/1.0"

    def log_message(self, fmt, *args):            # keep the console quiet-ish
        if "/tts" not in (args[0] if args else ""):
            log("%s %s" % (self.address_string(), fmt % args))

    # -- helpers --------------------------------------------------------------
    def send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, code, text):
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # -- routes ---------------------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        route = parsed.path.rstrip("/") or "/"
        qs = urllib.parse.parse_qs(parsed.query)

        if route == "/":
            return self.send_html(200, setup_page())

        if route == "/health":
            return self.send_json(200, {
                "ok": True,
                "key_set": bool(CONFIG.key),
                "default_voice": CONFIG.data.get("default_voice", ""),
                "tts_model": FISH_TTS_MODEL,
                "retro": retro_available(),
                "voices_cached": len(_voices_cache["items"]),
                "presets": len(CONFIG.data.get("presets", [])),
            })

        if route == "/voices":
            query = (qs.get("q") or [""])[0].strip()
            model_id = (qs.get("id") or [""])[0].strip()
            limit = max(1, min(500, int((qs.get("limit") or ["200"])[0] or 200)))

            try:
                if model_id:
                    found = fetch_model(model_id)
                    items = [found] if found else []
                elif query:
                    items = search_voices(query, limit=limit)
                else:
                    items = fetch_voices(force=(qs.get("refresh") or ["0"])[0] == "1")
            except FishError as exc:
                return self.send_json(502, {"error": str(exc), "voices": []})

            if query or model_id:
                pinned = [p for p in preset_entries()
                          if not query or query.lower() in p["label"].lower()]
            else:
                pinned = preset_entries()
            seen = {p["name"] for p in pinned}
            items = pinned + [v for v in items if v["name"] not in seen]

            voices = [{"name": v["name"], "label": v["label"]} for v in items[:limit]]
            voices += [{"name": n, "label": "Retro — " + n.replace("retro-", "")}
                       for n in retro_available()]
            return self.send_json(200, {"voices": voices})

        if route == "/tts":
            voice = (qs.get("voice") or [""])[0].strip()
            text = (qs.get("text") or [""])[0]
            if not voice or not text:
                return self.send_json(400, {"error": "voice and text required"})
            if not VOICE_RE.match(voice):
                return self.send_json(400, {"error": "bad voice id"})
            try:
                audio = synth(voice, text)
            except FishError as exc:
                return self.send_json(502, {"error": str(exc)})
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(audio)))
            self.send_header("Cache-Control", "public, max-age=86400")
            self.end_headers()
            self.wfile.write(audio)
            return

        return self.send_json(404, {"error": "not found"})

    def do_POST(self):
        route = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(min(length, 8192)) if length else b""

        if route == "/config":
            key = ""
            ctype = (self.headers.get("Content-Type") or "").lower()
            if "application/json" in ctype:
                try:
                    key = (json.loads(raw.decode("utf-8", "replace")) or {}).get("key", "")
                except Exception:                 # noqa: BLE001
                    key = ""
            else:
                form = urllib.parse.parse_qs(raw.decode("utf-8", "replace"))
                key = (form.get("key") or [""])[0]

            key = key.strip()
            if not key.startswith("sk-fish-"):
                return self._finish_config("That does not look like a Fish Audio key (sk-fish-...).", 400)

            old = CONFIG.key
            CONFIG.set_key(key)
            try:                                  # validate against the API
                fetch_voices(force=True)
            except FishError as exc:
                CONFIG.data["fish_key"] = old
                CONFIG.save()
                return self._finish_config("Key rejected by Fish Audio: %s" % exc, 400)

            log("config: fish key stored")
            return self._finish_config("", 200)

        if route == "/presets":
            wanted, remove = "", False
            ctype = (self.headers.get("Content-Type") or "").lower()
            if "application/json" in ctype:
                data = json.loads(raw.decode("utf-8", "replace")) if raw else {}
                wanted = str((data or {}).get("id", "")).strip().lower()
                remove = bool((data or {}).get("remove"))
            else:
                form = urllib.parse.parse_qs(raw.decode("utf-8", "replace"))
                wanted = (form.get("id") or [""])[0].strip().lower()
                remove = (form.get("remove") or ["0"])[0] not in ("", "0")

            if not VOICE_RE.match(wanted):
                return self.send_json(400, {"error": "id must be a Fish Audio model id"})

            try:
                if remove:
                    remove_preset(wanted)
                    log("presets: unpinned %s" % wanted[:8])
                else:
                    found = add_preset(wanted)
                    log("presets: pinned %s (%s)" % (wanted[:8], found["label"]))
            except FishError as exc:
                return self.send_json(502, {"error": str(exc)})

            if "application/json" in (self.headers.get("Accept") or ""):
                return self.send_json(200, {"ok": True,
                                            "presets": CONFIG.data.get("presets", [])})
            self.send_response(303)
            self.send_header("Location", "/")
            self.end_headers()
            return

        return self.send_json(404, {"error": "not found"})

    def _finish_config(self, error, code):
        if "application/json" in (self.headers.get("Accept") or ""):
            return self.send_json(code, {"ok": code == 200, "error": error or None})
        self.send_response(303)                   # back to the setup page
        self.send_header("Location", "/")
        self.end_headers()


# ----------------------------------------------------------------------------- main

def main():
    global CONFIG, CACHE_DIR, HOST, PORT

    ap = argparse.ArgumentParser(description="AI NPCs voice relay")
    ap.add_argument("--host", default="127.0.0.1", help="bind address (default 127.0.0.1)")
    ap.add_argument("--port", type=int, default=7171)
    ap.add_argument("--config", default=os.path.join(HERE, "config.json"))
    ap.add_argument("--cache", default=os.path.join(HERE, "cache"))
    args = ap.parse_args()

    HOST, PORT = args.host, args.port
    CONFIG = Config(args.config)
    CACHE_DIR = args.cache
    os.makedirs(CACHE_DIR, exist_ok=True)

    if not CONFIG.key:
        log("no Fish Audio key yet — open http://%s:%d/ and paste one" % (HOST, PORT))
    if HOST not in ("127.0.0.1", "localhost"):
        log("WARNING: bound to %s — anyone who can reach this port can spend your Fish credits" % HOST)

    log("listening on http://%s:%d  (key %s)" % (HOST, PORT, "loaded" if CONFIG.key else "missing"))
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
