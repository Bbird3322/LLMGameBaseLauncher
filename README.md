# AIgameBasesys (Local llama.cpp Game Base)

llama.cpp をローカル実行基盤として使う、開発者向けテキストRPGベースです。
ゲーム UI、ローカル配信、llama-server 起動管理を最初から分離しているので、
「とりあえず遊べる雛形」を起点にゲームロジックを積みやすい構成になっています。
Pythonの環境構築や複雑なライブラリのインストールなしで、**「フォルダをコピーするだけで他のPCでも動く」**設計になっています。

使うだけの人は、まず [`HOW_TO_USE.md`](<./HOW_TO_USE.md>) を見てください。

## 動作機序
このシステムは、フロントエンドが直接 AI と話すのではなく、**中継役**を挟むことで、複数の AI を一括制御しています。

どの言語で書く場合も、以下のステップは共通です。

1. JSONデータの作成: モデルに送る「指示（System）」と「会話履歴（User/Assistant）」を JSON 形式でまとめます。
2. HTTP POST 送信: 中継サーバー（既定：localhost:4173/api/chat）に対してデータを送ります。
3. リームまたは一括受信: AI からの返答（JSON）を受け取り、必要なテキスト部分だけを抽出します。

### マルチエージェントの仕組み
scripts/serve-game.ps1 が、各 AI（ポート 8080, 8081...）への交通整理を行っています。

- JSの場合: askOneAgent(payload, agentIndex) のようにインデックスを指定して呼び出します。

- 他の言語の場合: 直接各ポート（http://127.0.0.1:8080/v1/chat/completions など）を叩くことで、プロキシを介さず個別に情報を拾うことも可能です。「HTTPリクエストが送れること」と「JSONが扱えること」さえ満たせば、どんな言語でもEXE化してAIを組み込めます。

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

### index.html / game.js の改変ポイント

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

## 最短起動

1. `test/START.bat` か `LLMGameBaseLauncher.exe` を実行
2. GUI でモデル選択、ゲーム開始、全停止を操作する

起動時は小さな待機ポップアップが出て、GUI が開いたら自動で閉じます。
ログは `logs/` に出力され、ランチャー例外時のレポートは `logs/error/launcher-error.txt` に保存されます。

### モデルの入れ方

1. `.gguf` ファイルを `llama-runtime/models/`に置く
2. `test\START.bat` を実行してランチャーを開く
3. モデル一覧から追加したモデルを選ぶ
4. `Start llama-server` を押す

補足:

- 既定では `llama-runtime/models/` を使います
- ファイル名は自由ですが拡張子は `.gguf` が必要です
- ランチャーに出ない場合は `Refresh` を押してください

### 複数AIの起動

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

## フォルダ構成

初見でも把握しやすいように、用途ごとにまとめると次の通りです。

- `index.html`
  - ゲーム画面（UI）の本体
- `game.js`
  - ブラウザ側のゲーム進行ロジック（入力処理、表示更新、`/api/chat` 呼び出し）

- `scripts/`
  - 運用用スクリプト置き場
  - 例: ランチャー GUI 起動、llama-server 起動/停止、ローカル配信サーバー、EXE ビルド
- `test/`
  - 開発確認用の起動入口
  - `START.bat` / `START.ps1` から起動確認するときに使う
- `release/`
  - 配布用入口スクリプト置き場
  - `LauncherEntry.ps1` は EXE 化時のエントリ

- `llama-runtime/`
  - llama.cpp 実行物とモデルをまとめる実行基盤フォルダ
- `llama-runtime/cpu/`
  - CPU 実行用の `llama-server.exe` と関連 DLL
- `llama-runtime/gpu/`
  - GPU 実行用の `llama-server.exe` と関連 DLL
- `llama-runtime/models/`
  - `.gguf` モデル配置先

- `config/`
  - ランチャーが読む設定ファイル置き場（実行時に自動生成/更新あり）

- `logs/`
  - ランチャーや各プロセスのログ出力先
  - 代表例: `launcher-startup.log`, `llama-<agent-id>.stdout.log`, `llama-<agent-id>.stderr.log`, `local-server.stdout.log`, `local-server.stderr.log`
- `logs/error/`
  - ランチャー例外レポート `launcher-error.txt` の保存先

## コンフィグのいじり方

