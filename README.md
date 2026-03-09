# Local Private AI Stack — OpenClaw + Ollama + SearXNG

A fully private, fully local AI setup that gives you a capable AI assistant with real-time web search. Nothing leaves your machine except SearXNG's outbound searches. No API keys required. No cloud services.

Built and documented through extensive trial and error. The Reddit thread that started it all is here:
https://www.reddit.com/r/openclaw/comments/1rm5h3c/solved_how_to_use_local_searxng_with_openclaw/

---

## What You Get

- **OpenClaw** — AI chat interface running locally in your browser
- **Ollama** — runs open source AI models on your own hardware
- **SearXNG** — private self-hosted search engine, no tracking, no API keys
- **Real-time web search** — the AI automatically searches for current information on any topic
- **Multiple models** — general use, coding, multimodal, fast and capable options
- **VPN compatible** — instructions for making it work with your VPN via split tunneling

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
git clone https://github.com/emmieG/local-ai-stack
cd local-ai-stack
bash rebuild.sh
```

Then open http://127.0.0.1:18789 in your browser.

---

## What the Script Does

The rebuild.sh script handles everything in order:

1. Installs Ollama and pulls the AI models
2. Creates optimized Modelfiles with reduced context windows for faster responses
3. Installs Docker and sets up SearXNG with JSON format enabled
4. Installs OpenClaw 2026.3.1 and creates the systemd service
5. Applies all configuration values
6. Patches the SSRF guard files to allow local network access
7. Creates the workspace files (AGENTS.md, IDENTITY.md)

Total install time: 30-60 minutes depending on your internet speed and hardware.

---

## The Core Problem This Solves

OpenClaw blocks all requests to local/private IP addresses by default via hardcoded SSRF security guards. This means it cannot reach a locally running SearXNG instance even though both are on the same machine.

The fix requires patching JavaScript dist files in the OpenClaw installation. The script handles this automatically and also finds the correct filenames since they change between versions.

Full technical details and the manual patch commands are in the Reddit thread linked above.

---

## Why OpenClaw 2026.3.1

This version is pinned deliberately. Newer versions changed the SSRF guard file structure in ways that break the patch. The script disables auto-updates so it stays on 2026.3.1.

If you want to try a newer version you will need to re-identify the SSRF guard files and re-apply the patches manually. The Reddit thread documents this process.

---

## Models Included

The script installs and optimizes the following models:

| Model | Use Case | Size |
|-------|----------|------|
| qwen2.5-fast | General use, web search, current events | 4.7GB |
| qwen2.5-coder-fast | Coding tasks, 7b | 4.7GB |
| qwen2.5-coder-fast-3b | Coding tasks, faster | 1.9GB |
| mistral-fast | General use, language tasks | 4.4GB |
| phi3-fast | Fast general use, Microsoft 3.8b | 2.2GB |
| llava-fast | Multimodal, can analyze images | 4.7GB |
| deepseek-coder-fast | Coding, 6.7b | 3.8GB |
| gemma3-fast | Google 4b general use | 3.3GB |
| nomic-embed-text | Embeddings for document search (RAG) | 274MB |

All chat models are created with a reduced context window (num_ctx 4096) for significantly faster response times on consumer hardware. Response times on a mid-range GPU are typically 1-8 minutes depending on query complexity.

To switch models:
```bash
openclaw config set agents.defaults.model.primary ollama/MODEL-NAME
sudo systemctl restart openclaw
```

---

## How Web Search Works

The AI uses your local SearXNG instance via the web_fetch tool. The AGENTS.md workspace file tells the model to automatically search for any current information — news, prices, people, events, anything — without you having to explicitly ask it to search every time.

Search URL pattern used internally:
```
http://127.0.0.1:8081/search?q=QUERY&format=json&engines=google,duckduckgo,brave&results=5
```

The model is instructed to:
- Search for everything, not just specific subjects
- Base answers exclusively on search result content, not training data
- Compare results across engines and flag when sources disagree
- Include publication dates so you can judge freshness

---

## VPN Compatibility

If you run a VPN on your machine it will intercept loopback traffic and break the connection between OpenClaw and SearXNG.

**The fix: split tunneling**

Exclude the openclaw and ollama processes from your VPN tunnel. Their traffic never leaves your machine so excluding them costs nothing in terms of privacy. SearXNG's outbound searches still go through your VPN.

The challenge on Linux is most VPN clients only show GUI applications in their split tunnel dropdown. OpenClaw and Ollama are background services with no desktop entries so they won't appear.

Fix — create desktop entries manually:

```bash
sudo tee /usr/share/applications/openclaw.desktop << 'EOF'
[Desktop Entry]
Name=OpenClaw
Exec=/usr/bin/openclaw
Type=Application
Categories=Network;
EOF

sudo tee /usr/share/applications/ollama.desktop << 'EOF'
[Desktop Entry]
Name=Ollama
Exec=/usr/local/bin/ollama
Type=Application
Categories=Network;
EOF
```

After running these, close and reopen your VPN client. OpenClaw and Ollama will now appear in the exclusion list. This works across VPN providers.

Note: if your VPN only supports app-based split tunneling via a config file rather than a GUI, this approach may not work. The GUI .desktop file method is the most reliable on Linux.

---

## Customizing the AI Personality and Behavior

Edit `~/.openclaw/workspace/AGENTS.md` to change how the AI behaves, what it knows about you, and how it handles searches.

Edit `~/.openclaw/workspace/IDENTITY.md` to give the AI a name and personality.

These files persist across conversations — anything you tell the AI to remember should be written here.

---

## Document Q&A (Coming Soon)

The nomic-embed-text model is pre-installed for RAG (Retrieval Augmented Generation). This will allow you to load your own documents — textbooks, manuals, reference material — and ask questions about their contents.

Recommended frontend: AnythingLLM (not included in this script, documented separately).

---

## Troubleshooting

**web_fetch returns blocked errors**
The SSRF patch may have been overwritten. Check:
```bash
grep -c 'dangerouslyAllowPrivateNetwork' /usr/lib/node_modules/openclaw/dist/subagent-registry-*.js
```
If result is 0, re-run the patch section of rebuild.sh.

**OpenClaw won't start (port conflict)**
```bash
sudo pkill -f openclaw-gateway
sleep 2
sudo systemctl start openclaw
```

**Model not searching, giving wrong answers**
Start a fresh session with /new. Long conversations cause context window bloat.

**SearXNG not responding**
```bash
docker ps | grep searxng
docker restart searxng
```

**Ollama not responding**
```bash
sudo systemctl restart ollama
openclaw config get models.providers.ollama.baseUrl
# Should return http://127.0.0.1:11434
```

**Check logs**
```bash
tail -f /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log
```

---

## Security Note

The SSRF guard in OpenClaw exists for a good reason — it prevents malicious content from tricking the AI into making requests to internal network resources like your router admin page or other local services.

By applying this patch you are disabling that protection for local addresses. The risk is low if:
- You are the only user of your OpenClaw instance
- You are not exposing it to the internet
- You are not asking it to fetch content from untrusted sources

The risk is higher if multiple people use your instance or if your gateway is exposed to the internet.

The config key `browser.ssrfPolicy.dangerouslyAllowPrivateNetwork` is an official option in OpenClaw's own codebase. The JavaScript patch was needed because the config key alone was not sufficient to fully bypass the guard.

Use this responsibly.

---

## Contributing

Issues and pull requests welcome. If you find that a newer version of OpenClaw has different SSRF guard filenames, please open an issue with the new filenames and patch commands so the script can be updated.

---

## License

MIT
