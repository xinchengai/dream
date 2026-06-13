#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
LOG_DIR="${OPENCLAW_LOG_DIR:-$HOME/.openclaw/logs}"

PROVIDER="ollama"
MODEL=""
BASE_URL=""
API_KEY=""
WRITE_API_KEY=1
FREQUENCY="${OPENCLAW_DREAMING_FREQUENCY:-0 3 * * *}"
DREAM_MODEL="${OPENCLAW_DREAMING_MODEL:-}"

DRY_RUN=0
SKIP_INDEX=0
PULL_OLLAMA=1
INSTALL_OLLAMA=0
RESTART_OPENCLAW=1
SERVICE_NAME="${OPENCLAW_SERVICE_NAME:-}"
RESTART_METHOD="auto"
CPU_TUNE=1
EMBEDDING_TIMEOUT_SECONDS="${OPENCLAW_EMBEDDING_TIMEOUT_SECONDS:-600}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OPENCLAW_RESTART_CONFIRMED=0
VALIDATION_STATUS=""

usage() {
  cat <<'USAGE'
Usage:
  tools/openclaw_enable_dreaming.sh [options]

What it does:
  - Installs/starts Ollama when requested.
  - Tunes Ollama for CPU-only servers by default.
  - Backs up ~/.openclaw/openclaw.json if it exists.
  - Enables OpenClaw Dreaming.
  - Configures local Ollama embeddings.
  - Restarts OpenClaw when possible.
  - Indexes and validates memory search readiness.

Recommended Alibaba Cloud CPU-only run:
  tools/openclaw_enable_dreaming.sh --install-ollama

Provider options:
  --provider dashscope  Use Alibaba Cloud Model Studio OpenAI-compatible embeddings.
  --provider openai     Use OpenAI embeddings.
  --provider ollama     Use local Ollama embeddings.

Options:
  --model MODEL         Embedding model name.
                       dashscope default: text-embedding-v4
                       openai default: text-embedding-3-small
                       ollama default: nomic-embed-text
  --api-key KEY         API key to write into openclaw.json.
                       Prefer env vars when possible:
                       DASHSCOPE_API_KEY or OPENAI_API_KEY.
  --no-write-api-key    Do not write the API key into openclaw.json.
  --base-url URL        Custom compatible base URL.
  --frequency CRON      Dreaming cron frequency. Default: "0 3 * * *".
  --dream-model MODEL   Optional Dream Diary model override.
  --config PATH         Config path. Default: ~/.openclaw/openclaw.json.
  --workspace PATH      Workspace path. Default: ~/.openclaw/workspace.
  --install-ollama      Install Ollama on Linux when missing.
  --pull-ollama         Pull the Ollama embedding model. Default for ollama.
  --no-pull-ollama      Skip model pull.
  --cpu-only            Tune Ollama/OpenClaw for CPU-only embedding. Default.
  --no-cpu-tune         Skip CPU-only tuning.
  --embedding-timeout N OpenClaw local embedding timeout seconds. Default: 600.
  --service-name NAME   OpenClaw systemd service name. Auto-detected by default.
  --restart-method M    Restart method: auto, systemd, pm2, docker, none.
  --no-restart          Do not restart OpenClaw after writing config.
  --skip-index          Do not run OpenClaw memory index/status validation.
  --dry-run             Print the updated config without writing it.
  -h, --help            Show this help.
USAGE
}

run_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "sudo is not available; cannot run: $*" >&2
    return 1
  fi
}

systemctl_cmd() {
  command -v systemctl >/dev/null 2>&1 || return 127
  systemctl "$@"
}