`scripts/llama-server.env.bat` はランチャーが自動生成するローカル設定ファイルです。
GitHub には含めない前提なので、開発マシンごとの絶対パスや実験用設定をそのまま置けます。

### config 配下で自動生成されるファイルと作成条件

`config/` は、必要になったタイミングでランチャーが自動作成します（初回起動直後に全ファイルが必ず揃うわけではありません）。

- `config/runtimeProfile.json`
  - 生成/更新条件: `Start llama-server` 実行時、`設定のインポート` 実行時、`AI設定のみ初期化` / `すべて初期化` 実行時
  - 用途: 現在の実行先URL、モード（CPU/GPU）、有効AI一覧などの「実行時スナップショット」

- `config/agentsProfile.json`
  - 生成/更新条件: `AIモデルを保存` 実行時、`Start llama-server` 実行時、`設定のインポート` 実行時、`AI設定のみ初期化` / `すべて初期化` 実行時
  - 用途: AI 一覧（`id` / `name` / `enabled` / `modelPath` / `llamaPort` など）の保存

- `config/bootSettings.json`
  - 生成/更新条件: `起動構成を保存` 実行時
  - 用途: 起動構成タブの入力状態（モデルフォルダ、CPU/GPU実行パス、既定Host/Port/NGL/CTX など）

- `config/uiSettings.json`
  - 生成/更新条件: `言語` の `適用` 実行時、`設定のインポート` 実行時
  - 用途: UI 言語（`ja` / `en`）

- `config/launchProfiles.json`
  - 生成/更新条件: 設定タブの `プロファイル保存` 実行時
  - 用途: 名前付きプロファイル（envMap と agents の組）

- `config/backups/settings_<reason>_<timestamp>.json`
  - 生成条件: `起動構成のみ初期化` / `AI設定のみ初期化` / `すべて初期化` 実行前、または `更新実行` の直前
  - 用途: リセットやアップデート前の退避スナップショット

補足:

- `scripts/serve-game.ps1` は `config/runtimeProfile.json` を参照して中継先 URL を決めます（無い場合は `http://127.0.0.1:8080` を使用）。
- そのため、実運用では最初に一度 `Start llama-server` を実行して `runtimeProfile.json` を生成しておくと分かりやすいです。

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
- `config/*.json` と `logs/` はローカル生成物として `.gitignore` 対象です
- 設定を変えたら、一度 `Stop All` してから再起動すると反映が確実です
- CUDA runtime が無い環境では、GPU モードを選んでいても CPU モードへ自動で切り替えて起動します
- 設定タブのアップデート機能は、Git 管理された開発コピーでのみ動作します

## ログの見方

ログは、次のように出力されます。

- `logs/launcher-startup.log`
  - ランチャー起動時のトレース（起動のたびに先頭から作り直し）
- `logs/llama-<agent-id>.stdout.log`
  - 各 llama-server プロセスの標準出力
- `logs/llama-<agent-id>.stderr.log`
  - 各 llama-server プロセスの標準エラー
- `logs/local-server.stdout.log`
  - `scripts/serve-game.ps1` の標準出力
- `logs/local-server.stderr.log`
  - `scripts/serve-game.ps1` の標準エラー
- `logs/error/launcher-error.txt`
  - ランチャーが捕捉した例外の詳細（Open game 失敗、Import 失敗、起動失敗など）

補足:

- ランチャーの「ログ」タブに表示されるのは、`logs/` 直下の `.log` / `.txt` です（`logs/error/` はサブフォルダのため一覧には出ません）。
- タイムアウト時は `llama-*.stderr.log` や `local-server.stderr.log` の末尾が、エラーダイアログ詳細にも取り込まれます。

### エラーコードの見方

`/api/chat` でエラーが起きたら、まず `logs/local-server.stderr.log` と `logs/error/launcher-error.txt` を確認します。

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
3. `logs/local-server.stderr.log` を確認し、必要なら `/api/chat` のレスポンス本文に出る `detail` と `upstreamBody` も確認

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

## トラブルシューティング
### 長時間プレイすると遅くなる / 途中で応答に失敗する

症状:

- ターンが進むほど返答が遅くなる
- 途中から `HTTP 400` や `HTTP 502` が混じる
- 返答品質が落ちたり、急に文脈が崩れる

原因:

