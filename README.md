# AIgameBasesys (Local llama.cpp Game Base)

llama.cpp をローカル実行基盤として使う、開発者向けテキストRPGベースです。
ゲーム UI、ローカル配信、llama-server 起動管理を最初から分離しているので、
「とりあえず遊べる雛形」を起点にゲームロジックを積みやすい構成になっています。

## 最短起動

1. `START.bat` か `LLMGameBaseLauncher.exe` を実行
2. GUI でモデル選択、ゲーム開始、全停止を操作する

`LLMGameBaseLauncher.exe` は `release\LauncherEntry.ps1` から生成した配布用ランチャーです。
`START.bat` はリポジトリ直下の共通入口で、開発時は `test\START.bat` に中継します。
`test\START.bat` は開発用入口で、常に EXE 化せず `test\START.ps1` を直接試せます。
エラーやクラッシュは `logs/` に TXT で保存され、ポップアップでも通知されます。

起動時は小さな待機ポップアップが出て、GUI が開いたら自動で閉じます。
エラー系ログは `logs/error/` に分けて保存されます。

## EXEビルド（正式版向け）

PowerShell で以下を実行すると、`ps2exe` を使って EXE を生成します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-exe.ps1
```

生成物:

- `LLMGameBaseLauncher.exe`

起動確認やデバッグは `test\START.bat`、配布確認は `LLMGameBaseLauncher.exe` を使い分けます。

## フォルダ構成

- `index.html` / `game.js`
  - ブラウザ側のゲーム UI と進行ロジック
- `scripts/`
  - 起動、停止、ローカル HTTP サーバー、ランチャー GUI
- `llama-runtime/`
  - CPU/GPU 別の `llama-server.exe` と関連 DLL
- `models/`
  - `.gguf` モデル配置先
- `config/runtimeProfile.json`
  - ランチャーが出力する実行時プロファイル（自動生成）
- `config/agentsProfile.json`
  - AI エージェント一覧と各ポート・モデル設定

## モデルの入れ方

1. `.gguf` ファイルを `llama-runtime/models/`に置く
2. `test\START.bat` を実行してランチャーを開く
3. モデル一覧から追加したモデルを選ぶ
4. `Start llama-server` を押す

補足:

- 既定では `llama-runtime/models/` を使います
- ファイル名は自由ですが拡張子は `.gguf` が必要です
- ランチャーに出ない場合は `Refresh` を押してください

## 複数AIの起動

このランチャーは、1つのモデルだけでなく複数の AI を同時に起動できます。各 AI は独立した設定として扱われ、一覧では `No` / `ID` / `名前` / `モデル` で管理します。

使い方:

1. `AIモデル` タブで使いたい `.gguf` を登録する
2. `起動構成` タブで AI を追加する
3. 各行に `名前` と `モデル` を割り当てる
4. 必要なら並列起動する AI を有効化する
5. `Start llama-server` でまとめて起動する

補足:

- 1体だけ動かす場合は、1行だけ設定すれば十分です
- 複数体を動かす場合は、同じモデルを複数 AI に割り当てることもできます
- 起動中の AI は、ランチャー側で個別に名前とモデルを確認できます
- 設定は `config/agentsProfile.json` に保存されます

### 設定ファイルのイメージ

複数 AI は、実際には「名前つきの起動設定の配列」として扱うと分かりやすいです。

```json
[
  {
    "id": "gm-1",
    "name": "GM",
    "model": "gemma-4-e4b-it-f16.gguf",
    "enabled": true
  },
  {
    "id": "judge-1",
    "name": "Judge",
    "model": "gemma-4-e2b-it-Q8_0.gguf",
    "enabled": true
  }
]
```

この形にしておくと、ランチャーは各 AI を個別に起動しやすくなり、ゲーム側も `name` や `model` を見て役割分担を作れます。

### 返答の拾い方

現在の `game.js` では、入力を受け取るたびに `Promise.allSettled` で複数の AI に同じ質問を送っています。各 AI の返答は `askOneAgent()` の戻り値 `{ agentIndex, reply }` として受け取り、成功したものだけを後段で使います。

```javascript
const payload = {
  model: "local-model",
  messages: history,
  temperature: 0.8,
  max_tokens: 500
};

