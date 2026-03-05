import logging
import os
import sys
from logging.handlers import RotatingFileHandler

import uvicorn

# Set up file logging so we can diagnose issues in the packaged app
LOG_DIR = os.path.expanduser("~/Library/Logs/Ronin")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "backend.log")

# Configure root logger BEFORE uvicorn starts.
# Pass log_config=None to uvicorn to prevent it from overriding our config.
# Use rotating log (max 5 MB, keep 3 backups) instead of overwriting (L5)
file_handler = RotatingFileHandler(
    LOG_FILE, mode="a", maxBytes=5_000_000, backupCount=3
)
file_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s"))
stream_handler = logging.StreamHandler(sys.stderr)
stream_handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s"))

root_logger = logging.getLogger()
root_logger.setLevel(logging.INFO)  # INFO in production, not DEBUG (I1)
root_logger.addHandler(file_handler)
root_logger.addHandler(stream_handler)

logger = logging.getLogger("ronin")
logger.info(f"Ronin backend starting — logs at {LOG_FILE}")
logger.info(f"Python: {sys.executable}")
logger.info(f"Working dir: {os.getcwd()}")

if __name__ == "__main__":
    uvicorn.run(
        "app.main:app",
        host="127.0.0.1",
        port=8000,
        reload=False,
        log_level="info",
        log_config=None,  # Don't let uvicorn override our logging config
    )
