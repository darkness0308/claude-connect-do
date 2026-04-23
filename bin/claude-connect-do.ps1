#!/usr/bin/env pwsh

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
}
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
$env:LC_ALL = "C.UTF-8"

$VERSION = "1.0.0"
$CONFIG_DIR = Join-Path $HOME ".config/claude-connect-do"
$CONFIG_FILE = Join-Path $CONFIG_DIR "config.env"
$MODELS_CACHE = Join-Path $CONFIG_DIR "models_cache.json"
$LITELLM_CONFIG = Join-Path $CONFIG_DIR "litellm_config.yaml"
$VENV_DIR = Join-Path $CONFIG_DIR "venv"
$LITELLM_WRAPPER = Join-Path $CONFIG_DIR "litellm_wrapper.py"
$INSTANCES_DIR = Join-Path $CONFIG_DIR "instances"
$LOGS_DIR = Join-Path $CONFIG_DIR "logs"
$PORT_MIN = 9119
$PORT_MAX = 9218
$HEALTH_TIMEOUT = 30
$DO_API_BASE = "https://inference.do-ai.run"
$PROXY_MASTER_KEY = "sk-claude-connect-do-$([guid]::NewGuid().ToString('N'))"
$LOCAL_BIN_DIR = Join-Path $HOME "bin"

$script:ProxyProcess = $null
$script:ProxyPort = $null

function Die([string]$msg) {
  Write-Host "error: $msg" -ForegroundColor Red
  exit 1
}

function Info([string]$msg) {
  Write-Host "[>] $msg" -ForegroundColor Blue
}

function Warn([string]$msg) {
  Write-Host "[!] $msg" -ForegroundColor Yellow
}

function Ok([string]$msg) {
  Write-Host "[+] $msg" -ForegroundColor Green
}

function Ensure-Dirs {
  New-Item -ItemType Directory -Path $CONFIG_DIR -Force | Out-Null
  New-Item -ItemType Directory -Path $INSTANCES_DIR -Force | Out-Null
  New-Item -ItemType Directory -Path $LOGS_DIR -Force | Out-Null
}

function Get-CurrentScriptPath {
  return (Resolve-Path $PSCommandPath).Path
}

function Load-Config {
  if (-not (Test-Path $CONFIG_FILE)) {
    return @{}
  }

  $cfg = @{}
  Get-Content $CONFIG_FILE | ForEach-Object {
    if ($_ -match '^\s*#') { return }
    if ($_ -match '^\s*$') { return }
    if ($_ -match '^([^=]+)=(.*)$') {
      $k = $Matches[1].Trim()
      $v = $Matches[2]
      $cfg[$k] = $v
    }
  }
  return $cfg
}

function Save-Config([string]$apiKey) {
  $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  @(
    "# claude-connect-do configuration - generated $ts"
    "DO_GRADIENT_API_KEY=$apiKey"
  ) | Set-Content -Path $CONFIG_FILE -Encoding UTF8
}