write_root_file() {
  local path="$1"
  local content="$2"
  if [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' "$content" > "$path"
  elif command -v sudo >/dev/null 2>&1; then
    printf '%s\n' "$content" | sudo tee "$path" >/dev/null
  else
    echo "sudo is not available; cannot write $path" >&2
    return 1
  fi
}

service_loaded() {
  local service="$1"
  [[ "$(systemctl show "$service" --property=LoadState --value 2>/dev/null || true)" == "loaded" ]]
}

wait_for_ollama() {
  local attempts="${1:-30}"
  local delay="${2:-1}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS --max-time 3 "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

ensure_ollama_background() {
  mkdir -p "$LOG_DIR"
  if pgrep -af 'ollama serve' >/dev/null 2>&1; then
    return 0
  fi
  echo "Starting Ollama in background; log: $LOG_DIR/ollama.log"
  nohup ollama serve >>"$LOG_DIR/ollama.log" 2>&1 &
  sleep 2
}

tune_ollama_cpu() {
  [[ "$PROVIDER" == "ollama" && "$CPU_TUNE" -eq 1 ]] || return 0

  echo
  echo "Applying CPU-only Ollama tuning..."

  if command -v systemctl >/dev/null 2>&1 && service_loaded "ollama.service"; then
    local override_dir="/etc/systemd/system/ollama.service.d"
    local override_file="$override_dir/openclaw-cpu.conf"
    local override_content
    override_content='[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=10m"
Environment="OLLAMA_LOAD_TIMEOUT=10m"
Environment="OLLAMA_MAX_QUEUE=64"'

    run_sudo mkdir -p "$override_dir"
    write_root_file "$override_file" "$override_content"
    run_sudo systemctl daemon-reload
    run_sudo systemctl enable --now ollama
    run_sudo systemctl restart ollama
    wait_for_ollama 45 1 || echo "Warning: Ollama API did not respond after systemd restart."
    return 0
  fi

  if command -v ollama >/dev/null 2>&1; then
    export OLLAMA_HOST="127.0.0.1:11434"
    export OLLAMA_NUM_PARALLEL="1"
    export OLLAMA_MAX_LOADED_MODELS="1"
    export OLLAMA_KEEP_ALIVE="10m"
    export OLLAMA_LOAD_TIMEOUT="10m"
    export OLLAMA_MAX_QUEUE="64"
    ensure_ollama_background
    wait_for_ollama 30 1 || echo "Warning: Ollama API did not respond after background start."
  fi
}

install_or_start_ollama() {
  [[ "$PROVIDER" == "ollama" ]] || return 0

  if ! command -v ollama >/dev/null 2>&1; then
    if [[ "$INSTALL_OLLAMA" -ne 1 ]]; then
      echo "Warning: ollama is not installed or not on PATH."
      echo "         Rerun with --install-ollama to install it automatically."
      return 0
    fi
    if [[ "$(uname -s)" != "Linux" ]]; then
      echo "--install-ollama is only supported on Linux by this script." >&2
      exit 1
    fi
    echo "Installing Ollama with the official installer..."
    curl -fsSL https://ollama.com/install.sh | sh
  fi

  if command -v systemctl >/dev/null 2>&1 && service_loaded "ollama.service"; then
    run_sudo systemctl enable --now ollama || true
  elif command -v ollama >/dev/null 2>&1; then
    ensure_ollama_background
  fi

  tune_ollama_cpu
}

ollama_model_present() {
  command -v ollama >/dev/null 2>&1 || return 1
  ollama list </dev/null 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -Fxq "$MODEL"
}

pull_ollama_model() {
  [[ "$PROVIDER" == "ollama" && "$PULL_OLLAMA" -eq 1 ]] || return 0
  command -v ollama >/dev/null 2>&1 || return 0

  if ! wait_for_ollama 30 1; then
    echo "Warning: Ollama service is not responding at $OLLAMA_URL."
    echo "         The script will still write OpenClaw config."
    return 0
  fi

  if ollama_model_present; then
    echo "Ollama model already present: $MODEL"
  else
    ollama pull "$MODEL" </dev/null
  fi
}

warm_up_ollama_embedding() {
  [[ "$PROVIDER" == "ollama" ]] || return 0
  wait_for_ollama 10 1 || return 0

  echo "Warming up Ollama embedding model..."
  local embed_payload embeddings_payload
  embed_payload="$(printf '{"model":"%s","input":"openclaw memory warmup"}' "$MODEL")"
  embeddings_payload="$(printf '{"model":"%s","prompt":"openclaw memory warmup"}' "$MODEL")"

  if curl -fsS --max-time 120 \
    -H 'Content-Type: application/json' \
    -d "$embed_payload" \
    "$OLLAMA_URL/api/embed" >/dev/null 2>&1; then
    return 0
  fi

  curl -fsS --max-time 120 \
    -H 'Content-Type: application/json' \
    -d "$embeddings_payload" \
    "$OLLAMA_URL/api/embeddings" >/dev/null 2>&1 || echo "Warning: Ollama embedding warm-up failed."
}

detect_service_from_process() {
  [[ -d /proc ]] || return 1

  local pid unit
  while read -r pid _; do
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || continue
    [[ -r "/proc/$pid/cgroup" ]] || continue
    unit="$(grep -Eo '[A-Za-z0-9_.@:-]*openclaw[A-Za-z0-9_.@:-]*\.service' "/proc/$pid/cgroup" | head -n 1 || true)"
    if [[ -n "$unit" ]] && service_loaded "$unit"; then
      printf '%s\n' "$unit"
      return 0
    fi
  done < <(pgrep -af 'openclaw|openclaw-gateway' 2>/dev/null || true)

  return 1
}

detect_openclaw_service() {
  if [[ -n "$SERVICE_NAME" ]]; then
    if service_loaded "$SERVICE_NAME"; then
      printf '%s\n' "$SERVICE_NAME"
      return 0
    fi
    echo "Warning: requested service is not loaded: $SERVICE_NAME"
    return 1
  fi

  command -v systemctl >/dev/null 2>&1 || return 1

  local candidate
  for candidate in openclaw.service openclaw-gateway.service gateway.service; do
    if service_loaded "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  local discovered
  discovered="$(
    {
      systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}'
      systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}'
    } | grep -Ei '(^|[-_.@])(openclaw|openclaw-gateway)([-_.@]|$)' | head -n 1 || true
  )"
  if [[ -n "$discovered" ]] && service_loaded "$discovered"; then
    printf '%s\n' "$discovered"
    return 0
  fi

  detect_service_from_process
}