const tasks = [];
for (let i = 0; i < agentCount; i += 1) {
  tasks.push(askOneAgent(payload, i + 1));
}

const results = await Promise.allSettled(tasks);
```

この方式のポイントは、1回の入力に対して複数の AI が並列で返答できることです。たとえば、1体目を「GM」、2体目を「副官」、3体目を「判定役」として扱えます。

```javascript
const replies = results
  .filter((result) => result.status === "fulfilled")
  .map((result) => result.value.reply);

const primaryReply = replies[0] ?? "応答なし";
```

`game.js` の今の実装では、最初に成功した返答を進行用に採用し、残りはログ表示や比較用に回せます。複数 AI をゲームの中で使う場合は、役割ごとに返答を分けると扱いやすくなります。

```javascript
async function askAgents(userText) {
  const baseMessages = [
    { role: "system", content: systemPrompt },
    ...history,
    { role: "user", content: userText }
  ];

  const payload = {
    model: "local-model",
    messages: baseMessages,
    temperature: 0.8,
    max_tokens: 500
  };

  const agentCount = 3;
  const tasks = Array.from({ length: agentCount }, (_, index) => askOneAgent(payload, index + 1));
  const results = await Promise.allSettled(tasks);

  return results
    .filter((result) => result.status === "fulfilled")
    .map((result) => result.value.reply);
}
```

このとき、ゲームの正解判定や HP の増減はコード側で固定し、AI の返答は「演出」「会話」「提案」にだけ使うのが安全です。

## index.html / game.js の改変ポイント

UIの見た目変更:

- `index.html` の `<style>` を編集します
- 画面レイアウトは `index.html` の `.app`, `.log`, `.row` あたりを調整すると反映されます

ゲーム文面・挙動変更:

- `game.js` の `systemPrompt` を変更すると、GMの口調や出力方針を調整できます
- `game.js` の `history` 初期値を変更すると、開始時シーンを変更できます
- `sendTurn` 内の `temperature` / `max_tokens` で応答のランダム性・長さを調整できます

API連携先の変更:

- ゲーム側は `/api/chat` を呼びます
- 実際の中継先は `scripts/serve-game.ps1` で設定されています

## コンフィグのいじり方

`scripts/llama-server.env.bat` はランチャーが自動生成するローカル設定ファイルです。
GitHub には含めない前提なので、開発マシンごとの絶対パスや実験用設定をそのまま置けます。

よく使う項目:

- `LLAMA_CPP_EXE_CPU` / `LLAMA_CPP_EXE_GPU`
  - `llama-server.exe` の絶対パス
- `LLAMA_MODEL_PATH`
  - 起動時に使う `.gguf` の絶対パス
- `LLAMA_HOST` / `LLAMA_PORT`
  - API待ち受け先（通常は `127.0.0.1` / `8080`）
- `LLAMA_NGL`
  - GPUオフロード層数（`0` でCPUのみ）
- `LLAMA_CTX`
  - コンテキスト長
- `LLAMA_EXTRA_ARGS`
  - 追加の起動引数

補足:

- `config/runtimeProfile.json` はランチャーが自動生成する実行情報です（手動編集は基本不要）
- 設定を変えたら、一度 `Stop All` してから再起動すると反映が確実です
- CUDA runtime が無い環境では、GPU モードを選んでいても CPU モードへ自動で切り替えて起動します
- 設定タブのアップデート機能は、Git 管理された開発コピーでのみ動作します

## エラーコードの見方

エラーが起きたら、まず `logs/error_YYYYMMDD_HHMMSS.txt` を確認します。

よくある HTTP コード:

- `400`
  - リクエスト不正（本文不足など）
- `404`
  - 配信ファイルが見つからない
- `405`
  - メソッド不正（GET/POSTの取り違え）
- `500`
  - サーバー内部エラー
- `502`
  - ゲームサーバーから llama 側への中継失敗

確認の順番:

1. `http://127.0.0.1:8080/health` が `200` か（llama 側）
2. `http://127.0.0.1:4173/__health` が `200` か（ゲームサーバー側）
3. `logs/` の最新 txt に出ている `detail` と `upstreamBody` を確認

## 主要スクリプト

- `test/START.bat`
  - 開発用入口。EXE を使わず `test/START.ps1` を直接起動
