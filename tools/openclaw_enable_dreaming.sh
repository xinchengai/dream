#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}"
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

usage() {
  cat <<'USAGE'
Usage:
  tools/openclaw_enable_dreaming.sh [options]

What it does:
  - Backs up ~/.openclaw/openclaw.json if it exists.
  - Creates the OpenClaw memory workspace directories.
  - Enables plugins.entries.memory-core.config.dreaming.
  - Checks and fixes common dreaming.model trust-gate config issues.
  - Configures agents.defaults.memorySearch embedding provider.
  - Restarts OpenClaw when it can identify a systemd service.
  - Optionally runs openclaw memory index/status when openclaw is on PATH.

Recommended local Ollama run:
  tools/openclaw_enable_dreaming.sh

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
                       Make sure the OpenClaw service environment has the key.
  --base-url URL        Custom compatible base URL.
                       dashscope default: https://dashscope.aliyuncs.com/compatible-mode/v1
  --frequency CRON      Dreaming cron frequency. Default: "0 3 * * *".
  --dream-model MODEL   Optional Dream Diary model override.
  --config PATH         Config path. Default: ~/.openclaw/openclaw.json.
  --workspace PATH      Workspace path. Default: ~/.openclaw/workspace.
  --install-ollama      For --provider ollama, install Ollama on Linux if missing.
  --pull-ollama         For --provider ollama, run: ollama pull MODEL. Default for ollama.
  --no-pull-ollama      For --provider ollama, skip model pull.
  --service-name NAME   OpenClaw systemd service name. Auto-detected by default.
  --no-restart          Do not restart OpenClaw service after writing config.
  --skip-index          Do not run openclaw memory index/status.
  --dry-run             Print the updated config without writing it.
  -h, --help            Show this help.
USAGE
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
    --service-name) SERVICE_NAME="${2:?missing service name}"; shift 2 ;;
    --no-restart) RESTART_OPENCLAW=0; shift ;;
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

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to safely update openclaw.json." >&2
  exit 1
fi

mkdir -p "$(dirname "$CONFIG_PATH")"
mkdir -p "$WORKSPACE_DIR/memory/.dreams"

echo "OpenClaw config: $CONFIG_PATH"
echo "OpenClaw workspace: $WORKSPACE_DIR"
echo "Embedding provider: $PROVIDER"
echo "Embedding model: $MODEL"
echo "Dreaming frequency: $FREQUENCY"

if command -v openclaw >/dev/null 2>&1; then
  echo "Detected OpenClaw:"
  openclaw --version || true
else
  echo "openclaw command not found on PATH. The script will still update config."
fi

if [[ "$PROVIDER" == "dashscope" && -z "$API_KEY" ]]; then
  echo "Warning: DASHSCOPE_API_KEY is not set and --api-key was not provided."
  echo "         The script will configure the DashScope provider, but embeddings will not work until an API key is available."
fi

if [[ "$PROVIDER" == "openai" && -z "$API_KEY" ]]; then
  echo "Warning: OPENAI_API_KEY is not set and --api-key was not provided."
  echo "         The script will configure OpenAI, but embeddings will not work until an API key is available."
fi

if [[ "$PROVIDER" == "ollama" ]]; then
  if ! command -v ollama >/dev/null 2>&1; then
    if [[ "$INSTALL_OLLAMA" -eq 1 ]]; then
      if [[ "$(uname -s)" != "Linux" ]]; then
        echo "--install-ollama is only supported on Linux by this script." >&2
        exit 1
      fi
      echo "Installing Ollama with the official installer..."
      curl -fsSL https://ollama.com/install.sh | sh
    else
      echo "Warning: ollama is not installed or not on PATH."
      echo "         Install it first, or rerun this script with --install-ollama on Linux."
    fi
  fi

  if command -v ollama >/dev/null 2>&1 && [[ "$PULL_OLLAMA" -eq 1 ]]; then
    if ! curl -fsS --max-time 3 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
      echo "Warning: Ollama service is not responding at http://127.0.0.1:11434."
      echo "         Start it first, for example: systemctl enable --now ollama"
      echo "         The script will still write OpenClaw config."
    else
      ollama pull "$MODEL"
    fi
  fi
fi

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
  if command -v systemctl >/dev/null 2>&1; then
    systemctl "$@"
  else
    return 127
  fi
}

