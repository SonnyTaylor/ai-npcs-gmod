<#
    AI NPCs — voice service (Windows PowerShell, no installs required)

    Fish Audio's TTS is an HTTP POST that returns audio bytes, and Garry's Mod can
    only *play* audio from a URL. This little local server closes that gap. Your
    Fish key stays in relay/config.json on this machine.

    Run it by double-clicking relay\start.bat (or: powershell -ExecutionPolicy Bypass -File relay\relay.ps1)

    Endpoints (same contract as relay/server.py):
        GET  /                     setup page
        GET  /health               status
        GET  /voices?q=rick        search the library      (free)
        GET  /voices?id=<32-hex>   one model               (free)
        GET  /voices?limit=40      listing, pinned first   (free)
        GET  /tts?voice=&text=     wav audio               (spends credits)
        POST /config               {"key": "sk-fish-..."}
        POST /presets              {"id": "..."} / {"id": "...", "remove": true}
#>

param(
    [int]    $Port   = 7171,
    [string] $Host_  = "localhost",
    [string] $ConfigPath = "",
    [string] $CacheDir   = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($ConfigPath -eq "") { $ConfigPath = Join-Path $Root "config.json" }
if ($CacheDir   -eq "") { $CacheDir   = Join-Path $Root "cache" }

$FishApi   = "https://api.fish.audio"
$FishModel = "s2.1-pro-free"     # TTS backend, not the voice
$MaxChars  = 400
$VoiceRe   = '^[A-Za-z0-9_-]{1,64}$'

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

function Write-Log($msg) {
    Write-Host ("[voice] {0}" -f $msg) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- config -----
function Load-Config {
    $cfg = @{ fish_key = ""; presets = @(); default_voice = "" }
    if (Test-Path $ConfigPath) {
        try {
            $disk = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json
            if ($disk.fish_key)      { $cfg.fish_key = $disk.fish_key }
            if ($disk.default_voice) { $cfg.default_voice = $disk.default_voice }
            if ($disk.presets)       { $cfg.presets = @($disk.presets) }
        } catch { Write-Log "config unreadable, starting fresh" }
    }
    return $cfg
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $ConfigPath
}

$Config = Load-Config

# ---------------------------------------------------------------- fish -------
function Invoke-FishJson([string]$Path) {
    if (-not $Config.fish_key) { throw "no_api_key" }
    $r = Invoke-WebRequest -Uri ($FishApi + $Path) -Method Get `
            -Headers @{ Authorization = "Bearer $($Config.fish_key)" } `
            -UseBasicParsing -TimeoutSec 40
    return ($r.Content | ConvertFrom-Json)
}

function Get-FishVoices([string]$Query, [int]$Limit = 40) {
    $path = if ($Query) {
        "/model?page_size=100&page_number=1&title=" + [uri]::EscapeDataString($Query)
    } else {
        "/model?page_size=100&page_number=1"
    }
    $parsed = Invoke-FishJson $path
    $out = @()
    foreach ($m in @($parsed.items)) {
        if (-not $m._id) { continue }
        if ($m.state -and $m.state -ne "trained") { continue }
        if ($m.type  -and $m.type  -ne "tts")     { continue }
        if ($m._id -notmatch $VoiceRe)            { continue }
        $label = if ($m.title) { "$($m.title)".Trim() } else { $m._id }
        if ($label.Length -gt 60) { $label = $label.Substring(0, 60) }
        $out += [pscustomobject]@{ name = $m._id; label = $label }
    }
    if ($Query) {
        # Fish search is fuzzy: prefer titles that start with the query.
        $q = $Query.ToLower()
        $out = @($out | Sort-Object @{ Expression = { -not $_.label.ToLower().StartsWith($q) } }, label)
    } else {
        $out = @($out | Sort-Object label)
    }
    return @($out | Select-Object -First $Limit)
}

function Get-FishVoice([string]$Id) {
    $m = Invoke-FishJson ("/model/" + [uri]::EscapeDataString($Id))
    if (-not $m._id) { throw "model_not_found" }
    $label = if ($m.title) { "$($m.title)".Trim() } else { $m._id }
    return [pscustomobject]@{ name = $m._id; label = $label }
}

function Get-Presets {
    return @($Config.presets | ForEach-Object {
        [pscustomobject]@{ name = "$($_.id)"; label = $(if ($_.label) { "$($_.label)" } else { "$($_.id)" }) }
    })
}

# ---------------------------------------------------------------- audio ------
function Get-Sha256([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").ToLower()
}

function Get-TtsBytes([string]$Voice, [string]$Text) {
    if (-not $Config.fish_key) { throw "no_api_key" }

    $text = ($Text -replace "\s+", " ").Trim()
    if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) }
    if ($text -eq "") { throw "empty_text" }

    $cacheFile = Join-Path $CacheDir ((Get-Sha256 ($Voice + "`0" + $text)) + ".wav")
    if (Test-Path $cacheFile) { return [System.IO.File]::ReadAllBytes($cacheFile) }

    $body = @{
        text            = $text
        reference_id    = $Voice
        format          = "wav"
        sample_rate     = 44100
        normalize       = $true
        latency         = "normal"
        prosody         = @{ speed = 1; volume = 0; normalize_loudness = $true }
    } | ConvertTo-Json -Depth 4

    $r = Invoke-WebRequest -Uri "$FishApi/v1/tts" -Method Post `
            -Headers @{ Authorization = "Bearer $($Config.fish_key)"; model = $FishModel } `
            -ContentType "application/json" -Body $body -UseBasicParsing -TimeoutSec 90

    $bytes = $r.Content
    if ($bytes -is [string]) { $bytes = [System.Text.Encoding]::Default.GetBytes($bytes) }
    if ($bytes.Length -lt 512 -or $bytes[0] -ne 0x52) { throw ("not_wav:" + $bytes.Length) }

    try { [System.IO.File]::WriteAllBytes($cacheFile, $bytes) } catch { }
    return $bytes
}

# ---------------------------------------------------------------- http -------
function Send-Json($ctx, [int]$code, $obj) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 6))
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = "application/json"
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Send-Html($ctx, [int]$code, [string]$html) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = "text/html; charset=utf-8"
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Send-Wav($ctx, [byte[]]$bytes) {
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = "audio/wav"
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Get-SetupPage {
    $keyState = if ($Config.fish_key) { "a key is configured" } else { "<b>no key configured</b>" }
    $pinRows = ""
    foreach ($p in Get-Presets) {
        $pinRows += "<li><b>$($p.label)</b> <code>$($p.name.Substring(0,8))</code>
            <form method='post' action='/presets' style='display:inline'>
            <input type='hidden' name='id' value='$($p.name)'><input type='hidden' name='remove' value='1'>
            <button class='ghost'>unpin</button></form></li>"
    }
    if (-not $pinRows) { $pinRows = "<li><i>nothing pinned yet</i></li>" }

    $libRows = ""
    try {
        foreach ($v in (Get-FishVoices "" 60)) {
            $libRows += "<li><b>$($v.label)</b> <code>$($v.name.Substring(0,8))</code></li>"
        }
    } catch { $libRows = "<li class='err'>$($_.Exception.Message)</li>" }

    return @"
<!doctype html><meta charset='utf-8'><title>AI NPCs - voice service</title>
<style>
 body{font:14px/1.5 system-ui,sans-serif;background:#1b1b1f;color:#e6e6e6;margin:0;padding:28px}
 h1{font-size:20px;margin:0 0 4px} .sub{color:#9a9a9a;margin-bottom:20px}
 section{background:#242429;border-radius:8px;padding:16px;margin-bottom:16px;max-width:900px}
 input{background:#1b1b1f;border:1px solid #3a3a41;color:#e6e6e6;padding:8px;border-radius:5px;width:400px}
 button{background:#3b6fd4;color:#fff;border:0;padding:8px 14px;border-radius:5px;cursor:pointer}
 button.ghost{background:#3a3a41;padding:2px 8px;font-size:12px}
 code{color:#8fb8ff} ul{padding-left:18px;max-height:300px;overflow:auto} .err{color:#ff8b8b}
</style>
<h1>AI NPCs - voice service</h1>
<div class='sub'>Fish Audio key: $keyState. Stored in relay/config.json on this machine only.</div>
<section>
  <form method='post' action='/config'>
    <p>Fish Audio API key (fish.audio -> Settings -> API keys). You can also paste it in game.</p>
    <input type='password' name='key' placeholder='sk-fish-...'>
    <button type='submit'>Save key</button>
  </form>
</section>
<section><p><b>Pinned voices</b> (first in the in-game list)</p>
  <form method='post' action='/presets'><input name='id' placeholder='32-character model id'>
  <button type='submit'>Pin</button></form><ul>$pinRows</ul></section>
<section><p><b>Library</b> - search in game by typing a character name.</p><ul>$libRows</ul></section>
"@
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://${Host_}:$Port/"
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
} catch {
    Write-Host "Could not start on $prefix" -ForegroundColor Red
    Write-Host "$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Another copy may already be running." -ForegroundColor Yellow
    Start-Sleep -Seconds 6
    exit 1
}

Write-Log "listening on $prefix"
Write-Log ("Fish key: " + $(if ($Config.fish_key) { "configured" } else { "NOT configured - paste one at $prefix" }))

while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()
    } catch { break }

    $req = $ctx.Request
    $path = $req.Url.AbsolutePath.TrimEnd("/")
    if ($path -eq "") { $path = "/" }

    try {
        switch -Regex ($path) {

            '^/$' {
                Send-Html $ctx 200 (Get-SetupPage)
            }

            '^/health$' {
                Send-Json $ctx 200 @{
                    ok = $true
                    key_set = [bool]$Config.fish_key
                    presets = @(Get-Presets).Count
                    credits = $(try { [double](Invoke-FishJson "/wallet/self/api-credit").credit } catch { $null })
                    tts_model = $FishModel
                    engine = "powershell"
                }
            }

            '^/voices$' {
                $q    = $req.QueryString["q"]
                $id   = $req.QueryString["id"]
                $lim  = 40
                if ($req.QueryString["limit"]) { [int]::TryParse($req.QueryString["limit"], [ref]$lim) | Out-Null }

                $voices = @()
                try {
                    if ($id)      { $voices = @(Get-FishVoice $id) }
                    elseif ($q)   { $voices = @(Get-FishVoices $q $lim) }
                    else          { $voices = @(Get-FishVoices "" $lim) }
                } catch {
                    Send-Json $ctx 502 @{ error = "$($_.Exception.Message)"; voices = @() }
                    continue
                }

                $pinned = @(Get-Presets | Where-Object { -not $q -or $_.label.ToLower().Contains($q.ToLower()) })
                $seen = @{}
                foreach ($p in $pinned) { $seen[$p.name] = $true }
                $merged = @($pinned) + @($voices | Where-Object { -not $seen[$_.name] })
                Send-Json $ctx 200 @{ voices = @($merged | Select-Object -First $lim) }
            }

            '^/tts$' {
                $voice = $req.QueryString["voice"]
                $text  = $req.QueryString["text"]
                if (-not $voice -or -not $text) { Send-Json $ctx 400 @{ error = "voice and text required" }; continue }
                if ($voice -notmatch $VoiceRe)  { Send-Json $ctx 400 @{ error = "bad voice id" }; continue }
                try {
                    Send-Wav $ctx (Get-TtsBytes $voice $text)
                } catch {
                    $msg = "$($_.Exception.Message)"
                    Send-Json $ctx 502 @{ error = $msg }
                }
            }

            '^/config$' {
                if ($req.HttpMethod -ne "POST") { Send-Json $ctx 405 @{ error = "POST only" }; continue }

                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $raw = $reader.ReadToEnd(); $reader.Close()

                $key = ""
                if ($raw.TrimStart().StartsWith("{")) {
                    $key = ("$((ConvertFrom-Json $raw).key)")
                } elseif ($raw -match "key=([^&]+)") {
                    $key = [uri]::UnescapeDataString($Matches[1])
                }
                $key = $key.Trim()

                if (-not $key.StartsWith("sk-fish-")) {
                    Send-Json $ctx 400 @{ ok = $false; error = "that does not look like a Fish Audio key" }; continue
                }

                $old = $Config.fish_key
                $Config.fish_key = $key
                try {
                    # /model is unauthenticated, so it cannot prove a key is valid.
                    Invoke-FishJson "/wallet/self/api-credit" | Out-Null
                    Save-Config $Config
                    Write-Log "key saved and validated"
                    Send-Json $ctx 200 @{ ok = $true }
                } catch {
                    $Config.fish_key = $old
                    Send-Json $ctx 400 @{ ok = $false; error = "Fish rejected the key: $($_.Exception.Message)" }
                }
            }

            '^/presets$' {
                if ($req.HttpMethod -ne "POST") { Send-Json $ctx 405 @{ error = "POST only" }; continue }

                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $raw = $reader.ReadToEnd(); $reader.Close()

                $id = ""; $remove = $false
                if ($raw.TrimStart().StartsWith("{")) {
                    $o = ConvertFrom-Json $raw
                    $id = "$($o.id)"; $remove = [bool]$o.remove
                } else {
                    if ($raw -match "id=([^&]+)")     { $id     = [uri]::UnescapeDataString($Matches[1]) }
                    if ($raw -match "remove=([^&]+)") { $remove = $Matches[1] -notin @("", "0", "false") }
                }
                $id = $id.Trim().ToLower()
                if ($id -notmatch $VoiceRe) { Send-Json $ctx 400 @{ ok = $false; error = "id must be a model id" }; continue }

                if ($remove) {
                    $Config.presets = @($Config.presets | Where-Object { "$($_.id)" -ne $id })
                    Save-Config $Config
                    Send-Json $ctx 200 @{ ok = $true; presets = @(Get-Presets) }
                } else {
                    try {
                        $found = Get-FishVoice $id
                        $Config.presets = @(@([pscustomobject]@{ id = $id; label = $found.label }) +
                                            @($Config.presets | Where-Object { "$($_.id)" -ne $id })) | Select-Object -First 200
                        Save-Config $Config
                        Send-Json $ctx 200 @{ ok = $true; presets = @(Get-Presets) }
                    } catch {
                        Send-Json $ctx 502 @{ ok = $false; error = "$($_.Exception.Message)" }
                    }
                }
            }

            default { Send-Json $ctx 404 @{ error = "not found" } }
        }
    } catch {
        try { Send-Json $ctx 500 @{ error = "$($_.Exception.Message)" } } catch { }
    }
}
