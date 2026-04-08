# Logi Build Haptics - shell integration
LOGI_HAP_PORT=43821
LOGI_HAP_PATTERNS_FILE="$HOME/.config/logi-build-haptics/patterns.json"
LOGI_HAP_SETTINGS_FILE="$HOME/.config/logi-build-haptics/settings.json"
LOGI_HAP_RESOURCE_URL="http://127.0.0.1:${LOGI_HAP_PORT}/resource-warning"
LOGI_HAP_BUILD_URL="http://127.0.0.1:${LOGI_HAP_PORT}/build-finished"

: "${LOGI_MONITOR_CPU_ENABLED:=1}"
: "${LOGI_MONITOR_RAM_ENABLED:=1}"
: "${LOGI_MONITOR_CPU_THRESHOLD:=90}"
: "${LOGI_MONITOR_RAM_THRESHOLD:=90}"
: "${LOGI_MONITOR_INTERVAL_SECONDS:=0.5}"
: "${LOGI_MONITOR_WARN_COOLDOWN_SECONDS:=30}"

LOGI_HAP_MONITOR_PID=""

function _logi_hap_load_patterns() {
  LOGI_HAP_PATTERNS=()
  if [[ -f "$LOGI_HAP_PATTERNS_FILE" ]]; then
    while IFS= read -r rx; do
      [[ -n "$rx" ]] && LOGI_HAP_PATTERNS+=("$rx")
    done < <(python3 - <<'PY'
import json, os
p=os.path.expanduser('~/.config/logi-build-haptics/patterns.json')
try:
  data=json.load(open(p))
  for it in data.get('patterns',[]):
    if it.get('enabled') and it.get('regex'):
      print(it['regex'])
except Exception:
  pass
PY
)
  fi
}

function _logi_hap_load_settings() {
  local loaded
  loaded=$(
    LOGI_HAP_SETTINGS_FILE_ENV="$LOGI_HAP_SETTINGS_FILE" python3 - <<'PY'
import json, os

p = os.environ.get("LOGI_HAP_SETTINGS_FILE_ENV", "")
defaults = {
  "cpuEnabled": True,
  "ramEnabled": True,
  "cpuThresholdPercent": 90,
  "ramThresholdPercent": 90,
  "intervalSeconds": 0.5,
  "warnCooldownSeconds": 30,
}
data = defaults.copy()
try:
  if p and os.path.isfile(p):
    parsed = json.load(open(p))
    if isinstance(parsed, dict):
      data.update(parsed)
except Exception:
  pass

cpu_enabled = 1 if bool(data.get("cpuEnabled", True)) else 0
ram_enabled = 1 if bool(data.get("ramEnabled", True)) else 0
cpu_threshold = int(data.get("cpuThresholdPercent", 90))
ram_threshold = int(data.get("ramThresholdPercent", 90))
interval = float(data.get("intervalSeconds", 0.5))
cooldown = int(data.get("warnCooldownSeconds", 30))

print(f"LOGI_MONITOR_CPU_ENABLED={cpu_enabled}")
print(f"LOGI_MONITOR_RAM_ENABLED={ram_enabled}")
print(f"LOGI_MONITOR_CPU_THRESHOLD={cpu_threshold}")
print(f"LOGI_MONITOR_RAM_THRESHOLD={ram_threshold}")
print(f"LOGI_MONITOR_INTERVAL_SECONDS={interval}")
print(f"LOGI_MONITOR_WARN_COOLDOWN_SECONDS={cooldown}")
PY
  )

  if [[ -n "$loaded" ]]; then
    eval "$loaded"
  fi
}

function _logi_hap_now() {
  if [[ -n "${EPOCHSECONDS:-}" ]]; then
    print -r -- "$EPOCHSECONDS"
  else
    date +%s
  fi
}

function _logi_hap_get_cpu_percent() {
  top -l 1 2>/dev/null | awk -F'[:,% ]+' '
    /CPU usage/ {
      user = $3 + 0
      sys  = $5 + 0
      printf "%.0f\n", user + sys
      found = 1
      exit
    }
    END {
      if (!found) print -1
    }'
}

function _logi_hap_get_ram_percent() {
  memory_pressure 2>/dev/null | awk -F'[:%]' '
    /System-wide memory free percentage/ {
      gsub(/[[:space:]]/, "", $2)
      free = $2 + 0
      used = 100 - free
      if (used < 0) used = 0
      if (used > 100) used = 100
      printf "%.0f\n", used
      found = 1
      exit
    }
    END {
      if (!found) print -1
    }'
}