restart_openclaw_systemd() {
  command -v systemctl >/dev/null 2>&1 || return 1

  local service
  service="$(detect_openclaw_service || true)"
  [[ -n "$service" ]] || return 1

  echo
  echo "Restarting OpenClaw service: $service"
  if run_sudo systemctl restart "$service"; then
    sleep 2
    if systemctl_cmd is-active --quiet "$service"; then
      echo "OpenClaw service is active: $service"
      OPENCLAW_RESTART_CONFIRMED=1
    else
      echo "Warning: $service restarted but is not active. Check: systemctl status $service"
    fi
    return 0
  fi

  echo "Warning: failed to restart $service. Check permissions or service name."
  return 1
}

restart_openclaw_pm2() {
  command -v pm2 >/dev/null 2>&1 || return 1

  local ids pm2_json
  pm2_json="$(pm2 jlist 2>/dev/null || true)"
  ids="$(PM2_JSON="$pm2_json" node <<'NODE' || true
try {
  const apps = JSON.parse(process.env.PM2_JSON || "[]");
  const matches = apps.filter((app) => {
    const name = String(app.name || "");
    const script = String(app.pm2_env?.pm_exec_path || "");
    const args = Array.isArray(app.pm2_env?.args) ? app.pm2_env.args.join(" ") : String(app.pm2_env?.args || "");
    return /openclaw|gateway/i.test(`${name} ${script} ${args}`);
  });
  process.stdout.write(matches.map((app) => String(app.pm_id)).join(" "));
} catch {}
NODE
)"

  [[ -n "$ids" ]] || return 1

  echo
  echo "Restarting OpenClaw pm2 app(s): $ids"
  pm2 restart $ids </dev/null
  OPENCLAW_RESTART_CONFIRMED=1
  return 0
}

restart_openclaw_docker() {
  command -v docker >/dev/null 2>&1 || return 1

  local containers
  containers="$(docker ps --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null | awk 'tolower($0) ~ /openclaw|gateway/ { print $1 }' | tr '\n' ' ' || true)"
  [[ -n "$containers" ]] || return 1

  echo
  echo "Restarting OpenClaw docker container(s): $containers"
  docker restart $containers </dev/null
  OPENCLAW_RESTART_CONFIRMED=1
  return 0
}

