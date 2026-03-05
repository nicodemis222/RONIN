#!/usr/bin/env python3
"""
RONIN Audio Pipeline Test
=========================
Tests the full backend pipeline step by step:
  1. Health check
  2. Meeting setup (/meeting/setup)
  3. WebSocket connect (/ws/audio)
  4. Send synthesized speech audio
  5. Verify transcript comes back
  6. Verify copilot LLM response (if LM Studio is running)

Run from the project root:
  cd /Users/matthewjohnson/RONIN
  source backend/.venv/bin/activate
  python scripts/test_pipeline.py
"""

import asyncio
import json
import struct
import sys
import time
import math
import wave
import tempfile
import os

import httpx
import websockets
import numpy as np

BASE_URL = "http://127.0.0.1:8000"
WS_URL = "ws://127.0.0.1:8000/ws/audio"

# Colors for terminal output
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"
BOLD = "\033[1m"


def log_pass(msg):
    print(f"  {GREEN}✅ PASS{RESET}: {msg}")


def log_fail(msg):
    print(f"  {RED}❌ FAIL{RESET}: {msg}")


def log_info(msg):
    print(f"  {CYAN}ℹ️  INFO{RESET}: {msg}")


def log_warn(msg):
    print(f"  {YELLOW}⚠️  WARN{RESET}: {msg}")


def generate_speech_audio(duration_sec=4.0, sample_rate=16000) -> bytes:
    """
    Generate a synthetic speech-like audio signal.
    Uses amplitude-modulated tones to mimic speech energy patterns
    that will trigger Whisper's speech detection.
    """
    t = np.linspace(0, duration_sec, int(sample_rate * duration_sec), dtype=np.float32)

    # Mix of frequencies typical in speech (100-3000 Hz)
    signal = np.zeros_like(t)
    # Fundamental frequency sweep (simulates pitch variation)
    signal += 0.3 * np.sin(2 * np.pi * 150 * t + 5 * np.sin(2 * np.pi * 2 * t))
    # First formant
    signal += 0.2 * np.sin(2 * np.pi * 500 * t)
    # Second formant
    signal += 0.15 * np.sin(2 * np.pi * 1500 * t)
    # Third formant
    signal += 0.1 * np.sin(2 * np.pi * 2500 * t)

    # Amplitude modulation to simulate syllable rhythm (~4 Hz)
    envelope = 0.5 + 0.5 * np.sin(2 * np.pi * 4 * t)
    signal *= envelope

    # Add some noise for realism
    signal += 0.05 * np.random.randn(len(t))

    # Normalize to int16 range
    signal = signal / np.max(np.abs(signal)) * 0.8
    int16_data = (signal * 32767).astype(np.int16)

    return int16_data.tobytes()


def generate_tts_audio(text="Hello, this is a test of the transcription system", sample_rate=16000) -> bytes:
    """
    Try to use macOS 'say' command to generate real speech audio.
    Falls back to synthetic audio if 'say' is not available.
    """
    try:
        with tempfile.NamedTemporaryFile(suffix=".aiff", delete=False) as f:
            aiff_path = f.name

        # Use macOS 'say' to generate speech
        os.system(f'say -o "{aiff_path}" "{text}"')

        if not os.path.exists(aiff_path) or os.path.getsize(aiff_path) < 100:
            raise FileNotFoundError("say command failed")

        # Convert AIFF to raw PCM via ffmpeg
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            wav_path = f.name

        os.system(
            f'ffmpeg -y -i "{aiff_path}" -ar {sample_rate} -ac 1 -sample_fmt s16 "{wav_path}" 2>/dev/null'
        )

        with wave.open(wav_path, "rb") as wf:
            raw_data = wf.readframes(wf.getnframes())

        os.unlink(aiff_path)
        os.unlink(wav_path)

        if len(raw_data) > 0:
            return raw_data
        raise ValueError("Empty audio")

    except Exception as e:
        log_warn(f"TTS generation failed ({e}), using synthetic audio")
        return generate_speech_audio()


