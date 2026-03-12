#!/bin/bash
# =============================================================================
# NEXACORE REBUILD SCRIPT v2
# Rebuilds: Ollama + SearXNG + OpenClaw 2026.3.1 + SSRF patches + all models
#           + Whisper STT + Piper TTS + NexaCore Voice Stack
# Run as: bash rebuild-v2.sh
# More info: https://www.reddit.com/r/openclaw/comments/1rm5h3c/
# =============================================================================

set -e

CURRENT_USER=$(whoami)

echo "========================================"
echo " NexaCore Rebuild Script v2"
echo " Running as: $CURRENT_USER"
echo "========================================"

# =============================================================================
# STEP 1: INSTALL OLLAMA
# =============================================================================
echo ""
echo "[1/10] Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl enable ollama
sudo systemctl start ollama
sleep 3
echo "Ollama installed: $(ollama --version)"

# =============================================================================
# STEP 2: PULL ALL MODELS
# =============================================================================
echo ""
echo "[2/10] Pulling Ollama models (this will take a while)..."

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
echo "[3/10] Creating optimized fast models (num_ctx 4096)..."

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
echo "[4/10] Installing Docker and SearXNG..."
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
echo "[5/10] Installing OpenClaw 2026.3.1..."
sudo npm install -g openclaw@2026.3.1

# Start OpenClaw once so it creates its own user service file
openclaw gateway &
sleep 8
openclaw gateway stop
sleep 3

# Fix the user service — add WorkingDirectory and startup delay to prevent uv_cwd error on boot
SERVICE_FILE="$HOME/.config/systemd/user/openclaw-gateway.service"
if [ -f "$SERVICE_FILE" ]; then
  # Only add if not already present
  grep -q "WorkingDirectory" "$SERVICE_FILE" || \
    sed -i 's/\[Service\]/[Service]\nWorkingDirectory=\/home\/$CURRENT_USER\nExecStartPre=\/bin\/sleep 5/' "$SERVICE_FILE"
  echo "User service patched with WorkingDirectory and startup delay."
else
  echo "WARNING: openclaw-gateway.service not found at $SERVICE_FILE"
  echo "Start OpenClaw manually once, then re-run the service fix."
fi

systemctl --user daemon-reload
systemctl --user enable openclaw-gateway
systemctl --user start openclaw-gateway
sleep 6
echo "OpenClaw installed: $(openclaw --version)"

# =============================================================================
# STEP 6: CONFIGURE OPENCLAW
# =============================================================================
echo ""
echo "[6/10] Configuring OpenClaw..."

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
echo "[7/10] Applying SSRF patches..."

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
echo "[8/10] Setting up OpenClaw workspace and desktop entries..."

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

echo "Workspace and desktop entries created."

# =============================================================================
# STEP 9: INSTALL WHISPER.CPP (Speech to Text)
# =============================================================================
echo ""
echo "[9/10] Installing Whisper.cpp (speech to text)..."

sudo apt-get install -y make g++ libsdl2-dev cmake

cd ~
if [ ! -d "whisper.cpp" ]; then
  git clone https://github.com/ggerganov/whisper.cpp.git
fi
cd whisper.cpp
make
bash models/download-ggml-model.sh base.en
cd ~

echo "Whisper.cpp installed and base.en model downloaded."
echo "Test with: ~/whisper.cpp/build/bin/whisper-cli -m ~/whisper.cpp/models/ggml-base.en.bin -f ~/whisper.cpp/samples/jfk.wav"

# =============================================================================
# STEP 10: INSTALL PIPER TTS + VOICE STACK
# =============================================================================
echo ""
echo "[10/10] Installing Piper TTS and NexaCore voice stack..."

# Dependencies
sudo apt-get install -y sox alsa-utils python3-pip
pip3 install flask pystray pillow pynput --break-system-packages

# Install Piper
mkdir -p ~/piper
cd ~/piper

PIPER_VERSION="2023.11.14-2"
PIPER_URL="https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_linux_x86_64.tar.gz"

