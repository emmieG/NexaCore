#!/bin/bash
# =============================================================================
# NEXACORE VOICE ADD-ON — STANDALONE INSTALLER
# Adds voice input (Whisper STT) and voice output (Piper TTS) to NexaCore
# Run AFTER rebuild-v2.sh has completed successfully
# Run as: bash install-voice-v2-GH.sh
# More info: https://github.com/emmieG/NexaCore
# =============================================================================

set -e

CURRENT_USER=$(whoami)

echo "========================================"
echo " NexaCore Voice Add-On Installer"
echo " Running as: $CURRENT_USER"
echo "========================================"

# =============================================================================
# STEP 1: INSTALL DEPENDENCIES
# =============================================================================
echo ""
echo "[1/5] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y make g++ cmake git sox alsa-utils python3-pip
pip3 install flask pystray pillow pynput --break-system-packages
echo "Dependencies installed."

# =============================================================================
# STEP 2: INSTALL WHISPER.CPP (Speech to Text)
# =============================================================================
echo ""
echo "[2/5] Installing Whisper.cpp..."

cd ~
if [ ! -d "whisper.cpp" ]; then
  git clone https://github.com/ggerganov/whisper.cpp.git
else
  echo "whisper.cpp already cloned, skipping."
fi

cd ~/whisper.cpp
make

if [ ! -f "models/ggml-base.en.bin" ]; then
  bash models/download-ggml-model.sh base.en
else
  echo "base.en model already downloaded, skipping."
fi

cd ~
echo "Whisper.cpp installed."
echo "Test: ~/whisper.cpp/build/bin/whisper-cli -m ~/whisper.cpp/models/ggml-base.en.bin -f ~/whisper.cpp/samples/jfk.wav"

# =============================================================================
# STEP 3: INSTALL PIPER TTS
# =============================================================================
echo ""
echo "[3/5] Installing Piper TTS..."

mkdir -p ~/piper
cd ~/piper

if [ ! -f "piper" ]; then
  PIPER_VERSION="2023.11.14-2"
  PIPER_URL="https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_linux_x86_64.tar.gz"
  echo "Downloading Piper..."
  curl -L "$PIPER_URL" -o piper.tar.gz
  tar -xzf piper.tar.gz
  rm piper.tar.gz
else
  echo "Piper binary already exists, skipping download."
fi

if [ ! -f "en_US-lessac-high.onnx" ]; then
  echo "Downloading voice model (en_US-lessac-high)..."
  curl -L "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/high/en_US-lessac-high.onnx" -o en_US-lessac-high.onnx
  curl -L "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/high/en_US-lessac-high.onnx.json" -o en_US-lessac-high.onnx.json
else
  echo "Voice model already exists, skipping download."
fi

cd ~
echo "Piper TTS installed."

# =============================================================================
# STEP 4: INSTALL VOICE SERVER AND TRAY
# =============================================================================
echo ""
echo "[4/5] Installing NexaCore voice server and tray..."

mkdir -p ~/.openclaw/voice

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

cat > ~/.openclaw/voice/nexacore-voice-tray.py << 'TRAYEOF'
import threading
import subprocess
import os
import sys
import json

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
tray_icon = None

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
        data = json.loads(result.stdout)
        text = data.get("text", "").strip()
        if text:
            subprocess.run(["xdotool", "type", "--clearmodifiers", "--", text])
    except Exception:
        pass

def update_icon():
    if tray_icon:
        tray_icon.icon = make_icon("red" if recording else "green")

def on_press(key):
    global hold_timer
    try:
        if key == keyboard.Key.cmd:
            if hold_timer is None:
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

def run_tray():
    global tray_icon
    menu = pystray.Menu(
        pystray.MenuItem("NexaCore Voice", lambda: None, enabled=False),
        pystray.MenuItem("Hold Super 1s to record", lambda: None, enabled=False),
        pystray.MenuItem("Quit", lambda: tray_icon.stop())
    )
    tray_icon = pystray.Icon("nexacore-voice", make_icon("green"), "NexaCore Voice", menu)
    tray_icon.run()

listener = keyboard.Listener(on_press=on_press, on_release=on_release)
listener.start()
run_tray()
TRAYEOF

echo "Voice scripts installed."

# =============================================================================
# STEP 5: CREATE SYSTEMD SERVICE AND AUTOSTART
# =============================================================================
echo ""
echo "[5/5] Setting up autostart..."

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

echo "Autostart configured."

# =============================================================================
# FINAL: VERIFY
# =============================================================================
echo ""
echo "========================================"
echo " VERIFICATION"
echo "========================================"
echo "Voice server: $(systemctl --user is-active nexacore-voice)"
echo "Health check: $(curl -s http://127.0.0.1:19999/health)"
echo ""
echo "========================================"
echo " DONE"
echo "========================================"
echo ""
echo "NEXT STEPS:"
echo "- Install Tampermonkey in Firefox from addons.mozilla.org"
echo "- In Tampermonkey Dashboard, create a new script and paste:"
echo ""
echo "// ==UserScript=="
echo "// @name         NexaCore TTS"
echo "// @namespace    http://127.0.0.1:18789/"
echo "// @version      1.0"
echo "// @match        http://127.0.0.1:18789/*"
echo "// @grant        GM_xmlhttpRequest"
echo "// @connect      127.0.0.1"
echo "// @run-at       document-idle"
echo "// ==/UserScript=="
echo "(function() {"
echo "    'use strict';"
echo "    const seen = new Set();"
echo "    const observer = new MutationObserver(() => {"
echo "        document.querySelectorAll('div.chat-group.assistant div.chat-text').forEach(el => {"
echo "            const text = el.innerText.trim();"
echo "            if (text && !seen.has(text)) {"
echo "                seen.add(text);"
echo "                GM_xmlhttpRequest({"
echo "                    method: 'POST',"
echo "                    url: 'http://127.0.0.1:19999/tts',"
echo "                    headers: {'Content-Type': 'application/json'},"
echo "                    data: JSON.stringify({text: text})"
echo "                });"
echo "            }"
echo "        });"
echo "    });"
echo "    observer.observe(document.body, {childList: true, subtree: true});"
echo "})();"
echo ""
echo "- Test TTS: curl -s -X POST http://127.0.0.1:19999/tts -H 'Content-Type: application/json' -d '{\"text\": \"Voice installed successfully.\"}'"
echo "- Hold Super key for 1 second to activate voice input"
echo "========================================"