function Write-LiteLLMWrapper {
  $py = @'
"""claude-connect-do litellm wrapper - patches for DO Gradient AI compatibility."""
import sys

try:
    import uvicorn.config
    uvicorn.config.LOOP_SETUPS["uvloop"] = "uvicorn.loops.asyncio:asyncio_setup"
except Exception:
    pass

try:
    from litellm.llms.anthropic.experimental_pass_through.adapters.handler import (
        LiteLLMMessagesToCompletionTransformationHandler as _Handler,
    )

    _orig_prepare = _Handler._prepare_completion_kwargs

    def _strip_empty_text_blocks(messages):
        if not isinstance(messages, list):
            return messages
        cleaned = []
        for msg in messages:
            if not isinstance(msg, dict):
                cleaned.append(msg)
                continue
            content = msg.get("content")
            if isinstance(content, list):
                new_content = []
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        text = block.get("text")
                        if text is None or (isinstance(text, str) and text.strip() == ""):
                            continue
                    new_content.append(block)
                if len(new_content) == 0:
                    continue
                msg = dict(msg)
                msg["content"] = new_content
            elif isinstance(content, str) and content.strip() == "":
                continue
            cleaned.append(msg)
        return cleaned

    def _patched_prepare(**kwargs):
        extra_kwargs = kwargs.get("extra_kwargs") or {}
        for drop_key in ("context_management",):
            extra_kwargs.pop(drop_key, None)
        kwargs["extra_kwargs"] = extra_kwargs

        if "messages" in kwargs:
            kwargs["messages"] = _strip_empty_text_blocks(kwargs.get("messages"))

        system = kwargs.get("system")
        if isinstance(system, list):
            new_system = []
            for block in system:
                if isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text")
                    if text is None or (isinstance(text, str) and text.strip() == ""):
                        continue
                new_system.append(block)
            kwargs["system"] = new_system if new_system else None
        elif isinstance(system, str) and system.strip() == "":
            kwargs["system"] = None

        return _orig_prepare(**kwargs)

    _Handler._prepare_completion_kwargs = staticmethod(_patched_prepare)

    _orig_route = _Handler._route_openai_thinking_to_responses_api_if_needed

    def _patched_route(completion_kwargs, *, thinking=None):
        model = completion_kwargs.get("model", "")
        if isinstance(model, str) and "anthropic" in model:
            return
        return _orig_route(completion_kwargs, thinking=thinking)

    _Handler._route_openai_thinking_to_responses_api_if_needed = staticmethod(_patched_route)
except Exception as e:
    print(f"[claude-connect-do] WARNING: failed to patch adapter: {e}", file=sys.stderr)

try:
    import litellm
    litellm.use_chat_completions_url_for_anthropic_messages = True
except Exception as e:
    print(f"[claude-connect-do] WARNING: failed to set chat completions flag: {e}", file=sys.stderr)

from litellm.proxy.proxy_cli import run_server
run_server()
'@

  Set-Content -Path $LITELLM_WRAPPER -Value $py -Encoding UTF8
}

function Resolve-LiteLLM {
  $venvPy = Join-Path $VENV_DIR "Scripts/python.exe"
  $venvLite = Join-Path $VENV_DIR "Scripts/litellm.exe"

  if (Test-Path $venvPy) {
    try {
      & $venvPy -c "import litellm" *> $null
      if (Test-Path $LITELLM_WRAPPER) {
        return "wrapper"
      }
      if (Test-Path $venvLite) {
        return $venvLite
      }
      return "wrapper"
    } catch {
    }
  }

  if (Test-Path $venvLite) {
    return $venvLite
  }

  return $null
}

function Show-NodeInstallHelp {
  Warn "Node.js is required."
  Write-Host "  Install: winget install OpenJS.NodeJS.LTS"
  Write-Host "  Or: https://nodejs.org"
}

function Show-PythonInstallHelp {
  Warn "Python 3 with venv support is required."
  Write-Host "  Install: winget install Python.Python.3.12"
}

function Show-ClaudeInstallHelp {
  Warn "Claude Code CLI is required."
  Write-Host "  Install: npm install -g @anthropic-ai/claude-code"
  Write-Host "  Docs: https://docs.anthropic.com/en/docs/claude-code"
}

function Ensure-LiteLLM {
  if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Show-PythonInstallHelp
    Die "Python 3 is required to install the LiteLLM proxy"
  }
  try {
    python -c "import venv" *> $null
  } catch {
    Warn "Python venv module is missing."
    Show-PythonInstallHelp
    Die "Python venv module is required"
  }
  if (-not (Resolve-LiteLLM)) {
    Info "LiteLLM not found in claude-connect-do venv. Installing into $VENV_DIR (one-time; may take a few minutes)..."
    python -m venv $VENV_DIR
    $pip = Join-Path $VENV_DIR "Scripts/pip.exe"
    if (-not (Test-Path $pip)) {
      Die "Failed to create virtual environment"
    }
    & $pip install --quiet "litellm[proxy]"
    Write-LiteLLMWrapper
    Ok "LiteLLM installed in $VENV_DIR"
  }
}

function Check-Deps {
  $missing = $false

  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Show-NodeInstallHelp
    $missing = $true
  }

  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Show-ClaudeInstallHelp
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
      Warn "npm was not found. Install Node.js first."
      Show-NodeInstallHelp
    }
    $missing = $true
  }

  Ensure-LiteLLM  # handles python/venv/litellm checks and installation

  if ($missing) {
    Die "Missing dependencies. Install them and try again."
  }
}