- `game.js` は会話履歴 `history` を毎ターンそのまま `messages` に送っています
- 履歴を削る処理がないため、長時間プレイするとプロンプトが肥大化します
- 既定の `LLAMA_CTX` は `8192` です。モデルや設定によっては、この文脈上限に近づくほど遅延や失敗が起きやすくなります
- 初期値は `scripts/launch-llama-server.ps1` の `New-DefaultEnvMap()` で設定されています。

対策:

- 履歴を一定件数で間引く
- 残すのは `system` と直近数往復だけにする
- 必要ならランチャーの `LLAMA_CTX` を増やす
- ただし `LLAMA_CTX` を増やすと RAM / VRAM 使用量も増えるため、重いモデルでは逆に不安定になることがあります

実装例:

```javascript
function truncateHistory() {
  const MAX_HISTORY_LENGTH = 15;

  if (history.length > MAX_HISTORY_LENGTH) {
    // system は残して、古い会話から削る
    history.splice(1, history.length - MAX_HISTORY_LENGTH);
  }
}

async function sendTurn() {
  const userText = inputEl.value.trim();
  if (!userText) return;

  history.push({ role: "user", content: userText });
  truncateHistory();

  const payload = {
    model: "local-model",
    messages: history,
    temperature: 0.8,
    max_tokens: 300
  };

  // ...
}
```

補足:

- `max_tokens` は「返答の最大長」です。大きいほど長文を返せますが、そのぶん生成時間も伸びやすくなります
- `LLAMA_CTX` は「モデルに渡せる文脈長」です。`history` が長いほど多く消費します
- `max_tokens` と `LLAMA_CTX` は別物です。`max_tokens` を減らしても、履歴が長すぎる問題そのものは解決しません

### 長文生成で `Fetch failed` や `HTTP 502` になる

症状:

- 長い描写を出させたときだけ失敗する
- ブラウザ側では `fetch` 失敗のように見える
- `HTTP 502` や `llama_proxy_failed` が返る

原因:

- ローカル中継サーバー `scripts/serve-game.ps1` は upstream への `Invoke-WebRequest` に `TimeoutSec 90` を設定しています
- つまり 90 秒を超える生成は、中継側タイムアウトで失敗しやすくなります

対策:

- `game.js` の `max_tokens` を下げる
- プロンプトに「簡潔に」「3行以内」など、出力長の制約を書く
- 必要なら、より軽いモデルに変える
- マルチAIで同時本数を増やしている場合は、まず 1 体で再現するか確認する

### 起動直後に `502 Bad Gateway` になる

症状:

- 起動直後にゲームを開いてすぐ送信すると失敗する

原因:

- `llama-server` はモデル読み込み完了まで数秒から数十秒かかることがあります
- ランチャーから通常手順で開く場合は、ランチャー側が `/health` を待ってからゲームを開くため、この問題は起きにくいです
- ただし、手動で先にブラウザを開いた場合や、独自に `index.html` へ直接アクセスした場合は起こりえます

対策:

- まずはランチャーの `Start llama-server` を使い、準備完了後に `Open game` する
- 手動起動を許す構成にするなら、ブラウザ側でも送信前に llama 側の `/health` を待つ

### ランチャーから起動するとすぐ落ちる / 黒い画面が一瞬出て終わる

よくある原因:

- VRAM 不足
- CUDA runtime 不足
- GPU モードなのに NVIDIA GPU が無い
- `llama-server.exe` のパス不正
- モデルファイル不在

対策:

- GPU モードなら `LLAMA_NGL` を下げる
- それでも不安定なら CPU モードに切り替える
- より小さい `.gguf` モデルに変える
- ログとして `logs/llama-<agent-id>.stderr.log` を確認する

### モデルファイルが見つからない

症状:

- 起動時に「モデルファイルが存在しません」と表示される

原因:

- AI設定で指定された `modelPath` に `.gguf` が存在しません

対策:

- `llama-runtime/models/` に対象ファイルがあるか確認する
- ランチャーの `AIモデル` タブで正しいモデルを選び直す
- 拡張子が `.gguf` になっているか確認する

## ライセンス
本製品は MIT License の第三者コンポーネントを含みます。詳細は [THIRD_PARTY_NOTICES.txt](<./licence/THIRD_PARTY_NOTICES.txt>) を参照してください