async def test_health():
    """Test 1: Health endpoint"""
    print(f"\n{BOLD}Test 1: Health Check{RESET}")
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get(f"{BASE_URL}/meeting/health", timeout=5)
            if resp.status_code == 200:
                log_pass(f"Backend is healthy: {resp.json()}")
                return True
            else:
                log_fail(f"Health returned status {resp.status_code}")
                return False
    except Exception as e:
        log_fail(f"Cannot reach backend: {e}")
        return False


async def test_meeting_setup():
    """Test 2: Meeting setup"""
    print(f"\n{BOLD}Test 2: Meeting Setup{RESET}")
    config = {
        "title": "Pipeline Test Meeting",
        "goal": "Test that audio transcription and copilot work end-to-end",
        "constraints": "This is an automated test",
        "notes": [],
    }
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                f"{BASE_URL}/meeting/setup",
                json=config,
                timeout=10,
            )
            if resp.status_code == 200:
                data = resp.json()
                session_id = data.get("session_id", "")
                log_pass(f"Meeting created — session_id: {session_id}")
                return session_id
            else:
                log_fail(f"Setup returned {resp.status_code}: {resp.text}")
                return None
    except Exception as e:
        log_fail(f"Setup request failed: {e}")
        return None


async def test_websocket_connect():
    """Test 3: WebSocket connects and stays open"""
    print(f"\n{BOLD}Test 3: WebSocket Connection{RESET}")
    try:
        ws = await asyncio.wait_for(
            websockets.connect(WS_URL), timeout=5
        )
        log_pass(f"WebSocket connected to {WS_URL}")
        # Quick ping test
        pong = await ws.ping()
        await asyncio.wait_for(pong, timeout=3)
        log_pass("WebSocket ping/pong OK")
        return ws
    except asyncio.TimeoutError:
        log_fail("WebSocket connection timed out (5s)")
        return None
    except Exception as e:
        log_fail(f"WebSocket connection failed: {e}")
        return None


async def test_send_audio(ws, audio_data: bytes, chunk_size: int = 64000):
    """Test 4: Send audio chunks and collect responses"""
    print(f"\n{BOLD}Test 4: Send Audio + Receive Responses{RESET}")

    total_bytes = len(audio_data)
    total_samples = total_bytes // 2
    duration = total_samples / 16000
    log_info(f"Audio: {duration:.1f}s, {total_bytes} bytes, sending in {chunk_size}-byte chunks")

    chunks_sent = 0
    messages_received = []

    # Send all chunks
    offset = 0
    while offset < total_bytes:
        chunk = audio_data[offset : offset + chunk_size]
        try:
            await ws.send(chunk)
            chunks_sent += 1
        except Exception as e:
            log_fail(f"Send failed on chunk #{chunks_sent + 1}: {e}")
            return messages_received
        offset += chunk_size
        # Small delay between chunks to simulate real-time
        await asyncio.sleep(0.05)

    log_pass(f"Sent {chunks_sent} audio chunks ({total_bytes} bytes total)")

    # Wait for responses (transcription takes a few seconds)
    log_info("Waiting for backend responses (up to 30s)...")
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            msg = await asyncio.wait_for(ws.recv(), timeout=2.0)
            data = json.loads(msg)
            messages_received.append(data)
            msg_type = data.get("type", "unknown")

            if msg_type == "transcript_update":
                text = data.get("data", {}).get("text", "")
                log_pass(f"Transcript received: \"{text}\"")
            elif msg_type == "copilot_response":
                suggestions = data.get("data", {}).get("suggestions", [])
                log_pass(f"Copilot response: {len(suggestions)} suggestions")
                for s in suggestions[:2]:
                    log_info(f"  [{s.get('tone', '?')}] {s.get('text', '')[:80]}")
            elif msg_type == "error":
                error_msg = data.get("data", {}).get("message", "")
                log_warn(f"Backend error: {error_msg}")
            else:
                log_info(f"Unknown message type: {msg_type}")

        except asyncio.TimeoutError:
            # No message within 2s — check if we have enough
            if messages_received:
                break
            # Keep waiting if we haven't received anything yet
            elapsed = time.time() - (deadline - 30)
            if elapsed < 15:
                continue
            else:
                break
        except websockets.ConnectionClosed as e:
            log_fail(f"WebSocket closed: code={e.code}, reason={e.reason}")
            break
        except Exception as e:
            log_fail(f"Error receiving: {e}")
            break

    return messages_received


