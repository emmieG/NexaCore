#!/bin/bash
# =============================================================================
# LOCAL PRIVATE AI STACK — REBUILD SCRIPT
# Rebuilds: Ollama + SearXNG + OpenClaw 2026.3.1 + SSRF patches + all models
# Run as: bash rebuild.sh
# More info: https://www.reddit.com/r/openclaw/comments/1rm5h3c/
# =============================================================================

set -e

# Detect current username automatically — no hardcoded usernames
CURRENT_USER=$(whoami)

echo "========================================"
echo " Local Private AI Stack — Rebuild"
echo " Running as: $CURRENT_USER"
echo "========================================"

# =============================================================================
# STEP 1: INSTALL OLLAMA
# =============================================================================
echo ""
echo "[1/8] Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl enable ollama
sudo systemctl start ollama
sleep 3
echo "Ollama installed: $(ollama --version)"

# =============================================================================
# STEP 2: PULL ALL MODELS
# =============================================================================
echo ""
echo "[2/8] Pulling Ollama models (this will take a while)..."

ollama pull qwen2.5:7b
ollama pull qwen2.5:3b
ollama pull qwen2.5-coder:7b
ollama pull qwen2.5-coder:3b
ollama pull mistral:7b
ollama pull phi3:mini
ollama pull llava:7b
ollama pull gemma3:4b
ollama pull deepseek-coder:6.7b
ollama pull nomic-embed-text

echo "All base models pulled."

# =============================================================================
# STEP 3: CREATE OPTIMIZED MODELFILES (reduced context window for speed)
# =============================================================================
echo ""
echo "[3/8] Creating optimized fast models (num_ctx 4096)..."

create_fast_model() {
  local base=$1
  local name=$2
  local tmpfile=$(mktemp)
  printf "FROM %s\nPARAMETER num_ctx 4096\n" "$base" > "$tmpfile"
  ollama create "$name" -f "$tmpfile"
  rm "$tmpfile"
  echo "Created: $name from $base"
}

create_fast_model "qwen2.5:7b"          "qwen2.5-fast"
create_fast_model "qwen2.5-coder:7b"    "qwen2.5-coder-fast"
create_fast_model "qwen2.5-coder:3b"    "qwen2.5-coder-fast-3b"
create_fast_model "mistral:7b"          "mistral-fast"
create_fast_model "phi3:mini"           "phi3-fast"
create_fast_model "llava:7b"            "llava-fast"
create_fast_model "deepseek-coder:6.7b" "deepseek-coder-fast"
create_fast_model "gemma3:4b"           "gemma3-fast"

echo "All fast models created."
ollama list

# =============================================================================
# STEP 4: INSTALL DOCKER AND SEARXNG
# =============================================================================
echo ""
echo "[4/8] Installing Docker and SearXNG..."
sudo apt-get update
sudo apt-get install -y docker.io
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker $CURRENT_USER

echo "Starting SearXNG container..."
docker run -d \
  --name searxng \
  --restart always \
  -p 8081:8080 \
  searxng/searxng

echo "Waiting for SearXNG to start..."
sleep 5

echo "Enabling JSON format in SearXNG..."
docker exec searxng sh -c "
  sed -i 's/# - json/- json/' /etc/searxng/settings.yml 2>/dev/null || \
  grep -q 'json' /etc/searxng/settings.yml || \
  echo 'Note: manually verify JSON format is enabled in SearXNG settings.yml'
"
docker restart searxng
sleep 3

echo "Testing SearXNG..."
curl -s "http://127.0.0.1:8081/search?q=test&format=json&engines=duckduckgo&results=1" | head -c 100
echo ""
echo "SearXNG OK"

# =============================================================================
# STEP 5: INSTALL OPENCLAW 2026.3.1
# =============================================================================
echo ""
echo "[5/8] Installing OpenClaw 2026.3.1..."
sudo npm install -g openclaw@2026.3.1

sudo tee /etc/systemd/system/openclaw.service > /dev/null << SERVICEEOF
[Unit]
Description=OpenClaw Gateway
After=network.target ollama.service

[Service]
Type=simple
User=$CURRENT_USER
ExecStart=/usr/bin/openclaw gateway
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

sudo systemctl daemon-reload
sudo systemctl enable openclaw
sudo systemctl start openclaw
sleep 3
echo "OpenClaw installed: $(openclaw --version)"

# =============================================================================
# STEP 6: CONFIGURE OPENCLAW
# =============================================================================
echo ""
echo "[6/8] Configuring OpenClaw..."

openclaw config set models.providers.ollama.baseUrl http://127.0.0.1:11434
openclaw config set agents.defaults.model.primary ollama/qwen2.5-fast
openclaw config set tools.web.search.enabled false
openclaw config set browser.ssrfPolicy.dangerouslyAllowPrivateNetwork true
openclaw config set update.checkOnStart false

echo "OpenClaw config applied."

# =============================================================================
# STEP 7: APPLY SSRF PATCHES
# =============================================================================
echo ""
echo "[7/8] Applying SSRF patches..."

DIST="/usr/lib/node_modules/openclaw/dist"

SUBAGENT=$(ls $DIST/subagent-registry-*.js 2>/dev/null | grep -v ".bak" | head -1)
if [ -z "$SUBAGENT" ]; then
  echo "ERROR: Could not find subagent-registry file in $DIST"
  exit 1
fi

echo "Patching $SUBAGENT..."
sudo cp "$SUBAGENT" "$SUBAGENT.bak"
sudo sed -i 's/return fetchWithSsrFGuard(useEnvProxy ? withTrustedEnvProxyGuardedFetchMode(resolved) : withStrictGuardedFetchMode(resolved));/return fetchWithSsrFGuard({...withTrustedEnvProxyGuardedFetchMode(resolved), policy: {...(resolved.policy ?? {}), dangerouslyAllowPrivateNetwork: true}});/' "$SUBAGENT"
echo "subagent-registry patched: $(grep -c 'dangerouslyAllowPrivateNetwork' $SUBAGENT) occurrences"