function Bootstrap-ClaudeAuth {
  $claudeDir = Join-Path $HOME ".claude"
  $claudeJson = Join-Path $claudeDir ".claude.json"
  New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null

  if (Test-Path $claudeJson) {
    try {
      $d = Get-Content $claudeJson -Raw | ConvertFrom-Json
      if ($d.numStartups -ge 1) {
        return
      }
      $d.numStartups = [Math]::Max([int]$d.numStartups, 1)
      if (-not $d.firstStartTime) {
        $d | Add-Member -NotePropertyName firstStartTime -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
      }
      $d | ConvertTo-Json -Depth 8 | Set-Content $claudeJson -Encoding UTF8
      return
    } catch {
    }
  }

  Info "Bootstrapping Claude Code auth for API key usage..."
  $obj = [ordered]@{
    numStartups = 1
    firstStartTime = [DateTime]::UtcNow.ToString("o")
    hasCompletedOnboarding = $true
  }
  $obj | ConvertTo-Json -Depth 8 | Set-Content $claudeJson -Encoding UTF8
  Ok "Claude Code configured for API key auth"
}

function Discover-Models([switch]$Force) {
  if ((-not $Force) -and (Test-Path $MODELS_CACHE)) {
    $age = (Get-Date) - (Get-Item $MODELS_CACHE).LastWriteTime
    if ($age.TotalSeconds -lt 86400) {
      return
    }
  }

  $cfg = Load-Config
  $apiKey = $cfg["DO_GRADIENT_API_KEY"]
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Die "No API key configured. Run: claude-connect-do setup"
  }

  try {
    $headers = @{ Authorization = "Bearer $apiKey" }
    $resp = Invoke-RestMethod -Uri "$DO_API_BASE/v1/models" -Headers $headers -Method Get -TimeoutSec 30
    $resp | ConvertTo-Json -Depth 100 | Set-Content -Path $MODELS_CACHE -Encoding UTF8
  } catch {
    Die "Failed to fetch models from DO API. Check your API key and network."
  }

  Generate-LiteLLMConfig
}

function Generate-LiteLLMConfig {
  if (-not (Test-Path $MODELS_CACHE)) {
    Die "Models cache not found. Run: claude-connect-do setup"
  }

  $py = @'
import json, re, sys

API_BASE = sys.argv[2]
MASTER_KEY = sys.argv[3]

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

do_models = sorted(m["id"] for m in data.get("data", []) if "claude" in m["id"].lower())

if not do_models:
    print("No Claude models found", file=sys.stderr)
    sys.exit(1)

def do_to_cc_names(do_id):
    base = re.sub(r'^anthropic-', '', do_id)
    normalized = base.replace('.', '-')

    names = set([normalized])

    family_match = re.search(r'(sonnet|opus|haiku)', normalized)
    version_match = re.findall(r'(\d+(?:-\d+)?)', normalized)

    if family_match and version_match:
        family = family_match.group(1)
        ver_parts = '-'.join(version_match)
        names.add(f"claude-{family}-{ver_parts}")
        names.add(f"claude-{ver_parts}-{family}")

    primary = normalized
    aliases = sorted(names - {primary})
    return primary, aliases

entries = []
mapped_cc_names = set()
primary_names = set()

for do_id in do_models:
    primary, aliases = do_to_cc_names(do_id)
    entries.append((primary, do_id))
    mapped_cc_names.add(primary)
    primary_names.add(primary)
    for alias in aliases:
        if alias not in mapped_cc_names:
            entries.append((alias, do_id))
            mapped_cc_names.add(alias)
            primary_names.add(alias)

family_best = {}
for do_id in do_models:
    base = re.sub(r'^anthropic-', '', do_id)
    for family in ('sonnet', 'opus', 'haiku'):
        if family in base:
            nums = [int(x) for x in re.findall(r'(\d+)', base)]
            ver_tuple = tuple(nums) if nums else (0,)
            if family not in family_best or ver_tuple > family_best[family][0]:
                family_best[family] = (ver_tuple, do_id)
            break

for family, (_, best_do) in family_best.items():
    for major in range(3, 6):
        for minor in range(0, 10):
            candidate = f"claude-{family}-{major}-{minor}"
            if candidate not in mapped_cc_names:
                entries.append((candidate, best_do))
                mapped_cc_names.add(candidate)

KNOWN_DATES = ["20240229", "20241022", "20250219", "20250514", "20250929", "20251001"]
for base_name in list(primary_names):
    do_id_for_base = None
    for cc_name, do_id in entries:
        if cc_name == base_name:
            do_id_for_base = do_id
            break
    if do_id_for_base is None:
        continue
    for date in KNOWN_DATES:
        dated = f"{base_name}-{date}"
        if dated not in mapped_cc_names:
            entries.append((dated, do_id_for_base))
            mapped_cc_names.add(dated)

lines = ["# Auto-generated by claude-connect-do - do not edit manually", "model_list:"]
seen = set()
for cc_name, do_id in entries:
    if cc_name in seen:
        continue
    seen.add(cc_name)
    lines.append(f"  - model_name: {cc_name}")
    lines.append("    litellm_params:")
    lines.append(f"      model: openai/{do_id}")
    lines.append("      api_key: os.environ/DO_GRADIENT_API_KEY")
    lines.append(f"      api_base: {API_BASE}")
    lines.append("      drop_params: true")
    lines.append("      request_timeout: 600")

lines.append("")
lines.append("general_settings:")
lines.append("  drop_params: true")
lines.append(f"  master_key: {MASTER_KEY}")
lines.append("")
lines.append("litellm_settings:")
lines.append("  drop_params: true")
lines.append("  request_timeout: 600")

print("\n".join(lines))
'@

  $stdoutFile = [System.IO.Path]::GetTempFileName()
  $stderrFile = [System.IO.Path]::GetTempFileName()
  try {
    $py | python - $MODELS_CACHE "$DO_API_BASE/v1" $PROXY_MASTER_KEY 1> $stdoutFile 2> $stderrFile
    if ($LASTEXITCODE -ne 0) {
      $stderr = if (Test-Path $stderrFile) { Get-Content $stderrFile -Raw } else { "" }
      Die "Failed to generate LiteLLM config`n$stderr"
    }

    $yaml = Get-Content $stdoutFile -Raw
    Set-Content -Path $LITELLM_CONFIG -Value $yaml -Encoding UTF8
  } finally {
    Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
  }
  Ok "Generated LiteLLM config from /v1/models"
}