async def test_meeting_end(session_id: str):
    """Test 5: End meeting and get summary"""
    print(f"\n{BOLD}Test 5: End Meeting + Summary{RESET}")
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                f"{BASE_URL}/meeting/end?session_id={session_id}",
                timeout=60,
            )
            if resp.status_code == 200:
                data = resp.json()
                summary = data.get("executive_summary", "")
                log_pass(f"Summary generated: \"{summary[:100]}...\"")
                return True
            elif resp.status_code == 503:
                detail = resp.json().get("detail", "")
                log_warn(f"Summary failed (LM Studio not running?): {detail[:100]}")
                return False
            else:
                log_fail(f"End meeting returned {resp.status_code}: {resp.text[:200]}")
                return False
    except Exception as e:
        log_fail(f"End meeting failed: {e}")
        return False


async def run_tests():
    print(f"\n{'=' * 60}")
    print(f"{BOLD}RONIN Audio Pipeline Test{RESET}")
    print(f"{'=' * 60}")

    # Test 1: Health
    healthy = await test_health()
    if not healthy:
        print(f"\n{RED}ABORT: Backend is not running. Start it with:{RESET}")
        print(f"  cd backend && source .venv/bin/activate && python run.py")
        return

    # Test 2: Meeting setup
    session_id = await test_meeting_setup()
    if not session_id:
        print(f"\n{RED}ABORT: Could not create meeting session{RESET}")
        return

    # Test 3: WebSocket connect
    ws = await test_websocket_connect()
    if not ws:
        print(f"\n{RED}ABORT: Could not connect WebSocket{RESET}")
        return

    # Generate speech audio using macOS TTS
    print(f"\n{BOLD}Generating test audio...{RESET}")
    audio_data = generate_tts_audio(
        "Hello, this is a test of the Ronin transcription system. "
        "We are testing whether Whisper can transcribe speech correctly. "
        "The quick brown fox jumps over the lazy dog."
    )
    log_info(f"Generated {len(audio_data)} bytes of audio ({len(audio_data) // 2 / 16000:.1f}s)")

    # Test 4: Send audio + receive responses
    messages = await test_send_audio(ws, audio_data)

    # Close WebSocket
    try:
        await ws.close()
    except Exception:
        pass

    # Analyze results
    print(f"\n{BOLD}Results Summary{RESET}")
    print(f"{'=' * 60}")

    transcript_msgs = [m for m in messages if m.get("type") == "transcript_update"]
    copilot_msgs = [m for m in messages if m.get("type") == "copilot_response"]
    error_msgs = [m for m in messages if m.get("type") == "error"]

    print(f"  Transcript messages: {len(transcript_msgs)}")
    print(f"  Copilot responses:   {len(copilot_msgs)}")
    print(f"  Error messages:      {len(error_msgs)}")

    if transcript_msgs:
        full_text = " ".join(m["data"]["text"] for m in transcript_msgs)
        print(f"  Full transcript:     \"{full_text}\"")

    if error_msgs:
        for e in error_msgs:
            print(f"  {RED}Error: {e['data']['message']}{RESET}")

    if not messages:
        log_fail("No messages received at all!")
        print(f"\n{YELLOW}Diagnosis:{RESET}")
        print("  - Audio was sent but no response came back")
        print("  - Check ~/Library/Logs/Ronin/backend.log for details")
        print("  - Possible causes:")
        print("    1. Whisper model not found (check HF_HUB_CACHE)")
        print("    2. Transcription is blocking the event loop")
        print("    3. Audio energy too low (silence detection)")
    elif not transcript_msgs:
        log_warn("WebSocket responded but no transcripts")
        print("  - Whisper may be returning empty text")
        print("  - Check audio energy levels in backend.log")
    else:
        log_pass("Pipeline is working!")

    # Test 5: End meeting (optional — needs LM Studio)
    if transcript_msgs:
        await test_meeting_end(session_id)

    print(f"\n{'=' * 60}")
    print(f"{BOLD}Test complete.{RESET}")
    print(f"Backend logs: ~/Library/Logs/Ronin/backend.log")
    print(f"{'=' * 60}\n")


if __name__ == "__main__":
    asyncio.run(run_tests())