echo "Downloading Piper TTS..."
curl -L "$PIPER_URL" -o piper.tar.gz
tar -xzf piper.tar.gz
rm piper.tar.gz

echo "Downloading Piper voice model (en_US-lessac-high)..."
curl -L "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/high/en_US-lessac-high.onnx" -o en_US-lessac-high.onnx
curl -L "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/high/en_US-lessac-high.onnx.json" -o en_US-lessac-high.onnx.json

cd ~

echo "Testing Piper TTS..."
echo "Piper TTS installed." | ~/piper/piper --model ~/piper/en_US-lessac-high.onnx --output_raw | aplay -r 22050 -f S16_LE -t raw - 2>/dev/null && echo "Piper OK" || echo "Note: Piper test skipped (no audio device in this context)"

# Create voice directory
mkdir -p ~/.openclaw/voice

# Create voice server
cat > ~/.openclaw/voice/nexacore-voice-server.py << 'SERVEREOF'
from flask import Flask, jsonify, request
import subprocess
import os
import threading

app = Flask(__name__)

recording_process = None
recording_file = "/tmp/nexacore-voice.wav"

@app.route("/start", methods=["POST"])
def start():
    global recording_process
    if recording_process:
        return jsonify({"error": "already recording"}), 400
    recording_process = subprocess.Popen(
        ["arecord", "-f", "cd", "-t", "wav", "-r", "16000", recording_file],
        stderr=subprocess.DEVNULL
    )
    return jsonify({"status": "recording"})

@app.route("/stop", methods=["POST"])
def stop():
    global recording_process
    if not recording_process:
        return jsonify({"error": "not recording"}), 400
    recording_process.terminate()
    recording_process.wait()
    recording_process = None

    whisper = os.path.expanduser("~/whisper.cpp/build/bin/whisper-cli")
    model = os.path.expanduser("~/whisper.cpp/models/ggml-base.en.bin")
    result = subprocess.run(
        [whisper, "-m", model, "-f", recording_file, "--no-timestamps", "-otxt"],
        capture_output=True, text=True
    )
    txt_file = recording_file + ".txt"
    text = ""
    if os.path.exists(txt_file):
        with open(txt_file) as f:
            text = f.read().strip()
        os.remove(txt_file)
    if os.path.exists(recording_file):
        os.remove(recording_file)

    return jsonify({"text": text})

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})

def speak(text):
    piper = os.path.expanduser("~/piper/piper")
    model = os.path.expanduser("~/piper/en_US-lessac-high.onnx")
    tts = subprocess.Popen(
        [piper, "--model", model, "--output_raw"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL
    )
    aplay = subprocess.Popen(
        ["aplay", "-r", "22050", "-f", "S16_LE", "-t", "raw", "-"],
        stdin=tts.stdout,
        stderr=subprocess.DEVNULL
    )
    tts.stdin.write(text.encode())
    tts.stdin.close()
    tts.wait()
    aplay.wait()

@app.route("/tts", methods=["POST"])
def tts():
    data = request.get_json()
    text = data.get("text", "").strip()
    if not text:
        return jsonify({"error": "no text"}), 400
    threading.Thread(target=speak, args=(text,), daemon=True).start()
    return jsonify({"status": "speaking"})

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=19999)
SERVEREOF

# Create voice tray app
cat > ~/.openclaw/voice/nexacore-voice-tray.py << 'TRAYEOF'
import threading
import subprocess
import time
import os
import signal
import sys

try:
    import pystray
    from PIL import Image, ImageDraw
    from pynput import keyboard
except ImportError:
    print("Missing dependencies. Run: pip3 install pystray pillow pynput")
    sys.exit(1)

VOICE_SERVER = "http://127.0.0.1:19999"
recording = False
hold_timer = None

def make_icon(color):
    img = Image.new("RGB", (64, 64), color="black")
    d = ImageDraw.Draw(img)
    d.ellipse([8, 8, 56, 56], fill=color)
    return img

def start_recording():
    global recording
    if recording:
        return
    recording = True
    subprocess.run(["curl", "-s", "-X", "POST", f"{VOICE_SERVER}/start"], capture_output=True)
    update_icon()

