# OpenClaw Dreaming setup

One-command setup for OpenClaw 2026.5.19 Dreaming on CPU-only Alibaba Cloud
servers. The default path uses local Ollama embeddings, so no online embedding
API key is required.

## Recommended run

```bash
curl -fsSL https://raw.githubusercontent.com/xinchengai/dream/main/tools/openclaw_enable_dreaming.sh | bash -s -- --install-ollama
```

The script is idempotent and can be run again. It backs up existing config before
writing changes.

## What it does

- Installs and starts Ollama when `--install-ollama` is used.
- Tunes Ollama for CPU-only servers:
  - `OLLAMA_HOST=127.0.0.1:11434`
  - `OLLAMA_NUM_PARALLEL=1`
  - `OLLAMA_MAX_LOADED_MODELS=1`
  - `OLLAMA_KEEP_ALIVE=10m`
  - `OLLAMA_LOAD_TIMEOUT=10m`
  - `OLLAMA_MAX_QUEUE=64`
- Pulls `nomic-embed-text` only when missing.
- Warms up the embedding endpoint.
- Enables OpenClaw Dreaming:
  - `plugins.entries.memory-core.config.dreaming.enabled = true`
  - `plugins.entries.memory-core.config.dreaming.frequency = "0 3 * * *"`
- Configures memory search:
  - `provider = "ollama"`
  - `model = "nomic-embed-text"`
  - `sync.embeddingBatchTimeoutSeconds = 600`
- Restarts OpenClaw when it can detect systemd, pm2, or Docker.
- Prints the final manual check command:
  `openclaw memory status --deep --agent main`.

## Useful options

Skip CPU tuning:

```bash
./tools/openclaw_enable_dreaming.sh --no-cpu-tune
```

Use a custom embedding timeout:

```bash
./tools/openclaw_enable_dreaming.sh --embedding-timeout 900
```

Force a known OpenClaw systemd service:

```bash
./tools/openclaw_enable_dreaming.sh --service-name your-openclaw.service
```

Dry run without writing config:

```bash
./tools/openclaw_enable_dreaming.sh --dry-run --skip-index --no-pull-ollama
```

Run the OpenClaw check inside the script:

```bash
./tools/openclaw_enable_dreaming.sh --run-check
```

## Expected success

The script should end with:

```text
DONE: Config was written.
Run this check next:
  openclaw memory status --deep --agent main
```

Then run:

```bash
openclaw memory status --deep --agent main
```

Expected status:

```text
Provider: ollama
Model: nomic-embed-text
Embeddings: ready
Semantic vectors: ready
Dreaming: 0 3 * * *
```
