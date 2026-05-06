"""
YT-Downloader - FastAPI Server
動画ダウンロードAPIサーバー
"""

import asyncio
import json
import subprocess
from pathlib import Path
from typing import Optional, List

import yt_dlp
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Query
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

from config import (
    HOST,
    PORT,
    DOWNLOAD_DIR,
    LOG_LEVEL,
    DEFAULT_FORMAT,
    DEFAULT_SUBTITLE_LANGUAGES,
    FFMPEG_PATH,
    FFPROBE_PATH,
    YTDLP_PATH,
    YTDLP_COOKIE_FILE,
    YTDLP_COOKIES_FROM_BROWSER,
)
from downloader import DownloadManager, DownloadStatus


app = FastAPI(
    title="YT-Downloader Server",
    description="yt-dlpを使った動画ダウンロードAPI",
    version="1.0.0",
)

# CORS設定（ローカルアプリからのアクセスを許可）
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ダウンロードマネージャーを初期化
download_manager = DownloadManager(
    download_dir=str(DOWNLOAD_DIR),
    ffmpeg_path=FFMPEG_PATH,
    cookie_file=YTDLP_COOKIE_FILE,
    cookies_from_browser=YTDLP_COOKIES_FROM_BROWSER,
)

# WebSocket接続管理
active_connections: dict[str, list[WebSocket]] = {}


# === Request Models ===

class DownloadRequest(BaseModel):
    url: str
    format_id: str = ""
    subtitle: bool = False
    subtitle_languages: List[str] = DEFAULT_SUBTITLE_LANGUAGES
    duplicate_policy: str = "skip"


class FilePathRequest(BaseModel):
    filepath: str


# === API Endpoints ===

@app.get("/")
async def root():
    """サーバーの状態を確認する"""
    return {
        "service": "YT-Downloader Server",
        "version": "1.0.0",
        "status": "running",
        "downloads_dir": str(DOWNLOAD_DIR),
        "active_tasks": len([
            t for t in download_manager.tasks.values()
            if t.status in (DownloadStatus.DOWNLOADING, DownloadStatus.PROCESSING, DownloadStatus.PENDING)
        ]),
    }


@app.get("/api/video/info")
async def get_video_info(url: str = Query(..., description="動画のURL")):
    """
    動画の情報（タイトル、サムネイル、フォーマット一覧など）を取得する
    """
    try:
        info = await run_in_threadpool(download_manager.get_video_info, url)
        return info
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"動画情報の取得中にエラーが発生しました: {str(e)}")


@app.post("/api/download")
async def start_download(request: DownloadRequest):
    """
    動画のダウンロードを開始する
    """
    try:
        task_id = await run_in_threadpool(
            download_manager.start_download,
            url=request.url,
            format_id=request.format_id,
            subtitle=request.subtitle,
            subtitle_languages=request.subtitle_languages,
            duplicate_policy=request.duplicate_policy,
        )
        return {
            "task_id": task_id,
            "message": "ダウンロードを開始しました",
            "status": download_manager.get_task(task_id),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"ダウンロードの開始に失敗しました: {str(e)}")


@app.get("/api/download/status/{task_id}")
async def get_download_status(task_id: str):
    """
    ダウンロードタスクのステータスを取得する
    """
    task = download_manager.get_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="指定されたタスクが見つかりません")
    return task


@app.get("/api/download/tasks")
async def get_all_tasks():
    """
    全ダウンロードタスクの一覧を取得する
    """
    tasks = download_manager.get_all_tasks()
    # 新しい順にソート
    tasks.reverse()
    return {"tasks": tasks, "total": len(tasks)}


@app.post("/api/download/cancel/{task_id}")
async def cancel_download(task_id: str):
    """
    ダウンロードをキャンセルする
    """
    success = download_manager.cancel_download(task_id)
    if not success:
        raise HTTPException(status_code=400, detail="キャンセルできません（タスクが存在しないか、すでに完了しています）")
    return {"message": "ダウンロードをキャンセルしました", "task_id": task_id}


@app.post("/api/download/clear")
async def clear_completed():
    """
    完了したタスクをクリアする
    """
    download_manager.clear_completed()
    return {"message": "完了したタスクをクリアしました"}


@app.get("/api/downloads")
async def get_downloaded_files():
    """
    ダウンロード済みファイルの一覧を取得する
    """
    files = []
    for file_path in DOWNLOAD_DIR.iterdir():
        if file_path.is_file() and not file_path.name.startswith('.'):
            stat = file_path.stat()
            files.append({
                "name": file_path.name,
                "path": str(file_path),
                "size": stat.st_size,
                "size_str": download_manager._format_size(stat.st_size),
                "modified": stat.st_mtime,
            })

    # 更新日時の新しい順にソート
    files.sort(key=lambda f: f["modified"], reverse=True)
    return {"files": files, "total": len(files)}


@app.get("/api/downloads/open")
@app.post("/api/downloads/open")
async def open_download_folder():
    """
    ダウンロードフォルダをFinderで開く
    """
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    subprocess.Popen(["open", str(DOWNLOAD_DIR)])
    return {"message": f"Finderで開きました: {DOWNLOAD_DIR}"}


