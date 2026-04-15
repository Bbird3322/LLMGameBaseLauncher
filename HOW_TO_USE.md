# HOW TO USE

このファイルは、「開発はしないで使うだけ」の人向けの最短ガイドです。

## 先に知っておくこと

- Visual Studio の C/C++ コンパイラは不要です
- このプロジェクトには `llama-runtime/` 配下に `llama-server.exe` などの実行ファイルが同梱されています
- 必要になることがあるのは、C/C++ コンパイラではなく実行用ランタイムです

## 必要なもの

- Windows
- PowerShell が使える環境
- `.gguf` 形式のモデルファイル

環境によって追加で必要なもの:

- CPU モードだけ使う場合
  - Microsoft Visual C++ 再頒布可能パッケージが必要になる場合があります
- GPU モードを使う場合
  - NVIDIA GPU
  - CUDA runtime
  - `cublas64_13.dll` など、GPU 版 `llama-server.exe` が要求する DLL

## 最初の手順

1. `.gguf` ファイルを[Hugging-Face](https://huggingface.co/)もしくはファイル内のダウンローダ `HF-GGUF-Downloader.exe` から `llama-runtime\models\` に置く
2. `LLMGameBaseLauncher.exe` を起動する
3. EXE がない場合は `test\START.bat` を使う
4. ランチャーでモデルを選ぶ
5. `Start llama-server` を押す
6. `Open Game` でゲーム画面を開く

## うまく起動しないとき

### EXE や BAT は開くが、llama-server が起動しない

確認すること:

- `.gguf` が `llama-runtime\models\` にあるか
- モデル一覧にそのファイルが見えているか
- CPU モードで起動できるか

### GPU モードだけ失敗する

まず疑うもの:

- NVIDIA GPU があるか
- CUDA runtime が入っているか
- `cublas64_13.dll` が見つかるか

GPU がだめでも、CPU モードなら起動できることがあります。

### 起動時にエラーが出る

- `logs\` を確認してください
- 詳しい内容は `logs\error\` に出ることがあります

## 開発者向けではない人へ

- EXE を使うだけなら、`ps2exe` の導入は不要です
- Visual Studio のインストールも不要です
- ソースを編集したり EXE を再生成したい人だけ、`README.md` を読んでください
