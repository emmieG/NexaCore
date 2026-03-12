<p align="center">
  <img src="nexacore-logo.jpg" alt="NexaCore" width="600"/>
</p>
# NexaCore — Private Local AI Stack

A fully private, fully local AI setup with real-time web search and optional voice input/output. Nothing leaves your machine except SearXNG's outbound searches. No API keys required. No cloud services.

Built and documented through extensive trial and error. The Reddit thread that started it all:
https://www.reddit.com/r/openclaw/comments/1rm5h3c/solved_how_to_use_local_searxng_with_openclaw/

---

## What You Get

- **OpenClaw 2026.3.1** — AI chat interface running locally in your browser
- **Ollama** — runs open source AI models on your own hardware
- **SearXNG** — private self-hosted search engine, no tracking, no API keys
- **Real-time web search** — AI automatically searches for current information on any topic
- **Multiple models** — general use, coding, multimodal, fast and capable options
- **VPN compatible** — split tunneling instructions included
- **Voice add-on** — optional push-to-talk input and spoken responses

---

## Requirements

- Linux (tested on Ubuntu/Linux Mint)
- x86_64 architecture
- At least 16GB RAM (32GB+ recommended)
- Nvidia GPU recommended (4GB+ VRAM) — runs on CPU only but will be slow
- Node.js 22+
- Docker
- npm

---

## Quick Start

```bash
git clone https://github.com/emmieG/NexaCore
cd NexaCore
bash rebuild-v2.sh
```

Then open `http://127.0.0.1:18789` in your browser.

---

## Optional: Voice Add-On

Run after `rebuild-v2.sh` to add push-to-talk voice input and spoken AI responses:

```bash
bash install-voice-v2.sh
```

This installs Whisper.cpp (speech to text), Piper TTS (text to speech), a voice server on port 19999, and a system tray icon. Hold the Super key for 1 second to start recording. Release to transcribe and type. Install the Tampermonkey script (instructions printed at end of install) for AI responses to be read aloud automatically.

---

## What rebuild-v2.sh Does

1. Installs Ollama and pulls all AI models
2. Creates optimized Modelfiles with reduced context windows for faster responses
3. Installs Docker and sets up SearXNG with JSON format enabled
4. Installs OpenClaw 2026.3.1
5. Applies all OpenClaw configuration values
6. Patches the SSRF guard files to allow local network access
7. Sets up workspace files (AGENTS.md, IDENTITY.md)
8. Creates VPN split tunnel desktop entries

Total install time: 30-60 minutes depending on internet speed and hardware.

---

## The Core Problem This Solves

OpenClaw blocks all requests to local/private IP addresses by default via hardcoded SSRF security guards. This means it cannot reach a locally running SearXNG instance even though both are on the same machine.

The fix requires patching JavaScript dist files in the OpenClaw installation. The script handles this automatically and finds the correct filenames since they change between versions.

Full technical details in the Reddit thread linked above.

---

## Why OpenClaw 2026.3.1

This version is pinned deliberately. Newer versions changed the SSRF guard file structure in ways that break the patch. The script disables auto-updates so it stays on 2026.3.1.

---

## Models Included

All chat models are created with `num_ctx 4096` for significantly faster response times on consumer hardware. Response times on a mid-range GPU are typically 1-8 minutes depending on query complexity.

| Model | Use Case | Size |
|-------|----------|------|
| qwen2.5-fast | General use, web search | 4.7GB |
| qwen2.5-coder-fast | Coding, 7b | 4.7GB |
| qwen2.5-coder-fast-3b | Coding, faster | 1.9GB |
| mistral-fast | General, language tasks | 4.4GB |
| phi3-fast | Fast general use | 2.2GB |
| llava-fast | Multimodal, image analysis | 4.7GB |
| deepseek-coder-fast | Coding, 6.7b | 3.8GB |
| gemma3-fast | Google 4b general use | 3.3GB |
| nomic-embed-text | Embeddings for RAG | 274MB |

To switch models:
```bash
openclaw config set agents.defaults.model.primary ollama/MODEL-NAME
systemctl --user restart openclaw-gateway
```

---

## How Web Search Works

The AI uses your local SearXNG instance via the `web_fetch` tool. The `AGENTS.md` workspace file instructs the model to automatically search for any current information without being explicitly asked every time.

The model is instructed to search for everything, base answers exclusively on search result content, compare results across engines and flag disagreements, and include publication dates.

---

## VPN Compatibility

If you run a VPN, it will intercept loopback traffic and break the connection between OpenClaw and SearXNG. The fix is split tunneling — exclude openclaw and ollama from your VPN tunnel.

The challenge on Linux is most VPN clients only show GUI applications in their split tunnel dropdown. The script creates desktop entries for both automatically so they appear in your VPN client's exclusion list.

After running the script, close and reopen your VPN client, then add OpenClaw and Ollama to the exclusion list.

---

## OpenClaw Gateway Service

OpenClaw manages its own user-level systemd service. Do NOT create a system-level service — it will conflict on boot.

```bash
# Correct commands
systemctl --user start openclaw-gateway
systemctl --user stop openclaw-gateway
systemctl --user restart openclaw-gateway
systemctl --user status openclaw-gateway
```

If OpenClaw fails with `uv_cwd` error on boot, add a working directory and startup delay:

```bash
systemctl --user stop openclaw-gateway
sed -i 's/\[Service\]/[Service]\nWorkingDirectory=\/home\/$USER\nExecStartPre=\/bin\/sleep 5/' \
  ~/.config/systemd/user/openclaw-gateway.service
systemctl --user daemon-reload
systemctl --user start openclaw-gateway
```

---

## Customizing the AI

Edit `~/.openclaw/workspace/AGENTS.md` to change how the AI behaves, what it knows about you, and how it handles searches.

Edit `~/.openclaw/workspace/IDENTITY.md` to give the AI a name and personality.

These files persist across conversations.

---

## Troubleshooting

**web_fetch returns blocked errors**
```bash
grep -c 'dangerouslyAllowPrivateNetwork' /usr/lib/node_modules/openclaw/dist/subagent-registry-*.js
# If result is 0, SSRF patch was lost — re-run rebuild-v2.sh
```

**OpenClaw won't start (port conflict)**
```bash
openclaw gateway stop
sudo pkill -f openclaw-gateway
sleep 2
systemctl --user start openclaw-gateway
```

**Model not searching / giving wrong answers**
Start a fresh session with `/new`. Long conversations cause context window bloat.

**SearXNG not responding**
```bash
docker ps | grep searxng
docker restart searxng
```

**Check logs**
```bash
tail -f /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log
```

---

## Security Note

The SSRF guard in OpenClaw exists for a good reason — it prevents malicious content from tricking the AI into making requests to internal network resources. By applying this patch you are disabling that protection for local addresses.

The risk is low if you are the only user of your instance, you are not exposing it to the internet, and you are not fetching content from untrusted sources.

The config key `browser.ssrfPolicy.dangerouslyAllowPrivateNetwork` is an official option in OpenClaw's own codebase. The JavaScript patch was needed because the config key alone was not sufficient.

Use this responsibly.

---

## Contributing

Issues and pull requests welcome. If you find that a newer version of OpenClaw has different SSRF guard filenames, please open an issue with the new filenames and patch commands so the script can be updated.

---

## License

MIT
