import logging
import os
import sys

import uvicorn

# Set up file logging so we can diagnose issues in the packaged app
LOG_DIR = os.path.expanduser("~/Library/Logs/Ronin")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "backend.log")

# Configure root logger BEFORE uvicorn starts.
# Pass log_config=None to uvicorn to prevent it from overriding our config.
file_handler = logging.FileHandler(LOG_FILE, mode="w")
file_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s"))
stream_handler = logging.StreamHandler(sys.stderr)
stream_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s"))

root_logger = logging.getLogger()
root_logger.setLevel(logging.DEBUG)
root_logger.addHandler(file_handler)
root_logger.addHandler(stream_handler)

logger = logging.getLogger("ronin")
logger.info(f"Ronin backend starting — logs at {LOG_FILE}")
logger.info(f"Python: {sys.executable}")
logger.info(f"Working dir: {os.getcwd()}")
logger.info(f"HF_HUB_CACHE: {os.environ.get('HF_HUB_CACHE', '(not set)')}")
logger.info(f"HF_HUB_OFFLINE: {os.environ.get('HF_HUB_OFFLINE', '(not set)')}")

if __name__ == "__main__":
    uvicorn.run(
        "app.main:app",
        host="127.0.0.1",
        port=8000,
        reload=False,
        log_level="debug",
        log_config=None,  # Don't let uvicorn override our logging config
    )
