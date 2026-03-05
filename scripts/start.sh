#!/bin/bash
set -e

RONIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND_DIR="$RONIN_DIR/backend"

echo "=== Starting Ronin ==="

# Check LM Studio
echo "Checking LM Studio..."
if curl -s http://localhost:1234/v1/models > /dev/null 2>&1; then
    echo "  LM Studio: OK"
else
    echo "  WARNING: LM Studio not responding on localhost:1234"
    echo "  Start LM Studio and load a model before beginning a meeting."
fi

# Start backend
echo "Starting backend..."
cd "$BACKEND_DIR"
source .venv/bin/activate
HF_HUB_OFFLINE=1 python run.py &
BACKEND_PID=$!

# Wait for backend health
echo "Waiting for backend..."
for i in {1..15}; do
    if curl -s http://localhost:8000/meeting/health > /dev/null 2>&1; then
        echo "  Backend: OK (PID: $BACKEND_PID)"
        break
    fi
    if [ $i -eq 15 ]; then
        echo "  ERROR: Backend failed to start"
        kill $BACKEND_PID 2>/dev/null
        exit 1
    fi
    sleep 1
done

echo ""
echo "Ronin backend is running on http://localhost:8000"
echo "Open the RoninApp in Xcode and run it."
echo "Press Ctrl+C to stop the backend."
echo ""

wait $BACKEND_PID