restart_openclaw() {
  [[ "$RESTART_OPENCLAW" -eq 1 ]] || {
    echo "Skipped OpenClaw restart."
    return 0
  }

  case "$RESTART_METHOD" in
    auto|systemd|pm2|docker|none) ;;
    *)
      echo "Warning: unsupported restart method: $RESTART_METHOD"
      echo "         Supported: auto, systemd, pm2, docker, none"
      return 0
      ;;
  esac

  [[ "$RESTART_METHOD" != "none" ]] || {
    echo "Skipped OpenClaw restart."
    return 0
  }

  if [[ "$RESTART_METHOD" == "auto" || "$RESTART_METHOD" == "systemd" ]]; then
    restart_openclaw_systemd && return 0
    [[ "$RESTART_METHOD" == "systemd" ]] && return 0
  fi
  if [[ "$RESTART_METHOD" == "auto" || "$RESTART_METHOD" == "pm2" ]]; then
    restart_openclaw_pm2 && return 0
    [[ "$RESTART_METHOD" == "pm2" ]] && return 0
  fi
  if [[ "$RESTART_METHOD" == "auto" || "$RESTART_METHOD" == "docker" ]]; then
    restart_openclaw_docker && return 0
    [[ "$RESTART_METHOD" == "docker" ]] && return 0
  fi

  echo "Warning: could not auto-restart OpenClaw."
  echo "         Tried systemd, pm2, and Docker detection. Config was still written."
  return 0
}

run_openclaw_validation() {
  if [[ "$SKIP_INDEX" -eq 1 || ! -x "$(command -v openclaw 2>/dev/null || true)" ]]; then
    echo
    echo "Skipped OpenClaw index/status checks."
    VALIDATION_STATUS="skipped"
    return 0
  fi

  echo
  echo "Running OpenClaw memory index/status checks..."
  openclaw memory index --force --agent main </dev/null || openclaw memory index --force </dev/null || true

  local status_output status_file
  status_file="$(mktemp)"
  openclaw memory status --deep --agent main >"$status_file" 2>&1 </dev/null || openclaw memory status --deep >"$status_file" 2>&1 </dev/null || true
  status_output="$(cat "$status_file")"
  rm -f "$status_file"
  printf '%s\n' "$status_output"

  if grep -Eq 'Provider:[[:space:]]+ollama' <<<"$status_output" \
    && grep -Eq 'Model:[[:space:]]+nomic-embed-text' <<<"$status_output" \
    && grep -Eq 'Embeddings:[[:space:]]+(ready|available)' <<<"$status_output" \
    && grep -Eq 'Semantic vectors:[[:space:]]+ready' <<<"$status_output" \
    && grep -Eq 'Dreaming:[[:space:]]+' <<<"$status_output"; then
    VALIDATION_STATUS="success"
    return 0
  fi

  VALIDATION_STATUS="failed"
  return 0
}