function Cleanup-StalePids {
  Get-ChildItem -Path $INSTANCES_DIR -Filter "proxy-*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
    $parts = (Get-Content $_.FullName -Raw).Trim().Split(":")
    if ($parts.Length -lt 1) { return }
    $procId = [int]$parts[0]
    if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
      Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
  }
}

function Test-PortInUse([int]$port) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect("127.0.0.1", $port, $null, $null)
    $connected = $async.AsyncWaitHandle.WaitOne(150)
    if (-not $connected) { return $false }
    $client.EndConnect($async)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Find-AvailablePort {
  Cleanup-StalePids
  for ($port = $PORT_MIN; $port -le $PORT_MAX; $port++) {
    $pidFile = Join-Path $INSTANCES_DIR "proxy-$port.pid"
    if ((-not (Test-PortInUse $port)) -and (-not (Test-Path $pidFile))) {
      return $port
    }
  }
  Die "No available ports in range $PORT_MIN-$PORT_MAX. Run: claude-connect-do stop-all"
}

function Start-Proxy([int]$port, [string]$apiKey) {
  $logOut = Join-Path $LOGS_DIR "proxy-$port.log"
  $logErr = Join-Path $LOGS_DIR "proxy-$port.err.log"

  $litellmMode = Resolve-LiteLLM
  if (-not $litellmMode) {
    Die "LiteLLM not found. Run: claude-connect-do setup"
  }

  $env:DO_GRADIENT_API_KEY = $apiKey
  $env:PYTHONUTF8 = "1"
  $env:PYTHONIOENCODING = "utf-8"
  $env:LC_ALL = "C.UTF-8"
  if ($litellmMode -eq "wrapper") {
    $venvPy = Join-Path $VENV_DIR "Scripts/python.exe"
    $proxyArgs = @($LITELLM_WRAPPER, "--config", $LITELLM_CONFIG, "--host", "127.0.0.1", "--port", "$port")
    $p = Start-Process -FilePath $venvPy -ArgumentList $proxyArgs -RedirectStandardOutput $logOut -RedirectStandardError $logErr -PassThru
  } else {
    $proxyArgs = @("--config", $LITELLM_CONFIG, "--host", "127.0.0.1", "--port", "$port")
    $p = Start-Process -FilePath $litellmMode -ArgumentList $proxyArgs -RedirectStandardOutput $logOut -RedirectStandardError $logErr -PassThru
  }

  $script:ProxyProcess = $p
  $script:ProxyPort = $port

  $pidFile = Join-Path $INSTANCES_DIR "proxy-$port.pid"
  $startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  "{0}:{1}:{2}:{3}" -f $p.Id, $port, $PID, $startedAt | Set-Content -Path $pidFile -Encoding UTF8
}