function _logi_hap_post_resource_warning() {
  local metric="$1"
  local usage="$2"
  local threshold="$3"

  LOGI_HAP_WARN_METRIC="$metric" \
  LOGI_HAP_WARN_USAGE="$usage" \
  LOGI_HAP_WARN_THRESHOLD="$threshold" \
  LOGI_HAP_WARN_CMD="$LOGI_HAP_LAST_CMD" \
  LOGI_HAP_WARN_URL="$LOGI_HAP_RESOURCE_URL" \
  python3 - <<'PY' >/dev/null 2>&1
import json, os, urllib.request

url = os.environ.get("LOGI_HAP_WARN_URL", "")
if not url:
  raise SystemExit(0)

payload = {
  "metric": os.environ.get("LOGI_HAP_WARN_METRIC", ""),
  "usagePercent": int(os.environ.get("LOGI_HAP_WARN_USAGE", "0")),
  "thresholdPercent": int(os.environ.get("LOGI_HAP_WARN_THRESHOLD", "0")),
  "cmd": os.environ.get("LOGI_HAP_WARN_CMD", ""),
}
data = json.dumps(payload).encode("utf-8")
req = urllib.request.Request(
  url,
  data=data,
  headers={"Content-Type": "application/json"},
  method="POST",
)
try:
  urllib.request.urlopen(req, timeout=0.2)
except Exception:
  pass
PY
}

function _logi_hap_warn_metric() {
  local metric="$1"
  local usage="$2"
  local threshold="$3"

  if [[ "$metric" == "ram" ]]; then
    print -r -- "ZshDev: you are running out of RAM! (${usage}% used, threshold ${threshold}%)"
  elif [[ "$metric" == "cpu" ]]; then
    print -r -- "ZshDev: CPU usage is very high! (${usage}% used, threshold ${threshold}%)"
  fi

  _logi_hap_post_resource_warning "$metric" "$usage" "$threshold"
}

function _logi_hap_resource_monitor_loop() {
  local last_cpu_warn=0
  local last_ram_warn=0
  local now cpu ram

  while true; do
    now=$(_logi_hap_now)
    if (( LOGI_MONITOR_CPU_ENABLED == 1 )); then
      cpu=$(_logi_hap_get_cpu_percent)
      if (( cpu >= LOGI_MONITOR_CPU_THRESHOLD )); then
        if (( now - last_cpu_warn >= LOGI_MONITOR_WARN_COOLDOWN_SECONDS )); then
          _logi_hap_warn_metric "cpu" "$cpu" "$LOGI_MONITOR_CPU_THRESHOLD"
          last_cpu_warn=$now
        fi
      fi
    fi

    if (( LOGI_MONITOR_RAM_ENABLED == 1 )); then
      ram=$(_logi_hap_get_ram_percent)
      if (( ram >= LOGI_MONITOR_RAM_THRESHOLD )); then
        if (( now - last_ram_warn >= LOGI_MONITOR_WARN_COOLDOWN_SECONDS )); then
          _logi_hap_warn_metric "ram" "$ram" "$LOGI_MONITOR_RAM_THRESHOLD"
          last_ram_warn=$now
        fi
      fi
    fi

    sleep "$LOGI_MONITOR_INTERVAL_SECONDS"
  done
}

function _logi_hap_start_resource_monitor() {
  _logi_hap_stop_resource_monitor
  _logi_hap_resource_monitor_loop &
  LOGI_HAP_MONITOR_PID=$!
}

function _logi_hap_stop_resource_monitor() {
  if [[ -n "${LOGI_HAP_MONITOR_PID:-}" ]] && kill -0 "$LOGI_HAP_MONITOR_PID" 2>/dev/null; then
    kill "$LOGI_HAP_MONITOR_PID" >/dev/null 2>&1
    wait "$LOGI_HAP_MONITOR_PID" >/dev/null 2>&1
  fi
  LOGI_HAP_MONITOR_PID=""
}

function logi_hap_preexec() {
  LOGI_HAP_LAST_CMD="$1"
  LOGI_HAP_MATCHED=0

  # reload every command so toggles apply immediately
  _logi_hap_load_patterns
  _logi_hap_load_settings

  for pat in "${LOGI_HAP_PATTERNS[@]}"; do
    if [[ "$1" =~ $pat ]]; then
      LOGI_HAP_MATCHED=1
      _logi_hap_start_resource_monitor
      break
    fi
  done
}

function logi_hap_precmd() {
local ec=$?
  _logi_hap_stop_resource_monitor

  if [[ "${LOGI_HAP_MATCHED:-0}" -eq 1 ]]; then
    # POST JSON to localhost receiver (silent if receiver isn't running yet)
    LOGI_HAP_LAST_CMD_ENV="$LOGI_HAP_LAST_CMD" LOGI_HAP_LAST_EC_ENV="$ec" LOGI_HAP_BUILD_URL_ENV="$LOGI_HAP_BUILD_URL" python3 - <<'PY' >/dev/null 2>&1
import json, os, urllib.request
cmd = os.environ.get('LOGI_HAP_LAST_CMD_ENV', '')
try:
  ec = int(os.environ.get('LOGI_HAP_LAST_EC_ENV', '0'))
except Exception:
  ec = 0

url = os.environ.get('LOGI_HAP_BUILD_URL_ENV', 'http://127.0.0.1:43821/build-finished')
data = json.dumps({'cmd': cmd, 'exitCode': ec}).encode('utf-8')
req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json'}, method='POST')
try:
  urllib.request.urlopen(req, timeout=0.2)
except Exception:
  pass
PY
  fi

  LOGI_HAP_MATCHED=0
  LOGI_HAP_LAST_CMD=""
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec logi_hap_preexec
add-zsh-hook precmd  logi_hap_precmd