print_final_status() {
  echo
  if [[ "$VALIDATION_STATUS" == "success" ]]; then
    echo "SUCCESS: OpenClaw Dreaming is configured with Ollama CPU-only embeddings."
    if [[ "$OPENCLAW_RESTART_CONFIRMED" -eq 1 ]]; then
      echo "OpenClaw restart: confirmed."
    else
      echo "OpenClaw restart: not confirmed, but memory validation succeeded."
    fi
  elif [[ "$VALIDATION_STATUS" == "skipped" ]]; then
    echo "DONE: Config was written. Validation was skipped."
  else
    echo "DONE WITH WARNINGS: Config was written, but final validation did not report full readiness."
    echo "Expected: Provider: ollama, Embeddings: ready, Semantic vectors: ready, Dreaming: ..."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="${2:?missing provider}"; shift 2 ;;
    --model) MODEL="${2:?missing model}"; shift 2 ;;
    --api-key) API_KEY="${2:?missing api key}"; shift 2 ;;
    --no-write-api-key) WRITE_API_KEY=0; shift ;;
    --base-url) BASE_URL="${2:?missing base url}"; shift 2 ;;
    --frequency) FREQUENCY="${2:?missing cron frequency}"; shift 2 ;;
    --dream-model) DREAM_MODEL="${2:?missing dream model}"; shift 2 ;;
    --config) CONFIG_PATH="${2:?missing config path}"; shift 2 ;;
    --workspace) WORKSPACE_DIR="${2:?missing workspace path}"; shift 2 ;;
    --install-ollama) INSTALL_OLLAMA=1; shift ;;
    --pull-ollama) PULL_OLLAMA=1; shift ;;
    --no-pull-ollama) PULL_OLLAMA=0; shift ;;
    --cpu-only) CPU_TUNE=1; shift ;;
    --no-cpu-tune) CPU_TUNE=0; shift ;;
    --embedding-timeout) EMBEDDING_TIMEOUT_SECONDS="${2:?missing timeout seconds}"; shift 2 ;;
    --service-name) SERVICE_NAME="${2:?missing service name}"; shift 2 ;;
    --restart-method) RESTART_METHOD="${2:?missing restart method}"; shift 2 ;;
    --no-restart) RESTART_OPENCLAW=0; RESTART_METHOD="none"; shift ;;
    --skip-index) SKIP_INDEX=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$PROVIDER" in
  dashscope)
    MODEL="${MODEL:-text-embedding-v4}"
    BASE_URL="${BASE_URL:-https://dashscope.aliyuncs.com/compatible-mode/v1}"
    API_KEY="${API_KEY:-${DASHSCOPE_API_KEY:-}}"
    ;;
  openai)
    MODEL="${MODEL:-text-embedding-3-small}"
    BASE_URL="${BASE_URL:-}"
    API_KEY="${API_KEY:-${OPENAI_API_KEY:-}}"
    ;;
  ollama)
    MODEL="${MODEL:-nomic-embed-text}"
    BASE_URL="${BASE_URL:-}"
    ;;
  *)
    echo "Unsupported provider: $PROVIDER" >&2
    echo "Supported providers: dashscope, openai, ollama" >&2
    exit 2
    ;;
esac