detect_openclaw_service() {
  if [[ -n "$SERVICE_NAME" ]]; then
    printf '%s\n' "$SERVICE_NAME"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  local candidate
  for candidate in openclaw openclaw-gateway openclaw.service openclaw-gateway.service; do
    if systemctl list-unit-files "${candidate%.service}.service" --no-legend 2>/dev/null | grep -q .; then
      printf '%s\n' "${candidate%.service}.service"
      return 0
    fi
  done

  local discovered
  discovered="$(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^openclaw.*\.service$' | head -n 1 || true)"
  if [[ -n "$discovered" ]]; then
    printf '%s\n' "$discovered"
    return 0
  fi

  return 1
}

restart_openclaw() {
  if [[ "$RESTART_OPENCLAW" -ne 1 ]]; then
    echo "Skipped OpenClaw restart."
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "Warning: systemctl not found; cannot auto-restart OpenClaw."
    echo "         Restart your OpenClaw Gateway/service manually."
    return 0
  fi

  local service
  if ! service="$(detect_openclaw_service)"; then
    echo "Warning: could not auto-detect the OpenClaw systemd service."
    echo "         Rerun with --service-name NAME, or restart OpenClaw manually."
    return 0
  fi

  echo
  echo "Restarting OpenClaw service: $service"
  if run_sudo systemctl restart "$service"; then
    sleep 2
    systemctl_cmd is-active --quiet "$service" \
      && echo "OpenClaw service is active: $service" \
      || echo "Warning: $service restarted but is not active. Check: systemctl status $service"
  else
    echo "Warning: failed to restart $service. Check permissions or service name."
  fi
}

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
node >"$TMP_OUTPUT" <<'NODE'
const fs = require("fs");
const path = require("path");

const configPath = process.env.CONFIG_PATH;
const provider = process.env.PROVIDER;
const model = process.env.MODEL;
const baseUrl = process.env.BASE_URL || "";
const apiKey = process.env.API_KEY || "";
const writeApiKey = process.env.WRITE_API_KEY !== "0";
const frequency = process.env.FREQUENCY || "0 3 * * *";
const dreamModel = process.env.DREAM_MODEL || "";

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
      if (escape) {
        escape = false;
      } else if (ch === "\\") {
        escape = true;
      } else if (ch === quote) {
        inString = false;
      }
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
    if (parent[key] !== undefined) {
      issues.push(`Replaced invalid ${key} value with an object.`);
    }
    parent[key] = {};
  }
  return parent[key];
}

let config = {};
let existed = fs.existsSync(configPath);
let issues = [];

if (existed) {
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

if (memoryCoreConfig.dreaming && (typeof memoryCoreConfig.dreaming !== "object" || Array.isArray(memoryCoreConfig.dreaming))) {
  issues.push("plugins.entries.memory-core.config.dreaming was not an object; replaced it.");
  memoryCoreConfig.dreaming = {};
}

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

if (dreamModel) {
  dreaming.model = dreamModel;
}

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
  if (!dashscope.models.some((entry) => entry && entry.id === model)) {
    dashscope.models.push({ id: model });
  }
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

if (!memorySearch.query || typeof memorySearch.query !== "object" || Array.isArray(memorySearch.query)) {
  memorySearch.query = {};
}
if (!memorySearch.query.hybrid || typeof memorySearch.query.hybrid !== "object" || Array.isArray(memorySearch.query.hybrid)) {
  memorySearch.query.hybrid = {};
}
memorySearch.query.hybrid.mmr = Object.assign({}, memorySearch.query.hybrid.mmr, { enabled: true });
memorySearch.query.hybrid.temporalDecay = Object.assign({}, memorySearch.query.hybrid.temporalDecay, { enabled: true });

const output = {
  issues,
  config,
};
process.stdout.write(JSON.stringify(output, null, 2));
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

if [[ "$SKIP_INDEX" -eq 0 && -x "$(command -v openclaw 2>/dev/null || true)" ]]; then
  echo
  echo "Running OpenClaw memory index/status checks..."
  openclaw memory index --force --agent main || openclaw memory index --force || true
  openclaw memory status --deep --agent main || openclaw memory status --deep || true
else
  echo
  echo "Skipped OpenClaw index/status checks."
fi

cat <<'NEXT'

Next steps:
  1. If auto-restart did not find your service, rerun with: --service-name NAME
  2. Run: openclaw memory status --deep --agent main
  3. If embeddings are still unavailable with Ollama, confirm:
     - ollama list
     - curl http://127.0.0.1:11434/api/version
     - ollama pull nomic-embed-text
NEXT