function Wait-ForProxy([int]$port) {
  $url = "http://127.0.0.1:$port/health/readiness"
  Info "Waiting for LiteLLM proxy on port $port..."

  for ($i = 0; $i -lt $HEALTH_TIMEOUT; $i++) {
    try {
      Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 2 | Out-Null
      Ok "Proxy ready on port $port"
      return
    } catch {
    }

    if ($script:ProxyProcess -and $script:ProxyProcess.HasExited) {
      Warn "Proxy exited unexpectedly. Log output:"
      $logOut = Join-Path $LOGS_DIR "proxy-$port.log"
      $logErr = Join-Path $LOGS_DIR "proxy-$port.err.log"
      if (Test-Path $logOut) { Get-Content $logOut -Tail 30 }
      if (Test-Path $logErr) { Get-Content $logErr -Tail 30 }
      Die "LiteLLM proxy failed to start"
    }

    Start-Sleep -Seconds 1
  }

  Die "Proxy health check timed out after ${HEALTH_TIMEOUT}s"
}

function Cleanup {
  if ($script:ProxyProcess) {
    try {
      if (-not $script:ProxyProcess.HasExited) {
        $script:ProxyProcess.CloseMainWindow() | Out-Null
        Start-Sleep -Seconds 1
      }
      if (-not $script:ProxyProcess.HasExited) {
        Stop-Process -Id $script:ProxyProcess.Id -Force -ErrorAction SilentlyContinue
      }
    } catch {
    }
  }

  if ($script:ProxyPort) {
    $pidFile = Join-Path $INSTANCES_DIR "proxy-$($script:ProxyPort).pid"
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  }
}

function Cmd-Install {
  New-Item -ItemType Directory -Path $LOCAL_BIN_DIR -Force | Out-Null
  $target = Join-Path $LOCAL_BIN_DIR "claude-connect-do.cmd"
  $src = Get-CurrentScriptPath

  @(
    "@echo off"
    "powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$src`" %*"
  ) | Set-Content -Path $target -Encoding ASCII

  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $userPath) { $userPath = "" }

  $pathItems = $userPath.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)
  if ($pathItems -notcontains $LOCAL_BIN_DIR) {
    $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $LOCAL_BIN_DIR } else { "$userPath;$LOCAL_BIN_DIR" }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Ok "Updated user PATH with $LOCAL_BIN_DIR"
  } else {
    Info "User PATH already contains $LOCAL_BIN_DIR"
  }

  if (-not $env:Path.Split(";") -contains $LOCAL_BIN_DIR) {
    $env:Path = "$LOCAL_BIN_DIR;$env:Path"
  }

  Ok "Installed claude-connect-do at $target"
  Info "Open a new terminal, or run: `$env:Path = '$LOCAL_BIN_DIR;' + `$env:Path"
}

