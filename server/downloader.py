"""
YT-Downloader - Downloader Module
yt-dlpをラップし、動画の取得・ダウンロード・進捗管理を行う
"""

import os
import shutil
import subprocess
import threading
import uuid
import json
import asyncio
from pathlib import Path
from typing import Optional, Dict, Any, List
from dataclasses import dataclass, field
from enum import Enum

import yt_dlp

from config import DEFAULT_FORMAT


class DownloadStatus(str, Enum):
    PENDING = "pending"
    DOWNLOADING = "downloading"
    PROCESSING = "processing"
    COMPLETED = "completed"
    ERROR = "error"
    CANCELLED = "cancelled"


@dataclass
class DownloadTask:
    task_id: str
    url: str
    status: DownloadStatus = DownloadStatus.PENDING
    progress: float = 0.0
    speed: float = 0.0
    eta: float = 0.0
    total_bytes: int = 0
    downloaded_bytes: int = 0
    filename: str = ""
    filepath: str = ""
    thumbnail: str = ""
    title: str = ""
    error_message: str = ""
    format_id: str = ""
    subtitle: bool = False
    duplicate_policy: str = "skip"


class DownloadManager:
    """ダウンロードタスクを管理するマネージャー"""

    def __init__(
        self,
        download_dir: str,
        ffmpeg_path: Optional[str] = None,
        cookie_file: Optional[str] = None,
        cookies_from_browser: Optional[str] = None,
    ):
        self.download_dir = Path(download_dir)
        self.download_dir.mkdir(parents=True, exist_ok=True)
        self.ffmpeg_path = ffmpeg_path
        self.ffmpeg_available = self._is_executable_available(ffmpeg_path)
        self.cookie_file = cookie_file
        self.cookies_from_browser = (cookies_from_browser or "").strip().lower()
        self.tasks: Dict[str, DownloadTask] = {}
        self.progress_callbacks: Dict[str, list] = {}
        self._lock = threading.Lock()

    def get_video_info(self, url: str) -> Dict[str, Any]:
        """URLから動画情報を取得する"""
        ydl_opts = self._base_ydl_opts({
            'extract_flat': False,
        })

        try:
            info = self._extract_info(url, ydl_opts, download=False)

            # フォーマット一覧を整理
            formats = []
            if info.get('formats'):
                for fmt in info['formats']:
                    vcodec = self._safe_str(fmt.get('vcodec'), 'none')
                    acodec = self._safe_str(fmt.get('acodec'), 'none')
                    if vcodec == 'none' and acodec == 'none':
                        continue

                    format_id = self._safe_str(fmt.get('format_id'))
                    ext = self._safe_str(fmt.get('ext'))
                    format_selector = self._format_selector_for_list(format_id, ext, vcodec, acodec)
                    if not format_selector:
                        continue

                    format_info = {
                        'format_id': format_selector,
                        'ext': ext,
                        'resolution': self._safe_str(fmt.get('resolution')),
                        'width': self._safe_int(fmt.get('width')),
                        'height': self._safe_int(fmt.get('height')),
                        'fps': self._safe_float(fmt.get('fps')),
                        'vcodec': vcodec,
                        'acodec': acodec,
                        'filesize': fmt.get('filesize') or fmt.get('filesize_approx', 0),
                        'tbr': self._safe_float(fmt.get('tbr')),
                        'format_note': self._safe_str(fmt.get('format_note')),
                    }
                    # ファイルサイズを人間が読める形式に変換
                    if format_info['filesize']:
                        format_info['filesize_str'] = self._format_size(format_info['filesize'])
                    formats.append(format_info)

            formats.extend(self._audio_conversion_formats())

            result = {
                'id': self._safe_str(info.get('id')),
                'title': self._safe_str(info.get('title')),
                'thumbnail': self._safe_str(info.get('thumbnail')),
                'duration': self._safe_int(info.get('duration')),
                'duration_string': self._format_duration(self._safe_int(info.get('duration'))),
                'uploader': self._safe_str(info.get('uploader')),
                'upload_date': self._safe_str(info.get('upload_date')),
                'view_count': self._safe_int(info.get('view_count')),
                'description': self._safe_str(info.get('description'))[:500],
                'formats': formats,
                'best_format_id': self._safe_str(info.get('format_id')),
            }

            return result

        except yt_dlp.utils.DownloadError as e:
            raise ValueError(f"動画の取得に失敗しました: {str(e)}")
        except Exception as e:
            raise ValueError(f"エラーが発生しました: {str(e)}")

    def start_download(
        self,
        url: str,
        format_id: str = "",
        subtitle: bool = False,
        subtitle_languages: Optional[List[str]] = None,
        duplicate_policy: str = "skip",
    ) -> str:
        """ダウンロードを開始する（バックグラウンドスレッドで実行）"""
        task_id = str(uuid.uuid4())[:8]

        task = DownloadTask(
            task_id=task_id,
            url=url,
            format_id=format_id,
            subtitle=subtitle,
            duplicate_policy=duplicate_policy,
        )

        with self._lock:
            self.tasks[task_id] = task

        # バックグラウンドでダウンロードを実行
        thread = threading.Thread(
            target=self._download_thread,
            args=(
                task_id,
                url,
                format_id,
                subtitle,
                subtitle_languages or ["ja", "en"],
                duplicate_policy,
            ),
            daemon=True,
        )
        thread.start()

        return task_id

    def _download_thread(
        self,
        task_id: str,
        url: str,
        format_id: str,
        subtitle: bool,
        subtitle_languages: List[str],
        duplicate_policy: str,
    ):
        """バックグラウンドでダウンロードを実行するスレッド"""
        task = self.tasks.get(task_id)
        if not task:
            return

        try:
            task.status = DownloadStatus.DOWNLOADING

            # yt-dlpのオプション設定
            output_template = self._output_template(duplicate_policy, task_id)

            ydl_opts = self._base_ydl_opts({
                'outtmpl': output_template,
                'progress_hooks': [lambda d: self._progress_hook(task_id, d)],
                'noprogress': False,
                'overwrites': duplicate_policy == "overwrite",
            })

            ffmpeg_location = self._ffmpeg_location()
            if ffmpeg_location:
                ydl_opts['ffmpeg_location'] = ffmpeg_location

            # フォーマット指定
            audio_conversion_opts = self._audio_conversion_options(format_id)
            if audio_conversion_opts:
                if not self.ffmpeg_available:
                    raise RuntimeError(
                        "音声形式への変換にはffmpegが必要です。"
                        "初期セットアップでffmpegをインストールするか、ffmpeg実行ファイルを選択してください。"
                    )
                ydl_opts.update(audio_conversion_opts)
            else:
                ydl_opts['format'] = self._format_selector(format_id)

            # 字幕設定
            if subtitle:
                ydl_opts['writesubtitles'] = True
                ydl_opts['subtitleslangs'] = subtitle_languages
                ydl_opts['subtitlesformat'] = 'srt'

            info = self._extract_info(url, ydl_opts, download=True)
            if info:
                task.title = info.get('title', '')
                task.thumbnail = info.get('thumbnail', '')
                # ダウンロードされたファイルのパスを取得
                if 'requested_downloads' in info:
                    dl = info['requested_downloads'][0]
                    task.filepath = self._resolve_downloaded_filepath(dl.get('filepath', ''))
                    task.filename = os.path.basename(task.filepath)
                else:
                    task.filename = info.get('title', 'unknown') + '.' + info.get('ext', 'mp4')
                    task.filepath = str(self.download_dir / task.filename)

                if duplicate_policy == "rename":
                    task.filepath = self._rename_with_counter(task.filepath, task_id)
                    task.filename = os.path.basename(task.filepath)

            task.status = DownloadStatus.COMPLETED
            task.progress = 100.0
            self._notify_progress(task_id)

        except Exception as e:
            task.status = DownloadStatus.ERROR
            task.error_message = str(e)
            self._notify_progress(task_id)

    @staticmethod
    def _safe_str(value: Any, default: str = "") -> str:
        if value is None:
            return default
        return str(value)

    @staticmethod
    def _safe_int(value: Any, default: int = 0) -> int:
        if value is None:
            return default
        try:
            return int(value)
        except (TypeError, ValueError):
            return default

    @staticmethod
    def _safe_float(value: Any, default: float = 0.0) -> float:
        if value is None:
            return default
        try:
            return float(value)
        except (TypeError, ValueError):
            return default

    @staticmethod
    def _audio_conversion_formats() -> List[Dict[str, Any]]:
        definitions = [
            ('audio:mp3', 'mp3', 'MP3音声', 'mp3'),
            ('audio:m4a', 'm4a', 'M4A音声', 'aac'),
            ('audio:wav', 'wav', 'WAV音声', 'pcm_s16le'),
            ('audio:flac', 'flac', 'FLAC音声', 'flac'),
            ('audio:opus', 'opus', 'OPUS音声', 'opus'),
        ]

        return [
            {
                'format_id': format_id,
                'ext': ext,
                'resolution': 'audio only',
                'width': 0,
                'height': 0,
                'fps': 0.0,
                'vcodec': 'none',
                'acodec': acodec,
                'filesize': 0,
                'tbr': 0.0,
                'format_note': note,
            }
            for format_id, ext, note, acodec in definitions
        ]

    def _audio_conversion_options(self, format_id: str) -> Optional[Dict[str, Any]]:
        conversions = {
            'audio:mp3': ('mp3', '192', 'bestaudio/best'),
            'audio:m4a': ('m4a', None, 'bestaudio[ext=m4a]/bestaudio/best'),
            'audio:wav': ('wav', None, 'bestaudio/best'),
            'audio:flac': ('flac', None, 'bestaudio/best'),
            'audio:opus': ('opus', None, 'bestaudio[ext=webm][acodec=opus]/bestaudio/best'),
        }
        conversion = conversions.get(format_id)
        if not conversion:
            return None

        codec, quality, selector = conversion
        postprocessors: List[Dict[str, Any]] = []
        extract_audio: Dict[str, Any] = {
            'key': 'FFmpegExtractAudio',
            'preferredcodec': codec,
        }
        if quality:
            extract_audio['preferredquality'] = quality

        postprocessors.append(extract_audio)

        return {
            'format': selector,
            'postprocessors': postprocessors,
            'keepvideo': False,
        }

    def _resolve_downloaded_filepath(self, filepath: str) -> str:
        if not filepath:
            return ""

        path = Path(filepath)
        if path.is_file():
            return str(path)

        for candidate in path.parent.glob(f"{path.stem}.*"):
            if candidate.is_file() and not candidate.name.endswith(('.part', '.ytdl')):
                return str(candidate)

        return filepath

    def _output_template(self, duplicate_policy: str, task_id: str) -> str:
        if duplicate_policy == "rename":
            return str(self.download_dir / f"%(title)s.__ytdlp_tmp_{task_id}.%(ext)s")
        return str(self.download_dir / "%(title)s.%(ext)s")

    def _rename_with_counter(self, filepath: str, task_id: str) -> str:
        path = Path(filepath)
        if not path.is_file():
            return filepath

        temp_marker = f".__ytdlp_tmp_{task_id}"
        base_stem = path.stem.removesuffix(temp_marker)
        base_path = path.with_name(f"{base_stem}{path.suffix}")
        if not base_path.exists():
            path.rename(base_path)
            return str(base_path)

        counter = 1
        while True:
            candidate = path.with_name(f"{base_stem} ({counter}){path.suffix}")
            if not candidate.exists():
                path.rename(candidate)
                return str(candidate)
            counter += 1

    def _format_selector_for_list(self, format_id: str, ext: str, vcodec: str, acodec: str) -> str:
        if not format_id:
            return ""

        ext = ext.lower()
        has_video = vcodec != "none"
        has_audio = acodec != "none"

        if has_video and has_audio:
            return format_id

        if not has_video and has_audio:
            return format_id

        if ext == "mp4":
            return (
                f"{format_id}+bestaudio[ext=m4a][acodec^=mp4a]/"
                f"{format_id}+bestaudio[ext=m4a]/"
                f"{format_id}+bestaudio/"
                f"{format_id}"
            )

        if ext == "webm":
            return (
                f"{format_id}+bestaudio[ext=webm]/"
                f"{format_id}+bestaudio/"
                f"{format_id}"
            )

        return (
            f"{format_id}+bestaudio/"
            f"{format_id}"
        )

    def _base_ydl_opts(self, extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        opts = {
            'quiet': True,
            'no_warnings': True,
        }
        if self.cookie_file:
            cookie_path = Path(self.cookie_file).expanduser()
            if cookie_path.is_file():
                opts['cookiefile'] = str(cookie_path)

        if extra:
            opts.update(extra)

        return opts

    def _extract_info(self, url: str, ydl_opts: Dict[str, Any], download: bool) -> Dict[str, Any]:
        try:
            return self._run_ydl(url, ydl_opts, download)
        except yt_dlp.utils.DownloadError as original_error:
            if not self._should_retry_with_browser_cookies(original_error):
                raise

            attempted = []
            for browser in self._browser_cookie_candidates():
                attempted.append(browser)
                retry_opts = dict(ydl_opts)
                retry_opts['cookiesfrombrowser'] = (browser, None, None, None)
                try:
                    return self._run_ydl(url, retry_opts, download)
                except Exception:
                    continue

            if attempted:
                raise yt_dlp.utils.DownloadError(
                    f"{original_error}. ブラウザCookieでも再試行しましたが失敗しました: {', '.join(attempted)}"
                )
            raise

    def _run_ydl(self, url: str, ydl_opts: Dict[str, Any], download: bool) -> Dict[str, Any]:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            return ydl.extract_info(url, download=download)

    def _should_retry_with_browser_cookies(self, error: Exception) -> bool:
        if self.cookie_file or not self.cookies_from_browser or self.cookies_from_browser == "none":
            return False

        message = str(error).lower()
        cookie_hints = (
            "not a bot",
            "sign in to confirm",
            "cookies-from-browser",
            "use --cookies",
            "authentication",
        )
        return any(hint in message for hint in cookie_hints)

    def _browser_cookie_candidates(self) -> List[str]:
        if not self.cookies_from_browser or self.cookies_from_browser == "none":
            return []

        supported = ["safari", "chrome", "brave", "edge", "chromium", "firefox"]
        if self.cookies_from_browser != "auto":
            return [self.cookies_from_browser]

        home = Path.home()
        browser_paths = {
            "safari": home / "Library/Containers/com.apple.Safari/Data/Library/Cookies",
            "chrome": home / "Library/Application Support/Google/Chrome",
            "brave": home / "Library/Application Support/BraveSoftware/Brave-Browser",
            "edge": home / "Library/Application Support/Microsoft Edge",
            "chromium": home / "Library/Application Support/Chromium",
            "firefox": home / "Library/Application Support/Firefox/Profiles",
        }

        candidates = [browser for browser, path in browser_paths.items() if path.exists()]
        return candidates or supported

    def _format_selector(self, format_id: str) -> str:
        if self.ffmpeg_available:
            return format_id or DEFAULT_FORMAT

        if format_id and '+' in format_id:
            raise RuntimeError(
                "ffmpegが見つからないため、映像と音声の結合が必要な形式はダウンロードできません。"
                "Homebrewで ffmpeg をインストールするか、単一ファイル形式を選択してください。"
            )

        return format_id or 'best[ext=mp4][vcodec!=none][acodec!=none]/best[vcodec!=none][acodec!=none]/best'

    def _ffmpeg_location(self) -> Optional[str]:
        if not self.ffmpeg_available or not self.ffmpeg_path:
            return None

        path = Path(self.ffmpeg_path).expanduser()
        if path.is_file():
            return str(path.parent)
        return str(path)

    @staticmethod
    def _is_executable_available(path: Optional[str]) -> bool:
        if not path:
            return False

        expanded = Path(path).expanduser()
        if expanded.is_file() and os.access(expanded, os.X_OK):
            return True

        return shutil.which(path) is not None

    def _progress_hook(self, task_id: str, d: Dict[str, Any]):
        """yt-dlpの進捗フック"""
        task = self.tasks.get(task_id)
        if not task:
            return

        if d['status'] == 'downloading':
            task.status = DownloadStatus.DOWNLOADING
            task.downloaded_bytes = d.get('downloaded_bytes', 0)
            task.total_bytes = d.get('total_bytes') or d.get('total_bytes_estimate', 0)
            task.speed = d.get('speed', 0)
            task.eta = d.get('eta', 0)

            if task.total_bytes > 0:
                task.progress = round((task.downloaded_bytes / task.total_bytes) * 100, 1)

            self._notify_progress(task_id)

        elif d['status'] == 'finished':
            task.status = DownloadStatus.PROCESSING
            task.progress = 95.0
            task.filename = os.path.basename(d.get('filename', ''))
            self._notify_progress(task_id)

        elif d['status'] == 'error':
            task.status = DownloadStatus.ERROR
            self._notify_progress(task_id)

    def cancel_download(self, task_id: str) -> bool:
        """ダウンロードをキャンセルする"""
        task = self.tasks.get(task_id)
        if task and task.status in (DownloadStatus.PENDING, DownloadStatus.DOWNLOADING):
            task.status = DownloadStatus.CANCELLED
            self._notify_progress(task_id)
            return True
        return False

    def get_task(self, task_id: str) -> Optional[Dict[str, Any]]:
        """タスクの情報を取得する"""
        task = self.tasks.get(task_id)
        if not task:
            return None

        return {
            'task_id': task.task_id,
            'url': task.url,
            'status': task.status.value,
            'format_id': task.format_id,
            'duplicate_policy': task.duplicate_policy,
            'progress': task.progress,
            'speed': self._format_speed(task.speed),
            'eta': self._format_eta(task.eta),
            'total_bytes': task.total_bytes,
            'downloaded_bytes': task.downloaded_bytes,
            'total_bytes_str': self._format_size(task.total_bytes),
            'downloaded_bytes_str': self._format_size(task.downloaded_bytes),
            'filename': task.filename,
            'filepath': task.filepath,
            'thumbnail': task.thumbnail,
            'title': task.title,
            'error_message': task.error_message,
        }

    def get_all_tasks(self) -> List[Dict[str, Any]]:
        """全タスクの一覧を取得する"""
        return [self.get_task(tid) for tid in self.tasks]

    def clear_completed(self):
        """完了したタスクをクリアする"""
        with self._lock:
            to_remove = [
                tid for tid, task in self.tasks.items()
                if task.status in (DownloadStatus.COMPLETED, DownloadStatus.ERROR, DownloadStatus.CANCELLED)
            ]
            for tid in to_remove:
                del self.tasks[tid]

    def register_progress_callback(self, task_id: str, callback):
        """進捗コールバックを登録する"""
        if task_id not in self.progress_callbacks:
            self.progress_callbacks[task_id] = []
        self.progress_callbacks[task_id].append(callback)

    def unregister_progress_callback(self, task_id: str, callback):
        """進捗コールバックを解除する"""
        if task_id in self.progress_callbacks:
            self.progress_callbacks[task_id] = [
                cb for cb in self.progress_callbacks[task_id] if cb != callback
            ]

    def _notify_progress(self, task_id: str):
        """登録されたコールバックに進捗を通知する"""
        task_data = self.get_task(task_id)
        if task_data and task_id in self.progress_callbacks:
            for callback in self.progress_callbacks[task_id]:
                try:
                    callback(task_data)
                except Exception:
                    pass

    @staticmethod
    def _format_size(size_bytes: float) -> str:
        """バイト数を人間が読める形式に変換"""
        if not size_bytes:
            return "0 B"
        units = ["B", "KB", "MB", "GB", "TB"]
        i = 0
        size = float(size_bytes)
        while size >= 1024.0 and i < len(units) - 1:
            size /= 1024.0
            i += 1
        return f"{size:.1f} {units[i]}"

    @staticmethod
    def _format_speed(speed: float) -> str:
        """速度を人間が読める形式に変換"""
        if not speed:
            return "0 B/s"
        return f"{DownloadManager._format_size(speed)}/s"

    @staticmethod
    def _format_eta(seconds: float) -> str:
        """ETAを人間が読める形式に変換"""
        if not seconds or seconds <= 0:
            return "計算中..."
        minutes = int(seconds // 60)
        secs = int(seconds % 60)
        if minutes > 60:
            hours = minutes // 60
            minutes = minutes % 60
            return f"{hours}時間{minutes}分{secs}秒"
        return f"{minutes}分{secs}秒"

    @staticmethod
    def _format_duration(seconds: float) -> str:
        """再生時間を人間が読める形式に変換"""
        if not seconds:
            return "0:00"
        hours = int(seconds // 3600)
        minutes = int((seconds % 3600) // 60)
        secs = int(seconds % 60)
        if hours > 0:
            return f"{hours}:{minutes:02d}:{secs:02d}"
        return f"{minutes}:{secs:02d}"