- `test/START.ps1`
  - 開発用 PowerShell 入口。EXE 化なしで起動確認するときに使う
- `release/LauncherEntry.ps1`
  - EXE 化専用の入口
- `scripts/launch-llama-server.ps1`
  - GUI 本体。モデル選択、AI 構成、起動、更新、設定保存を担当
- `scripts/serve-game.ps1`
  - 静的配信 + `/api/chat` の llama.cpp 中継
- `scripts/build-exe.ps1`
  - `ps2exe` を使った `LLMGameBaseLauncher.exe` の再生成

## 整理方針

- 配布時の実行ファイルは `LLMGameBaseLauncher.exe` を運用対象にします。

## API経路

- ブラウザ: `POST /api/chat`
- ゲームサーバー: `POST http://127.0.0.1:8080/v1/chat/completions`

## よくある確認

- llama が生きているか:
  - `http://127.0.0.1:8080/health`
- ゲームサーバーが生きているか:
  - `http://127.0.0.1:4173/__health`

## 補足

- `scripts/llama-server.env.bat` はローカル自動生成ファイルで、GitHub には含めません。
- 何も指定しない場合、ランチャーは同梱 `llama-runtime` を優先して使います。

## このベースを基にゲームを作る（開発者向け）

このプロジェクトは、次の 3 層を分けたまま育てると保守しやすいです。

- UI 層
  - `index.html` / `game.js` の表示と入力
- ゲーム状態層
  - HP、フラグ、分岐、セーブデータなどの正解データ
- LLM 通信層
  - `scripts/serve-game.ps1` と llama-server の呼び出し

### 設計方針

- LLMに任せる: 世界描写、会話、演出
- コードで管理する: 数値、分岐、勝敗、セーブデータ

LLMの出力をゲームの真実データにしないことが重要です。

### 変更対象ファイル

- `index.html`
  - 画面要素、HUD、入力UI
- `game.js`
  - ターン処理、状態更新、API送信
- `scripts/serve-game.ps1`
  - `/api/chat` のプロキシ処理
- `scripts/llama-server.env.bat`
  - llama.cpp 実行設定。起動時に無ければ自動生成

### 最小ゲームループ実装例

まずは状態オブジェクトを導入します。

```javascript
const state = {
  chapter: 1,
  turn: 0,
  hp: 10,
  sanity: 10,
  inventory: [],
  flags: {},
  gameOver: false,
  win: false
};
```

次に、1ターン関数を `game.js` に作ります。

```javascript
async function runTurn(playerAction) {
  if (state.gameOver) return;

  state.turn += 1;

  const messages = buildMessagesFromState(state, playerAction);
  const llm = await callChatApi(messages); // 既存 /api/chat を利用

  // 文字列演出はLLMから受ける
  const narration = llm.text;

  // 判定はコード側で確定
  applyRuleEffects(state, playerAction, llm);

  if (state.hp <= 0 || state.sanity <= 0) {
    state.gameOver = true;
    state.win = false;
  }

  if (state.chapter >= 3 && state.flags.bossDefeated) {
    state.gameOver = true;
    state.win = true;
  }

  renderTurnResult(narration, state);
}
```

### LLMプロンプト規約例

`systemPrompt` には、次のような規約を固定するのが安全です。

```text
あなたはゲームマスター。
出力は日本語。
以下のJSON形式で返す:
{
  "text": "情景と結果",
  "choices": ["選択肢1", "選択肢2", "選択肢3"],
  "tags": ["danger", "item"]
}
```

`game.js` 側で JSON parse に失敗した場合は、フォールバック表示に切り替えてゲーム停止を防ぎます。

### セーブ/ロード実装例

```javascript
function saveGame() {
  localStorage.setItem("llmGameSave", JSON.stringify(state));
}

function loadGame() {
  const raw = localStorage.getItem("llmGameSave");
  if (!raw) return false;
  Object.assign(state, JSON.parse(raw));
  return true;
}
```

### 実装順（推奨）

1. `state` 導入
2. `runTurn` 導入
3. 勝敗条件をコード固定
4. セーブ/ロード
5. 章システム（chapter）

この順で進めると、最短で「遊べる版」に到達し、その後の追加（装備、敵AI、分岐シナリオ）も安全に拡張できます。