function Cmd-Doctor {
  $issues = 0
  Info "claude-connect-do doctor v$VERSION"
  Write-Host ""

  if (Get-Command node -ErrorAction SilentlyContinue) {
    Ok "node: $(node -v)"
  } else {
    Show-NodeInstallHelp
    $issues++
  }

  if (Get-Command npm -ErrorAction SilentlyContinue) {
    Ok "npm: $(npm -v)"
  } else {
    Warn "npm not found"
    $issues++
  }

  if (Get-Command python -ErrorAction SilentlyContinue) {
    Ok "python: $(python --version 2>$null)"
    try {
      python -c "import venv" *> $null
      Ok "python venv module: available"
    } catch {
      Warn "python venv module is missing"
      Show-PythonInstallHelp
      $issues++
    }
  } else {
    Show-PythonInstallHelp
    $issues++
  }

  if (Get-Command claude -ErrorAction SilentlyContinue) {
    $ver = "installed"
    try { $ver = (claude --version 2>$null) } catch { }
    Ok "claude: $ver"
  } else {
    Show-ClaudeInstallHelp
    $issues++
  }

  if (Get-Command claude-connect-do -ErrorAction SilentlyContinue) {
    Ok "claude-connect-do on PATH: $((Get-Command claude-connect-do).Source)"
  } else {
    Warn "claude-connect-do is not on PATH. Run: claude-connect-do install"
    $issues++
  }

  $cfg = Load-Config
  if ($cfg.ContainsKey("DO_GRADIENT_API_KEY") -and -not [string]::IsNullOrWhiteSpace($cfg["DO_GRADIENT_API_KEY"])) {
    Ok "DO API key: configured"
  } else {
    Warn "DO API key is missing. Run: claude-connect-do setup"
    $issues++
  }

  $venvPy = Join-Path $VENV_DIR "Scripts/python.exe"
  if (Test-Path $venvPy) {
    try {
      & $venvPy -c "import litellm" *> $null
      Ok "LiteLLM venv: healthy"
    } catch {
      Warn "LiteLLM venv exists but import failed"
      Warn "Fix: Remove-Item -Recurse -Force $VENV_DIR; claude-connect-do setup"
      $issues++
    }
  } else {
    Warn "LiteLLM venv not created yet. Run: claude-connect-do setup"
    $issues++
  }

  Write-Host ""
  if ($issues -eq 0) {
    Ok "Doctor check passed. Setup looks good."
    return
  }

  Warn "Doctor found $issues issue(s). Fix the items above and re-run: claude-connect-do doctor"
  exit 1
}

function Cmd-Setup {
  Ensure-Dirs
  Info "claude-connect-do setup v$VERSION"
  Write-Host ""

  $cfg = Load-Config
  $current = if ($cfg.ContainsKey("DO_GRADIENT_API_KEY")) { $cfg["DO_GRADIENT_API_KEY"] } else { "" }

  if (-not [string]::IsNullOrWhiteSpace($current)) {
    $masked = if ($current.Length -gt 12) { $current.Substring(0, 8) + "..." + $current.Substring($current.Length - 4) } else { "(set)" }
    Write-Host "Current API key: $masked"
    $inputKey = Read-Host "Enter new DO Gradient AI API key (or press Enter to keep current)"
  } else {
    $inputKey = Read-Host "Enter your DigitalOcean Gradient AI API key"
  }

  if ([string]::IsNullOrWhiteSpace($inputKey)) {
    if ([string]::IsNullOrWhiteSpace($current)) {
      Die "API key is required"
    }
    $inputKey = $current
  }

  Save-Config $inputKey
  Ok "Config saved to $CONFIG_FILE"

  Info "First run installs LiteLLM proxy dependencies one time and may take a few minutes."
  Ensure-LiteLLM
  Bootstrap-ClaudeAuth
  Info "Discovering available models..."
  Discover-Models -Force
  Ok "Setup complete! Run 'claude-connect-do' to start a Claude session via DO."
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Show-NodeInstallHelp
  }
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Show-ClaudeInstallHelp
    Warn "Install Claude Code CLI, then run: claude-connect-do"
  }
}

function Cmd-Status {
  Ensure-Dirs
  Cleanup-StalePids

  $files = Get-ChildItem -Path $INSTANCES_DIR -Filter "proxy-*.pid" -ErrorAction SilentlyContinue
  if (-not $files) {
    Info "No running claude-connect-do instances"
    return
  }

  $count = 0
  foreach ($f in $files) {
    $parts = (Get-Content $f.FullName -Raw).Trim().Split(":")
    if ($parts.Length -lt 4) { continue }
    $procId = $parts[0]
    $port = $parts[1]
    $parent = $parts[2]
    $startTs = [long]$parts[3]
    $nowTs = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $elapsed = $nowTs - $startTs
    $mins = [int]($elapsed / 60)
    $secs = [int]($elapsed % 60)
    Write-Host ("  PID {0,-8}  Port {1,-6}  Parent {2,-8}  Uptime {3}m{4}s" -f $procId, $port, $parent, $mins, $secs)
    $count++
  }

  if ($count -eq 0) {
    Info "No running claude-connect-do instances"
  } else {
    Info "$count instance(s) running"
  }
}