@app.post("/api/downloads/open-file")
async def open_file(request: FilePathRequest):
    """
    ファイルをデフォルトアプリで開く
    """
    file = resolve_download_file(request.filepath)
    subprocess.Popen(["open", str(file)])
    return {"message": f"ファイルを開きました: {file.name}"}


@app.post("/api/downloads/reveal-file")
async def reveal_file(request: FilePathRequest):
    """
    ファイルをFinderで表示する
    """
    file = resolve_download_file(request.filepath)
    subprocess.Popen(["open", "-R", str(file)])
    return {"message": f"Finderで表示しました: {file.name}"}


@app.post("/api/downloads/delete")
async def delete_file(request: FilePathRequest):
    """
    ダウンロード済みファイルを削除する
    """
    file = resolve_download_file(request.filepath)
    file.unlink()
    return {"message": f"ファイルを削除しました: {file.name}"}


def resolve_download_file(filepath: str) -> Path:
    file = Path(filepath).expanduser().resolve()
    download_dir = DOWNLOAD_DIR.resolve()

    if not file.exists():
        raise HTTPException(status_code=404, detail="ファイルが見つかりません")
    if not file.is_file():
        raise HTTPException(status_code=400, detail="ファイルではありません")
    if not file.is_relative_to(download_dir):
        raise HTTPException(status_code=403, detail="アクセス権限がありません")

    return file


# === WebSocket ===

@app.websocket("/ws/progress/{task_id}")
async def websocket_progress(websocket: WebSocket, task_id: str):
    """
    ダウンロード進捗のリアルタイム通知（WebSocket）
    """
    await websocket.accept()

    if task_id not in active_connections:
        active_connections[task_id] = []
    active_connections[task_id].append(websocket)

    # 初期状態を送信
    task = download_manager.get_task(task_id)
    if task:
        await websocket.send_json(task)

    # コールバックを登録して進捗をリアルタイム通知
    progress_queue = asyncio.Queue()

    def on_progress(task_data):
        try:
            asyncio.get_event_loop().call_soon_threadsafe(progress_queue.put_nowait, task_data)
        except RuntimeError:
            pass

    download_manager.register_progress_callback(task_id, on_progress)

    try:
        while True:
            # 定期的にステータスを送信
            try:
                task_data = await asyncio.wait_for(progress_queue.get(), timeout=2.0)
                await websocket.send_json(task_data)

                # 完了・エラー・キャンセルで終了
                if task_data['status'] in (
                    DownloadStatus.COMPLETED.value,
                    DownloadStatus.ERROR.value,
                    DownloadStatus.CANCELLED.value,
                ):
                    break
            except asyncio.TimeoutError:
                # タイムアウト時はキープアライブ
                await websocket.send_json({"type": "keepalive"})

    except WebSocketDisconnect:
        pass
    finally:
        download_manager.unregister_progress_callback(task_id, on_progress)
        if task_id in active_connections:
            active_connections[task_id] = [
                ws for ws in active_connections[task_id] if ws != websocket
            ]


# === 設定関連 ===

@app.get("/api/settings")
async def get_settings():
    """現在の設定を取得する"""
    return {
        "download_dir": str(DOWNLOAD_DIR),
        "default_format": DEFAULT_FORMAT,
        "subtitle_languages": DEFAULT_SUBTITLE_LANGUAGES,
        "ffmpeg_path": FFMPEG_PATH or "",
        "cookie_file": YTDLP_COOKIE_FILE or "",
        "cookies_from_browser": YTDLP_COOKIES_FROM_BROWSER,
    }


@app.get("/api/health")
async def health_check():
    """ヘルスチェック"""
    # yt-dlpのバージョンを取得
    try:
        ytdlp_version = yt_dlp.version.__version__
        git_head = getattr(yt_dlp.version, "RELEASE_GIT_HEAD", "")
        if git_head:
            ytdlp_version = f"{ytdlp_version} (master {git_head[:7]})"
    except Exception:
        try:
            result = subprocess.run(
                [YTDLP_PATH or "yt-dlp", "--version"],
                capture_output=True,
                text=True,
                timeout=5
            )
            ytdlp_version = result.stdout.strip()
        except Exception:
            ytdlp_version = "unknown"

    return {
        "status": "healthy",
        "ffmpeg": download_manager.ffmpeg_available,
        "ffmpeg_path": FFMPEG_PATH or "",
        "ffprobe_path": FFPROBE_PATH or "",
        "ytdlp_version": ytdlp_version,
        "cookies_from_browser": YTDLP_COOKIES_FROM_BROWSER,
    }


# === サーバー起動 ===

if __name__ == "__main__":
    import uvicorn
    print(f"\n🚀 YT-Downloader Server を起動中...")
    print(f"   URL: http://{HOST}:{PORT}")
    print(f"   API Docs: http://{HOST}:{PORT}/docs")
    print(f"   Downloads: {DOWNLOAD_DIR}")
    print(f"   ffmpeg: {FFMPEG_PATH or 'not found'}")
    print(f"   cookies: {YTDLP_COOKIE_FILE or YTDLP_COOKIES_FROM_BROWSER or 'none'}")
    print()

    uvicorn.run(
        "main:app",
        host=HOST,
        port=PORT,
        log_level=LOG_LEVEL,
        reload=False,
    )
