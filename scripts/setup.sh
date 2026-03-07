#!/bin/bash
set -e

RONIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND_DIR="$RONIN_DIR/backend"

echo "=== Ronin Meeting Copilot Setup ==="
echo ""

# Check Python — prefer python3.14, fall back to python3
PYTHON_CMD=""
for cmd in python3.14 python3; do
    if command -v "$cmd" &> /dev/null; then
        PYTHON_CMD="$cmd"
        break
    fi
done
if [ -z "$PYTHON_CMD" ]; then
    echo "ERROR: Python 3 is required. Install via: brew install python@3.14"
    exit 1
fi
echo "Python: $($PYTHON_CMD --version)"

# Verify minimum version (3.13+)
PY_MINOR=$($PYTHON_CMD -c "import sys; print(sys.version_info.minor)")
if [ "$PY_MINOR" -lt 13 ]; then
    echo "ERROR: Python 3.13+ is required (found $($PYTHON_CMD --version))"
    echo "Install via: brew install python@3.14"
    exit 1
fi

# Create virtual environment
echo ""
echo "Setting up Python virtual environment..."
cd "$BACKEND_DIR"
$PYTHON_CMD -m venv .venv
source .venv/bin/activate

# Install dependencies
echo "Installing Python dependencies..."
pip install --upgrade pip -q
pip install -r requirements.txt

# Pre-download Whisper model
echo ""
echo "Pre-downloading Whisper model (this may take a minute on first run)..."
python3 -c "
import mlx_whisper
import tempfile, wave, numpy as np
# Create a minimal WAV to trigger model download
with tempfile.NamedTemporaryFile(suffix='.wav', delete=True) as f:
    with wave.open(f.name, 'wb') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(16000)
        wf.writeframes(np.zeros(16000, dtype=np.int16).tobytes())
    try:
        mlx_whisper.transcribe(f.name, path_or_hf_repo='mlx-community/whisper-small-mlx')
    except:
        pass
print('Whisper model ready.')
"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Make sure LM Studio is running with a model loaded on localhost:1234"
echo "  2. Open RoninApp/RoninApp.xcodeproj in Xcode and build"
echo "  3. Run: ./scripts/start.sh to launch the backend"
