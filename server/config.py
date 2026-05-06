"""
YT-Downloader - Configuration
"""

import os
import shutil
from pathlib import Path

# Base directories
BASE_DIR = Path(__file__).resolve().parent.parent
DOWNLOAD_DIR = BASE_DIR / "downloads"
LOG_DIR = BASE_DIR / "logs"

# GUI-launched processes often do not inherit the user's shell PATH. Add the
# common Homebrew locations before resolving command-line tools.
TOOL_SEARCH_PATHS = [
    BASE_DIR / "bin",
    Path("/opt/homebrew/bin"),
    Path("/usr/local/bin"),
    Path("/usr/bin"),
    Path("/bin"),
]


def _augment_path() -> None:
    current_parts = [part for part in os.environ.get("PATH", "").split(os.pathsep) if part]
    extra_parts = [
        str(path)
        for path in TOOL_SEARCH_PATHS
        if path.is_dir() and str(path) not in current_parts
    ]

    if extra_parts:
        os.environ["PATH"] = os.pathsep.join(extra_parts + current_parts)


def resolve_executable(name: str, env_var: str | None = None) -> str | None:
    configured = os.environ.get(env_var or "")
    if configured:
        expanded = Path(configured).expanduser()
        if expanded.is_dir():
            candidate = expanded / name
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return str(candidate)
        elif expanded.is_file() and os.access(expanded, os.X_OK):
            return str(expanded)

    found = shutil.which(name)
    if found:
        return found

    for directory in TOOL_SEARCH_PATHS:
        candidate = directory / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)

    return None


_augment_path()

# Server settings
HOST = os.environ.get("YTDLP_MAC_APP_HOST", "127.0.0.1")
PORT = int(os.environ.get("YTDLP_MAC_APP_PORT", "18765"))
LOG_LEVEL = "info"

# yt-dlp settings
DEFAULT_FORMAT = (
    "bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a][acodec^=mp4a]/"
    "bestvideo[ext=mp4][vcodec^=avc1]+bestaudio[ext=m4a]/"
    "best[ext=mp4][vcodec^=avc1][acodec^=mp4a]/"
    "best[ext=mp4][vcodec^=avc1]/"
    "best[ext=mp4]/best"
)
DEFAULT_SUBTITLE_LANGUAGES = ["ja", "en"]
MAX_CONCURRENT_DOWNLOADS = 3
YTDLP_COOKIE_FILE = os.environ.get("YTDLP_COOKIE_FILE") or None
YTDLP_COOKIES_FROM_BROWSER = os.environ.get("YTDLP_COOKIES_FROM_BROWSER", "auto").strip().lower()

# Command-line tools (system, Homebrew, or bundled in ./bin)
FFMPEG_PATH = resolve_executable("ffmpeg", "FFMPEG_PATH")
FFPROBE_PATH = resolve_executable("ffprobe", "FFPROBE_PATH")
YTDLP_PATH = resolve_executable("yt-dlp", "YTDLP_PATH")

# Ensure directories exist
DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR.mkdir(parents=True, exist_ok=True)
