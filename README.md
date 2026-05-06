# YT-Downloader

yt-dlpを使ったMac用動画ダウンロードアプリケーションです。

Pythonバックエンド（FastAPI）とSwiftUIフロントエンドで構成されています。

## 🎯 特徴

- **直感的なUI** - macOSネイティブSwiftUIによる美しいインターフェース
- **豊富なフォーマット対応** - YouTube、Twitter/X、ニコニコ動画など2000+サイトに対応
- **リアルタイム進捗表示** - ダウンロード速度、残り時間をリアルタイム表示
- **画質選択** - 利用可能な全フォーマットから自由に画質を選択
- **字幕ダウンロード** - 字幕ファイル（SRT）のダウンロードに対応
- **ファイル管理** - ダウンロード済みファイルの閲覧・検索・削除

## 📋 必要条件

| ソフトウェア | バージョン |
|---|---|
| macOS | 14.0+ (Sonoma) |
| Xcode | 15.0+ |
| Python | 3.10+ |
| ffmpeg | 最新版 |
| yt-dlp | 最新版 |
| Homebrew | 最新版 |

## 🚀 セットアップ

### 1. 初期セットアップ

```bash
# ターミナルで実行
cd yt-dlp-mac-app
chmod +x setup.sh
./setup.sh
```

このスクリプトは以下を自動でインストールします：
- Python3
- ffmpeg
- yt-dlp
- Python依存パッケージ（FastAPI, uvicorn, yt-dlp）

### 2. 手動セットアップ（setup.shを使わない場合）

```bash
# Homebrewで依存ツールをインストール
brew install python3 ffmpeg yt-dlp

# Pythonパッケージをインストール
cd yt-dlp-mac-app
pip3 install -r requirements.txt
```

## 📂 プロジェクト構成

```
yt-dlp-mac-app/
├── setup.sh                          # セットアップスクリプト
├── start_server.sh                   # サーバー起動スクリプト
├── requirements.txt                  # Python依存パッケージ
├── server/                           # Pythonバックエンド
│   ├── __init__.py
│   ├── main.py                       # FastAPIサーバー（メイン）
│   ├── config.py                     # 設定ファイル
│   └── downloader.py                 # yt-dlpラッパー
├── downloads/                        # ダウンロード保存先（自動作成）
└── YTDLPMacApp/                      # Swift/macOSアプリ
    └── YTDLPMacApp/
        ├── YTDLPMacApp.swift         # アプリエントリポイント
        ├── ContentView.swift         # メインビュー
        ├── Models/
        │   └── VideoInfo.swift       # データモデル
        ├── Services/
        │   └── APIClient.swift       # API通信クライアント
        ├── ViewModels/
        │   └── DownloadViewModel.swift # ビューモデル
        ├── Views/
        │   ├── DownloadView.swift    # ダウンロード画面
        │   ├── LibraryView.swift     # ライブラリ画面
        │   └── SettingsView.swift    # 設定画面
        ├── Assets.xcassets/          # アセットカタログ
        └── YTDLPMacApp.entitlements  # エンタイトルメント
```

## 🔧 使い方

### 1. サーバーを起動

```bash
# 方法A: 起動スクリプトを使う
./start_server.sh

# 方法B: 直接実行
cd server
python3 main.py
```

サーバーが起動すると http://127.0.0.1:18765 でAPIが利用可能になります。

### 2. Macアプリを起動

```bash
# Xcodeでプロジェクトを開く
open YTDLPMacApp/YTDLPMacApp.xcodeproj

# またはコマンドラインでビルド＆実行
cd YTDLPMacApp
xcodebuild -scheme YTDLPMacApp -configuration Debug build
```

### 3. アプリで動画をダウンロード

1. URL入力欄に動画のURLを貼り付け（🔍ボタンで検索）
2. 動画情報が表示されるので、画質を選択
3. 「ダウンロード開始」ボタンをクリック
4. 進捗バーでダウンロード状況を確認
5. 完了後、「ライブラリ」タブでファイルを確認

## 🎮 アプリ画面の説明

| タブ | 機能 |
|---|---|
| **ダウンロード** | URL入力、動画情報表示、画質選択、ダウンロード実行 |
| **ライブラリ** | ダウンロード済みファイルの閲覧・検索・開く・削除 |
| **設定** | サーバー接続設定、サーバー情報確認、アプリ設定 |

## ⌨️ ショートカットキー

| キー | 機能 |
|---|---|
| `⌘ + O` | ダウンロードフォルダを開く |
| `⌘ + N` | 検索フィールドにフォーカス |
| `Delete` | 選択ファイルを削除 |

## 🔌 APIエンドポイント

| エンドポイント | メソッド | 説明 |
|---|---|---|
| `/api/video/info?url=` | GET | 動画情報を取得 |
| `/api/download` | POST | ダウンロードを開始 |
| `/api/download/status/{task_id}` | GET | ダウンロード状況を取得 |
| `/api/download/tasks` | GET | 全タスク一覧を取得 |
| `/api/download/cancel/{task_id}` | POST | ダウンロードをキャンセル |
| `/api/downloads` | GET | ダウンロード済みファイル一覧 |
| `/api/downloads/open` | GET | Finderでダウンロードフォルダを開く |
| `/api/health` | GET | サーバー健全性チェック |
| `/ws/progress/{task_id}` | WebSocket | リアルタイム進捗通知 |

APIドキュメントは http://127.0.0.1:18765/docs で確認できます（Swagger UI）。

## ⚠️ 注意事項

- ダウンロードした動画は個人利用に限定してください。著作権を尊重してください。
- YouTubeの利用規約に従ってご利用ください。
- ffmpegは動画のマージやフォーマット変換に必要です。
- サーバー（Python）を先に起動してからアプリを使用してください。

## 📝 ライセンス

このプロジェクトは個人利用を目的としています。
yt-dlpはPublic Domainでリリースされています。