for f in $(ls $DIST/ssrf-*.js 2>/dev/null | grep -v ".bak"); do
  sudo cp "$f" "$f.bak"
  sudo sed -i 's/return policy?.dangerouslyAllowPrivateNetwork === true || policy?.allowPrivateNetwork === true;/return true;/' "$f"
  echo "Patched $f"
done

for f in $(ls $DIST/proxy-env-*.js 2>/dev/null | grep -v ".bak"); do
  sudo cp "$f" "$f.bak"
  sudo sed -i 's/return policy?.dangerouslyAllowPrivateNetwork === true || policy?.allowPrivateNetwork === true;/return true;/' "$f"
  echo "Patched $f"
done

for f in $(ls $DIST/fetch-guard-*.js 2>/dev/null | grep -v ".bak"); do
  sudo cp "$f" "$f.bak"
  sudo sed -i 's/dangerouslyAllowPrivateNetwork:!1/dangerouslyAllowPrivateNetwork:!0/g' "$f"
  echo "Patched fetch-guard: $f"
done

echo "All SSRF patches applied."

# =============================================================================
# STEP 8: SET UP WORKSPACE AND DESKTOP ENTRIES
# =============================================================================
echo ""
echo "[8/8] Setting up OpenClaw workspace and desktop entries..."

mkdir -p ~/.openclaw/workspace

cat > ~/.openclaw/workspace/AGENTS.md << 'AGENTSEOF'
## CRITICAL: Search Tool
You do NOT have web_search available. It requires an API key you do not have.
Instead use web_fetch with this URL: http://127.0.0.1:8081/search?q=QUERY&format=json&engines=google,duckduckgo,brave&results=5
Replace spaces in the query with +. This is your ONLY search method.

## CRITICAL: Real-Time Search
Your training data has a cutoff date. You cannot know current prices, news, weather, or any recent events from memory. For ANY question about the current state of the world — news, prices, people, events, weather, sports, politics, legal cases, anything — you MUST use web_fetch to search SearXNG before answering. Never say you cannot search — you can, use web_fetch.

## MANDATORY SEARCH RULE
- Use web_fetch with SearXNG for ALL current information without exception
- Do not limit this to specific subjects — search for everything
- URL pattern: http://127.0.0.1:8081/search?q=QUERY&format=json&engines=google,duckduckgo,brave&results=5
- When web_fetch returns JSON results, base your answer exclusively on the content fields
- Do not use training data when search results are available
- Note which engine each result came from
- Compare results across engines — if most agree but one differs, report the consensus and flag the outlier
- Always include the published date from results if one exists
- For price queries use results=1 and report exact dollar amount per troy ounce unless asked otherwise
- Present answers cleanly — give the answer first, then sources

## Memory and Persistence
- You have persistent memory across conversations via this workspace
- When the user tells you something important — a preference, a correction, a fact — note it below
- If the user corrects you, accept the correction immediately and remember it going forward
- Do not repeat information the user has already given you

# About Me
## My Preferences
- Fill this in during your first conversation

## My Setup
- OS: Linux
- Local AI: Ollama running qwen2.5-fast
- Private search: SearXNG running on Docker at http://127.0.0.1:8081
- OpenClaw version: 2026.3.1 (do not update)

## Important Facts
-

## Appointments & Reminders
-

## Conversation Notes
-
AGENTSEOF

cat > ~/.openclaw/workspace/IDENTITY.md << 'IDENTITYEOF'
# IDENTITY.md
Fill this in during your first conversation.
- **Name:**
- **Vibe:**
- **Emoji:**
IDENTITYEOF

sudo tee /usr/share/applications/openclaw.desktop > /dev/null << 'DESKTOPEOF'
[Desktop Entry]
Name=OpenClaw
Exec=/usr/bin/openclaw
Type=Application
Categories=Network;
DESKTOPEOF

sudo tee /usr/share/applications/ollama.desktop > /dev/null << 'DESKTOPEOF'
[Desktop Entry]
Name=Ollama
Exec=/usr/local/bin/ollama
Type=Application
Categories=Network;
DESKTOPEOF

echo "Desktop entries created for VPN split tunneling."

# =============================================================================
# FINAL: RESTART AND VERIFY
# =============================================================================
echo ""
echo "Restarting OpenClaw..."
sudo systemctl restart openclaw
sleep 3

echo ""
echo "========================================"
echo " VERIFICATION"
echo "========================================"
echo "Ollama:     $(curl -s http://127.0.0.1:11434/api/version)"
echo "SearXNG:    $(curl -s 'http://127.0.0.1:8081/search?q=test&format=json&engines=duckduckgo&results=1' | head -c 50)"
echo "OpenClaw:   $(openclaw --version)"
echo "Model:      $(openclaw config get agents.defaults.model.primary)"
echo "Ollama URL: $(openclaw config get models.providers.ollama.baseUrl)"
echo ""
echo "========================================"
echo " DONE — Open http://127.0.0.1:18789"
echo "========================================"
echo ""
echo "NEXT STEPS:"
echo "- Open http://127.0.0.1:18789 in your browser"
echo "- Edit ~/.openclaw/workspace/AGENTS.md with your personal preferences"
echo "- If using a VPN, add OpenClaw and Ollama to your split tunnel exclusion list"
echo "- Do NOT run: sudo npm install -g openclaw (will overwrite patches)"
echo "- Do NOT run: openclaw update"
echo "========================================"