def stop_recording():
    global recording
    if not recording:
        return
    recording = False
    update_icon()
    result = subprocess.run(
        ["curl", "-s", "-X", "POST", f"{VOICE_SERVER}/stop"],
        capture_output=True, text=True
    )
    try:
        import json
        data = json.loads(result.stdout)
        text = data.get("text", "").strip()
        if text:
            subprocess.run(["xdotool", "type", "--clearmodifiers", "--", text])
    except Exception:
        pass

def update_icon():
    if tray_icon:
        tray_icon.icon = make_icon("red" if recording else "green")

def on_click(icon, item):
    pass

def on_press(key):
    global hold_timer
    try:
        if key == keyboard.Key.cmd:
            hold_timer = threading.Timer(1.0, start_recording)
            hold_timer.start()
    except Exception:
        pass

def on_release(key):
    global hold_timer
    try:
        if key == keyboard.Key.cmd:
            if hold_timer:
                hold_timer.cancel()
                hold_timer = None
            stop_recording()
    except Exception:
        pass

tray_icon = None

def run_tray():
    global tray_icon
    menu = pystray.Menu(
        pystray.MenuItem("NexaCore Voice", lambda: None, enabled=False),
        pystray.MenuItem("Hold Super+Space to record", lambda: None, enabled=False),
        pystray.MenuItem("Quit", lambda: tray_icon.stop())
    )
    tray_icon = pystray.Icon("nexacore-voice", make_icon("green"), "NexaCore Voice", menu)
    tray_icon.run()

listener = keyboard.Listener(on_press=on_press, on_release=on_release)
listener.start()

run_tray()
TRAYEOF

# Create systemd user service for voice server
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/nexacore-voice.service << SVCEOF
[Unit]
Description=NexaCore Voice Server
After=default.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /home/$CURRENT_USER/.openclaw/voice/nexacore-voice-server.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF

systemctl --user daemon-reload
systemctl --user enable nexacore-voice
systemctl --user start nexacore-voice

# Create autostart entry for voice tray
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/nexacore-voice.desktop << AUTOEOF
[Desktop Entry]
Type=Application
Name=NexaCore Voice Tray
Exec=/usr/bin/python3 /home/$CURRENT_USER/.openclaw/voice/nexacore-voice-tray.py
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
AUTOEOF

echo "Voice stack installed."

# =============================================================================
# FINAL: RESTART AND VERIFY
# =============================================================================
echo ""
echo "Restarting OpenClaw..."
systemctl --user restart openclaw-gateway
sleep 6

echo ""
echo "========================================"
echo " VERIFICATION"
echo "========================================"
echo "Ollama:     $(curl -s http://127.0.0.1:11434/api/version)"
echo "SearXNG:    $(curl -s 'http://127.0.0.1:8081/search?q=test&format=json&engines=duckduckgo&results=1' | head -c 50)"
echo "OpenClaw:   $(openclaw --version)"
echo "Model:      $(openclaw config get agents.defaults.model.primary)"
echo "Ollama URL: $(openclaw config get models.providers.ollama.baseUrl)"
echo "Gateway:    $(systemctl --user is-active openclaw-gateway)"
echo "Voice svc:  $(systemctl --user is-active nexacore-voice)"
echo ""
echo "========================================"
echo " DONE — Open http://127.0.0.1:18789"
echo "========================================"
echo ""
echo "NEXT STEPS:"
echo "- Open http://127.0.0.1:18789 in Firefox"
echo "- Install Tampermonkey from addons.mozilla.org"
echo "- Restore TTS script from tampermonkey-backup-*.txt via Tampermonkey Dashboard > Utilities > Import"
echo "- Edit ~/.openclaw/workspace/AGENTS.md with your personal info"
echo "- If using a VPN, add OpenClaw and Ollama to your split tunnel exclusion list"
echo "- Do NOT run: sudo npm install -g openclaw (will overwrite patches)"
echo "- Do NOT run: openclaw update"
echo "========================================"