if ! [[ "$EMBEDDING_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "--embedding-timeout must be a positive integer." >&2
  exit 2
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to safely update openclaw.json." >&2
  exit 1
fi

mkdir -p "$(dirname "$CONFIG_PATH")"
mkdir -p "$WORKSPACE_DIR/memory/.dreams" "$LOG_DIR"

echo "OpenClaw config: $CONFIG_PATH"
echo "OpenClaw workspace: $WORKSPACE_DIR"
echo "Embedding provider: $PROVIDER"
echo "Embedding model: $MODEL"
echo "Dreaming frequency: $FREQUENCY"
echo "CPU tuning: $([[ "$CPU_TUNE" -eq 1 ]] && echo enabled || echo disabled)"

if command -v openclaw >/dev/null 2>&1; then
  echo "Detected OpenClaw:"
  openclaw --version </dev/null || true
else
  echo "openclaw command not found on PATH. The script will still update config."
fi

if [[ "$PROVIDER" == "dashscope" && -z "$API_KEY" ]]; then
  echo "Warning: DASHSCOPE_API_KEY is not set and --api-key was not provided."
fi
if [[ "$PROVIDER" == "openai" && -z "$API_KEY" ]]; then
  echo "Warning: OPENAI_API_KEY is not set and --api-key was not provided."
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  install_or_start_ollama
  pull_ollama_model
  warm_up_ollama_embedding
fi

TMP_OUTPUT="$(mktemp)"
cleanup() {
  rm -f "$TMP_OUTPUT"
}
trap cleanup EXIT

CONFIG_PATH="$CONFIG_PATH" \
PROVIDER="$PROVIDER" \
MODEL="$MODEL" \
BASE_URL="$BASE_URL" \
API_KEY="$API_KEY" \
WRITE_API_KEY="$WRITE_API_KEY" \
FREQUENCY="$FREQUENCY" \
DREAM_MODEL="$DREAM_MODEL" \
CPU_TUNE="$CPU_TUNE" \
EMBEDDING_TIMEOUT_SECONDS="$EMBEDDING_TIMEOUT_SECONDS" \
node >"$TMP_OUTPUT" <<'NODE'
const fs = require("fs");

const configPath = process.env.CONFIG_PATH;
const provider = process.env.PROVIDER;
const model = process.env.MODEL;
const baseUrl = process.env.BASE_URL || "";
const apiKey = process.env.API_KEY || "";
const writeApiKey = process.env.WRITE_API_KEY !== "0";
const frequency = process.env.FREQUENCY || "0 3 * * *";
const dreamModel = process.env.DREAM_MODEL || "";
const cpuTune = process.env.CPU_TUNE === "1";
const embeddingTimeout = Number(process.env.EMBEDDING_TIMEOUT_SECONDS || 600);

function stripJsonComments(input) {
  let out = "";
  let inString = false;
  let quote = "";
  let escape = false;
  for (let i = 0; i < input.length; i++) {
    const ch = input[i];
    const next = input[i + 1];
    if (inString) {
      out += ch;
      if (escape) escape = false;
      else if (ch === "\\") escape = true;
      else if (ch === quote) inString = false;
      continue;
    }
    if (ch === '"' || ch === "'") {
      inString = true;
      quote = ch;
      out += ch;
      continue;
    }
    if (ch === "/" && next === "/") {
      while (i < input.length && input[i] !== "\n") i++;
      out += "\n";
      continue;
    }
    if (ch === "/" && next === "*") {
      i += 2;
      while (i < input.length && !(input[i] === "*" && input[i + 1] === "/")) i++;
      i++;
      continue;
    }
    out += ch;
  }
  return out;
}

function parseConfig(text) {
  if (!text.trim()) return {};
  try {
    return JSON.parse(text);
  } catch (_) {
    const noComments = stripJsonComments(text)
      .replace(/([{,]\s*)([A-Za-z_$][\w$-]*)(\s*:)/g, '$1"$2"$3')
      .replace(/,\s*([}\]])/g, "$1")
      .replace(/'([^'\\]*(?:\\.[^'\\]*)*)'/g, (_, body) => JSON.stringify(body.replace(/\\'/g, "'")));
    return JSON.parse(noComments);
  }
}

function ensureObject(parent, key, issues) {
  if (!parent[key] || typeof parent[key] !== "object" || Array.isArray(parent[key])) {
    if (parent[key] !== undefined) issues.push(`Replaced invalid ${key} value with an object.`);
    parent[key] = {};
  }
  return parent[key];
}

let config = {};
let issues = [];

if (fs.existsSync(configPath)) {
  const raw = fs.readFileSync(configPath, "utf8");
  try {
    config = parseConfig(raw);
  } catch (error) {
    console.error(`Failed to parse ${configPath}: ${error.message}`);
    console.error("Refusing to modify the file. Fix JSON/JSON5 syntax first or restore from backup.");
    process.exit(3);
  }
}

const plugins = ensureObject(config, "plugins", issues);
const entries = ensureObject(plugins, "entries", issues);
const memoryCore = ensureObject(entries, "memory-core", issues);
const memoryCoreConfig = ensureObject(memoryCore, "config", issues);
const dreaming = ensureObject(memoryCoreConfig, "dreaming", issues);

if (dreaming.enabled !== true) {
  if (dreaming.enabled !== undefined) issues.push(`dreaming.enabled was ${JSON.stringify(dreaming.enabled)}; set to true.`);
  dreaming.enabled = true;
}
if (typeof dreaming.frequency !== "string" || dreaming.frequency.trim() === "") {
  if (dreaming.frequency !== undefined) issues.push("dreaming.frequency was invalid or empty; replaced it.");
  dreaming.frequency = frequency;
} else if (dreaming.frequency !== frequency && process.env.FREQUENCY) {
  dreaming.frequency = frequency;
}
if (dreamModel) dreaming.model = dreamModel;

if (dreaming.model) {
  const subagent = ensureObject(memoryCore, "subagent", issues);
  if (subagent.allowModelOverride !== true) {
    issues.push("dreaming.model requires memory-core.subagent.allowModelOverride; set it to true.");
    subagent.allowModelOverride = true;
  }
  if (!Array.isArray(subagent.allowedModels)) {
    issues.push("dreaming.model is set but subagent.allowedModels was missing; created it.");
    subagent.allowedModels = [];
  }
  if (!subagent.allowedModels.includes(dreaming.model)) {
    issues.push(`Added ${dreaming.model} to memory-core.subagent.allowedModels.`);
    subagent.allowedModels.push(dreaming.model);
  }
}

const agents = ensureObject(config, "agents", issues);
const defaults = ensureObject(agents, "defaults", issues);
const memorySearch = ensureObject(defaults, "memorySearch", issues);
memorySearch.enabled = true;

if (provider === "dashscope") {
  const models = ensureObject(config, "models", issues);
  const providers = ensureObject(models, "providers", issues);
  const dashscope = ensureObject(providers, "dashscope-embedding", issues);
  dashscope.api = "openai";
  dashscope.baseUrl = baseUrl;
  if (apiKey && writeApiKey) dashscope.apiKey = apiKey;
  if (!Array.isArray(dashscope.models)) dashscope.models = [];
  if (!dashscope.models.some((entry) => entry && entry.id === model)) dashscope.models.push({ id: model });
  memorySearch.provider = "dashscope-embedding";
  memorySearch.model = model;
} else if (provider === "openai") {
  const models = ensureObject(config, "models", issues);
  const providers = ensureObject(models, "providers", issues);
  const openai = ensureObject(providers, "openai", issues);
  openai.api = "openai";
  if (baseUrl) openai.baseUrl = baseUrl;
  if (apiKey && writeApiKey) openai.apiKey = apiKey;
  memorySearch.provider = "openai";
  memorySearch.model = model;
} else if (provider === "ollama") {
  memorySearch.provider = "ollama";
  memorySearch.model = model;
}

memorySearch.query = memorySearch.query && typeof memorySearch.query === "object" && !Array.isArray(memorySearch.query) ? memorySearch.query : {};
memorySearch.query.hybrid = memorySearch.query.hybrid && typeof memorySearch.query.hybrid === "object" && !Array.isArray(memorySearch.query.hybrid) ? memorySearch.query.hybrid : {};
memorySearch.query.hybrid.mmr = Object.assign({}, memorySearch.query.hybrid.mmr, { enabled: true });
memorySearch.query.hybrid.temporalDecay = Object.assign({}, memorySearch.query.hybrid.temporalDecay, { enabled: true });

if (provider === "ollama" && cpuTune) {
  memorySearch.sync = memorySearch.sync && typeof memorySearch.sync === "object" && !Array.isArray(memorySearch.sync) ? memorySearch.sync : {};
  memorySearch.sync.embeddingBatchTimeoutSeconds = embeddingTimeout;
}

process.stdout.write(JSON.stringify({ issues, config }, null, 2));
NODE

ISSUES="$(node -e 'const fs=require("fs"); const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(o.issues.length ? o.issues.map(x=>"- "+x).join("\n") : "- none")' "$TMP_OUTPUT")"
UPDATED_CONFIG="$(node -e 'const fs=require("fs"); const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(JSON.stringify(o.config,null,2))' "$TMP_OUTPUT")"

echo
echo "Config validation/fixes:"
echo "$ISSUES"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "Dry run. Updated config would be:"
  echo "$UPDATED_CONFIG"
  exit 0
fi

if [[ -f "$CONFIG_PATH" ]]; then
  BACKUP_PATH="${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_PATH" "$BACKUP_PATH"
  chmod 600 "$BACKUP_PATH" || true
  echo "Backup written: $BACKUP_PATH"
fi

printf '%s\n' "$UPDATED_CONFIG" > "$CONFIG_PATH"
chmod 600 "$CONFIG_PATH" || true
echo "Updated config written: $CONFIG_PATH"

restart_openclaw
run_openclaw_validation
print_final_status
