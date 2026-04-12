# AIgameBasesys (Local llama.cpp Game Base)

llama.cpp を使ってローカルで動かす、テキストRPG母体です。

## 最短起動

1. `START.exe` を実行（なければ `START.bat`）
2. GUI でモデル選択、ゲーム開始、全停止を操作する

`START.exe` は `START.ps1` から生成したランチャーです。
`START.bat` はフォールバック入口で、実際のGUIは `scripts/launch-llama-server.ps1` です。
エラーやクラッシュは `logs/` に TXT で保存され、ポップアップでも通知されます。

## フォルダ構成

- `index.html` / `game.js`
  - ゲームUI本体
- `scripts/`
  - 起動・停止・ローカルHTTPサーバー
- `llama-runtime/bin/`
  - `llama-server.exe` など実行バイナリ
- `llama-runtime/models/`
  - `.gguf` モデル
- `config/runtimeProfile.json`
  - ランチャーが出力する実行時プロファイル（自動生成）

## モデルの入れ方

1. `.gguf` ファイルを `llama-runtime/models/` に置く
2. `START.bat` を実行してランチャーを開く
3. モデル一覧から追加したモデルを選ぶ
4. `Start llama-server` を押す

補足:

- 推奨配置先は `llama-runtime/models/` です
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

固定設定を編集したい場合は `scripts/llama-server.env.bat` を編集します。

よく使う項目:

- `LLAMA_CPP_EXE`
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

- `START.bat`
  - 外側の操作ハブ（起動/ゲーム/停止）
- `scripts/launch-llama-server.ps1`
  - GUI本体。モデル選択、ゲーム開始、全停止をまとめる
- `scripts/serve-game.ps1`
  - 静的配信 + `/api/chat` を llama.cpp に中継

## 整理方針

- ルートの `.bat` は `START.bat` だけを運用対象にします。

## API経路

- ブラウザ: `POST /api/chat`
- ゲームサーバー: `POST http://127.0.0.1:8080/v1/chat/completions`

## よくある確認

- llama が生きているか:
  - `http://127.0.0.1:8080/health`
- ゲームサーバーが生きているか:
  - `http://127.0.0.1:4173/__health`

## 補足

- `scripts/llama-server.env.bat` は固定パスを手動指定できます。
- 何も指定しない場合、ランチャーは同梱 `llama-runtime` を優先して使います。

## このベースを基にゲームを作る（開発者向け）

このプロジェクトは「UI層」「ゲーム状態層」「LLM通信層」を分離して拡張する前提で作ると保守しやすくなります。

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
  - llama.cpp 実行設定

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