function Cmd-StopAll {
  Ensure-Dirs
  $stopped = 0
  Get-ChildItem -Path $INSTANCES_DIR -Filter "proxy-*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
    $parts = (Get-Content $_.FullName -Raw).Trim().Split(":")
    if ($parts.Length -gt 0) {
      $procId = [int]$parts[0]
      $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
      if ($p) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        $stopped++
      }
    }
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
  }

  if ($stopped -eq 0) {
    Info "No running instances to stop"
  } else {
    Ok "Stopped $stopped instance(s)"
  }
}

function Cmd-Models {
  Ensure-Dirs
  if (-not (Test-Path $MODELS_CACHE)) {
    Info "No cached models. Running discovery..."
    Discover-Models -Force
  }

  $py = @'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

do_models = sorted(m["id"] for m in data.get("data", []) if "claude" in m["id"].lower())

def primary_cc_name(do_id):
    base = re.sub(r'^anthropic-', '', do_id)
    return base.replace('.', '-')

print()
print(f"{'DO Gradient Model':<40}  ->  {'Claude Code Model'}")
print(f"{'-' * 40}     {'-' * 34}")
for do_id in do_models:
    cc = primary_cc_name(do_id)
    print(f"{do_id:<40}  ->  {cc}")
'@

  $py | python - $MODELS_CACHE
  Write-Host ""

  if (Test-Path $MODELS_CACHE) {
    $cacheTime = (Get-Item $MODELS_CACHE).LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
    Info "Cache last updated: $cacheTime"
  }
  Info "Run 'claude-connect-do setup' to refresh"
}

function Cmd-Version {
  Write-Host "claude-connect-do v$VERSION"
}

function Cmd-Help {
@"
claude-connect-do v$VERSION - Claude Code via DigitalOcean Gradient AI

Usage:
  claude-connect-do                    Start interactive Claude session via DO
  claude-connect-do <claude args>      Pass arguments to claude (e.g. claude-connect-do -p "hello")
  claude-connect-do install            Install claude-connect-do to ~/bin and configure user PATH
  claude-connect-do setup              Configure API key and discover models
  claude-connect-do doctor             Validate dependencies and print fix commands
  claude-connect-do status             Show running proxy instances
  claude-connect-do stop-all           Kill all running proxy instances
  claude-connect-do models             Show discovered model mappings
  claude-connect-do version            Show version
  claude-connect-do help               Show this help

Examples:
  claude-connect-do install
  claude-connect-do doctor
  claude-connect-do setup
  claude-connect-do
  claude-connect-do --model claude-sonnet-4-6 -p "hello"
"@ | Write-Host
}

function Main {
  Ensure-Dirs

  if ($args.Count -gt 0) {
    switch ($args[0]) {
      "install" { Cmd-Install; return }
      "setup" { Cmd-Setup; return }
      "doctor" { Cmd-Doctor; return }
      "status" { Cmd-Status; return }
      "stop-all" { Cmd-StopAll; return }
      "models" { Cmd-Models; return }
      "version" { Cmd-Version; return }
      "help" { Cmd-Help; return }
      "--help" { Cmd-Help; return }
      "-h" { Cmd-Help; return }
    }
  }

  $cfg = Load-Config
  $apiKey = if ($cfg.ContainsKey("DO_GRADIENT_API_KEY")) { $cfg["DO_GRADIENT_API_KEY"] } else { "" }
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Info "First-time setup required"
    Cmd-Setup
    $cfg = Load-Config
    $apiKey = if ($cfg.ContainsKey("DO_GRADIENT_API_KEY")) { $cfg["DO_GRADIENT_API_KEY"] } else { "" }
  }

  Check-Deps
  Discover-Models
  Generate-LiteLLMConfig

  $venvPy = Join-Path $VENV_DIR "Scripts/python.exe"
  if (Test-Path $venvPy) {
    Write-LiteLLMWrapper
  }

  $port = Find-AvailablePort

  try {
    Start-Proxy -port $port -apiKey $apiKey
    Wait-ForProxy -port $port

    Info "Launching Claude Code via DO Gradient AI (port $port)..."
    $env:ANTHROPIC_BASE_URL = "http://127.0.0.1:$port"
    $env:ANTHROPIC_AUTH_TOKEN = $PROXY_MASTER_KEY
    $env:DO_GRADIENT_API_KEY = $apiKey

    & claude @args
    exit $LASTEXITCODE
  } finally {
    Cleanup
  }
}

Main @args


