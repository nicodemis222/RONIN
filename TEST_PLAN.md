# RONIN Meeting Copilot - UX Test Plan

## Test Environment
- macOS 15+, Apple Silicon
- Python backend on localhost:8000
- LM Studio on localhost:1234 (optional for suggestion tests)

---

## Test 1: Backend Offline Experience

### Steps:
1. Ensure backend is NOT running (kill any python process on port 8000)
2. Launch RoninApp
3. Observe MeetingPrepView

### Expected:
- [x] Backend status shows red dot + "Backend offline"
- [x] "Retry" button appears next to status
- [x] Error banner: "Backend is not running. Start it with: ./scripts/start.sh"
- [x] "Start Listening" button is disabled
- [x] Filling in title + goal does NOT enable button while backend is offline

### After starting backend:
4. Start backend: `./scripts/start.sh`
5. Click "Retry" button

### Expected:
- [x] Status changes to green dot + "Backend online"
- [x] Error banner clears
- [x] "Start Listening" becomes enabled (if title + goal filled)

---

## Test 2: Meeting Prep Form Validation

### Steps:
1. Leave title empty, fill goal
2. Attempt to click "Start Listening"

### Expected:
- [x] Button is disabled
- [x] No error shown (just disabled)

### Steps:
3. Fill title, clear goal

### Expected:
- [x] Button is disabled

### Steps:
4. Fill both title and goal

### Expected:
- [x] Button becomes enabled

---

## Test 3: Notes Pack Loading

### Steps:
1. Click "Choose Files..."
2. Select a .md file
3. Observe file appears in list with name + char count

### Expected:
- [x] File name shown
- [x] Character count shown
- [x] X button to remove

### Steps:
4. Click X to remove
5. Try loading a non-UTF8 binary file

### Expected:
- [x] Error banner: "Could not read [filename]. Ensure it's a text file."

### Steps:
6. Try loading an empty .txt file

### Expected:
- [x] Error banner: "[filename] is empty."

---

## Test 4: Meeting Start Flow

### Steps:
1. Backend running, fill title + goal
2. Click "Start Listening"

### Expected:
- [x] Button shows spinner + "Connecting..."
- [x] Pre-flight health check runs
- [x] On success: transitions to live phase
- [x] Floating copilot overlay window opens
- [x] Main window shows "Meeting in progress"

---

## Test 5: Live Copilot - Connection

### Steps:
1. Start meeting with backend running

### Expected:
- [x] Title bar shows green dot when WebSocket connects
- [x] Status text shows "Listening..." after connection
- [x] Audio level meter shows activity when speaking

### Steps:
2. Kill backend while meeting is active

### Expected:
- [x] Green dot turns red
- [x] Status text shows connection error
- [x] Automatic reconnection attempts (up to 5)
- [x] If reconnection fails: error message about backend

---

## Test 6: Live Copilot - Audio Capture

### Steps:
1. Start meeting, speak into microphone

### Expected:
- [x] Audio level meter shows green/orange bars
- [x] Transcript segments start appearing in left panel
- [x] Timestamps shown next to each segment
- [x] Auto-scrolls to latest segment

---

## Test 7: Live Copilot - Microphone Permission

### Steps:
1. If mic permission not granted, start meeting

### Expected:
- [x] Error alert: "Microphone access denied..."
- [x] Directions to System Settings

---

## Test 8: Live Copilot - Controls

### Pause:
1. Click pause button
### Expected:
- [x] "PAUSED" badge appears in title bar
- [x] Status shows "Paused"
- [x] Timer stops counting
- [x] Audio capture pauses (audio buffer cleared)

### Resume:
2. Click play button
### Expected:
- [x] "PAUSED" badge disappears
- [x] Timer resumes
- [x] Audio capture resumes

### Mute:
3. Click mute button
### Expected:
- [x] Mic icon changes to mic.slash
- [x] Audio level meter goes flat
- [x] Audio buffer cleared (no stale data sent)

### Unmute:
4. Click unmute
### Expected:
- [x] Mic icon restores
- [x] Audio level meter active again

---

## Test 9: Live Copilot - Suggestions (requires LM Studio)

### Steps:
1. Load notes pack with specific facts
2. Start meeting, speak about topics in notes
3. Wait 5-10 seconds

### Expected:
- [x] Suggestions panel populates with 2-3 responses
- [x] Each has tone label (Direct/Diplomatic/Curious)
- [x] Copy button works on each suggestion
- [x] Guidance panel shows follow-up questions
- [x] If notes contain relevant facts, they appear in "From Your Notes"

---

## Test 10: End Meeting + Post-Meeting

### Steps:
1. Click "End" in control bar (or "End Meeting" in main window)

### Expected:
- [x] Copilot overlay closes
- [x] Main window shows loading: "Generating meeting summary..."
- [x] Summary displays with sections: Summary, Decisions, Action Items, Open Questions

### Copy:
2. Click "Copy Summary"
### Expected:
- [x] Success toast: "Copied to clipboard"
- [x] Paste verifies content

### Export:
3. Click "Export to Markdown"
### Expected:
- [x] Save dialog opens with default filename
- [x] After save: success toast with filename
- [x] File contains properly formatted markdown

### New Meeting:
4. Click "New Meeting"
### Expected:
- [x] Returns to Meeting Prep screen
- [x] Form is cleared

---

## Test 11: Post-Meeting Error Recovery

### Steps:
1. Kill backend before ending meeting
2. End meeting

### Expected:
- [x] Error screen: "Failed to generate summary..."
- [x] "Retry" button visible
- [x] "Back to Prep" button visible
- [x] Start backend, click "Retry" -> summary loads

---

## Test 12: Window Management

### Steps:
1. Start meeting
2. Check overlay window behavior

### Expected:
- [x] Overlay floats above other windows (including Zoom/Teams)
- [x] Overlay has translucent material background
- [x] Overlay is resizable (min 800x350)
- [x] 3 panels resize proportionally
- [x] Main window remains accessible behind overlay

---

## Issues Found & Fixed

| # | Issue | Fix Applied |
|---|-------|-------------|
| 1 | No backend health check before starting | Added pre-flight check in MeetingPrepView + MeetingPrepViewModel |
| 2 | WebSocket shows connected before actually connected | Changed to ping-verify, only set connected on success |
| 3 | No mic permission request | Added AVCaptureDevice authorization flow |
| 4 | Silent audio failures | Added onError callback, surfaced in UI |
| 5 | No audio level feedback | Added onAudioLevel callback + AudioLevelView meter |
| 6 | No connection retry | Added exponential backoff reconnection (5 attempts) |
| 7 | Audio buffer stale on pause/mute | Clear buffer on pause and mute |
| 8 | File encoding errors silent | Try multiple encodings, show error if all fail |
| 9 | Empty file accepted silently | Validate file content, show error |
| 10 | Export failure silent | Added do/catch with error message |
| 11 | Copy with no confirmation | Added success toast (both live + post-meeting) |
| 12 | Post-meeting no retry | Added retry button + retry() method |
| 13 | Status text missing | Added statusText showing connection/transcription state |
| 14 | Error messages generic | Improved to actionable messages with context |
| 15 | Backend status indicator | Added backend status badge with retry in prep view |
