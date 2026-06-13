# OpenClaw Dreaming setup

This helper is aimed at OpenClaw 5.19 deployments. The default path uses local
Ollama embeddings, so no online embedding API key is required.

## Recommended Ollama run

```bash
cd /path/to/xincheng
./tools/openclaw_enable_dreaming.sh
```

The script writes `~/.openclaw/openclaw.json`, backs up any existing config, and
uses:

- Dreaming: `plugins.entries.memory-core.config.dreaming.enabled = true`
- Schedule: `0 3 * * *`
- Embeddings provider: `ollama`
- Embeddings model: `nomic-embed-text`

If Ollama is not installed on your Linux server, run:

```bash
./tools/openclaw_enable_dreaming.sh --install-ollama
```

If Ollama is already installed but the service is not running:

```bash
sudo systemctl enable --now ollama
```

## Dry run first

```bash
./tools/openclaw_enable_dreaming.sh --dry-run
```

## Useful alternatives

Alibaba Cloud Model Studio / DashScope embeddings:

```bash
DASHSCOPE_API_KEY="sk-your-key" ./tools/openclaw_enable_dreaming.sh --provider dashscope
```

OpenAI embeddings:

```bash
OPENAI_API_KEY="sk-your-key" ./tools/openclaw_enable_dreaming.sh --provider openai
```

Custom schedule:

```bash
./tools/openclaw_enable_dreaming.sh --frequency "0 */6 * * *"
```

## What it checks

- Creates `~/.openclaw/workspace/memory/.dreams`.
- Creates `~/.openclaw/openclaw.json` if missing.
- Parses existing JSON or simple JSON5-style config.
- Backs up existing config to `openclaw.json.bak.YYYYMMDDHHMMSS`.
- Ensures `plugins.entries.memory-core.config.dreaming.enabled` is `true`.
- Ensures a valid `dreaming.frequency`.
- If `dreaming.model` is present, fixes the required subagent trust gate:
  `allowModelOverride: true` and `allowedModels`.
- Enables `agents.defaults.memorySearch`.
- Configures embeddings for DashScope/OpenAI/Ollama.
- Pulls the Ollama embedding model by default when using `--provider ollama`.
- Enables MMR and temporal decay for higher quality retrieval.

## Verify after restart

Restart your OpenClaw Gateway/service, then run:

```bash
openclaw memory index --force --agent main
openclaw memory status --deep --agent main
```

Expected healthy signs:

- `Dreaming:` shows a cron schedule such as `0 3 * * *`
- `Embeddings:` is available
- `Semantic vectors:` is available after indexing
- `Issues:` no longer reports the memory directory missing

If embeddings are still unavailable with Ollama, make sure the Ollama service is
running and the model exists:

```bash
ollama list
curl http://127.0.0.1:11434/api/version
```
