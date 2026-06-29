# Claude CLI Assistant

言語：[English](README.md) | [简体中文](README.zh-CN.md) | 日本語 | [한국어](README.ko.md)

Claude CLI Assistant は、ローカルの Claude Code CLI を助言役として呼び出すための、認証情報に依存しない Codex Skill です。これは Codex Skill であり、`claude` はこの Skill から呼び出される外部 CLI です。

このリポジトリには、API key、プライベートエンドポイント、Bearer token、ローカル shell alias、マシン固有のパスは含まれていません。Claude の認証と Provider ルーティングは、ユーザーのローカル環境に置いてください。

## ユースケース

- **Codex と Claude のクロス開発**：Codex がローカルで実装し、その後 Claude CLI に計画、diff、不足テスト、危険な仮定をレビューさせます。
- **複数エージェントのコードレビュー**：一方の assistant を主な実装担当にし、Claude を独立 reviewer として使って変更を受け入れる前に第二意見を得ます。
- **デバッグ支援**：失敗したコマンド出力、ログ、最小再現メモを Claude に渡して根本原因の仮説を得て、各主張をローカルで検証します。
- **アーキテクチャと影響範囲レビュー**：モジュール間契約、公開 API、migration、データ整合性、production impact を確認します。
- **テスト計画**：変更範囲が決まった後、高シグナルなテストケースと境界条件を洗い出します。
- **長時間の協働**：Claude をローカル async supervisor の下で実行し、外側の agent が待機をやめても Claude タスクを殺さないようにします。

## インストール

このリポジトリを Codex skills ディレクトリに clone します：

```bash
mkdir -p ~/.codex/skills
git clone https://github.com/AlbertZhang520/claude-cli-assistant.git ~/.codex/skills/claude-cli-assistant
```

Claude Code CLI は別途インストールして認証し、利用可能であることを確認します：

```bash
claude --version
claude auth status
```

## 設定

wrapper は呼び出し側の shell 環境を継承します。ローカル shell 設定に Anthropic または gateway 変数がある場合、`claude` はそれらを継承することがあります。

任意の wrapper 設定は環境変数、またはこの Skill ディレクトリのローカル `.env` に置けます。`.env` parser は `CLAUDE_CLI_` で始まる変数だけを読みます。

よく使う設定：

- `CLAUDE_CLI_BIN`：Claude CLI のパスまたはコマンド名。
- `CLAUDE_CLI_DEFAULT_BUDGET_USD`：`consult` のデフォルト cost cap。デフォルトは `0.12`。
- `CLAUDE_CLI_OUTPUT_WORDS`：デフォルトの応答語数予算。デフォルトは `900`。
- `CLAUDE_CLI_RETRY_OUTPUT_WORDS`：budget recovery retry の応答語数予算。デフォルトは `450`。
- `CLAUDE_CLI_RETRY_INPUT_CHARS`：budget error 後の retry prompt の目標文字数。デフォルトは `16000`。
- `CLAUDE_CLI_WARN_INPUT_CHARS`：大きな prompt 警告を出す文字数。デフォルトは `24000`。

設定を確認します：

```bash
cd ~/.codex/skills/claude-cli-assistant
./scripts/run-claude-cli.sh --check
./scripts/run-claude-cli.sh --print-config
```

`--print-config` は Provider 値を redact し、設定済みかどうかだけを表示します。

## 使い方

```bash
printf '%s' "Review this plan for missing cases. Do not modify files." \
  | ./scripts/run-claude-cli.sh consult plan-critique
```

Codex から Skill として呼び出すこともできます：

```text
Use $claude-cli-assistant to consult local Claude CLI on this implementation plan.
```

## Agent コラボレーション

Claude を一度だけの ad hoc prompt ではなく、別の code agent との協働相手として使う場合は、構造化 preset を使います：

```bash
./scripts/pack-context.sh --status --diff --output /tmp/claude-context.md
./scripts/run-claude-cli.sh consult review --context /tmp/claude-context.md --async --wait-timeout 30
```

Claude に次の実装 slice を選ばせる場合や、capability が不足しているかを判断させる場合は、軽量な capability inventory を含めます：

```bash
./scripts/pack-context.sh --inventory --file README.md --output /tmp/claude-context.md
```

利用可能な preset：

- `review`：コードまたは diff に対する adversarial review。
- `plan-critique`：実装計画の批評。
- `spec-rederive`：タスク理解の独立した再導出。
- `test-design`：独立したテスト案。
- `debug-root-cause`：失敗とログの原因分析。
- `blast-radius`：本番・連携リスクの評価。

Preset prompt は Claude に `BEGIN_RESULT` / `END_RESULT` の結果ブロックを返すよう求めます。非同期 run の完了後は `result <run_id>` で抽出済みの回答を読めます。

## 長時間タスク

他の code agent が Claude CLI の完了前に待機をやめる可能性がある場合は、非同期モードを使います：

```bash
run_id=$(printf '%s' "Review this large refactor. Do not modify files." \
  | ./scripts/run-claude-cli.sh consult review --async --wait-timeout 25)
./scripts/run-claude-cli.sh status "$run_id"
./scripts/run-claude-cli.sh logs "$run_id" --tail 80
./scripts/run-claude-cli.sh result "$run_id"
```

非同期コマンド：

- `consult <preset> --async`：preset prompt を作成し、supervisor の下で Claude を起動します。
- `start`：同じ supervisor で生の Claude CLI 引数を起動します。
- `status <run_id>`：状態、経過時間、アイドル時間、理由、終了コードを表示します。
- `wait <run_id> --timeout N`：呼び出し側の待機予算だけ待ちます。実行中なら現在状態を返し、Claude は終了しません。
- `logs <run_id>`：stdout を表示します。`--stderr` または `--events` で他のログを確認できます。
- `result <run_id>`：抽出済みの結果ブロックを表示します。結果ブロックがない場合は stdout を表示します。
- `cancel <run_id>`：Claude のプロセスグループを終了し、run を cancelled として記録します。
- `list`：最近の run を表示します。

タイムアウトは分離されています：

- `wait --timeout`：呼び出し側の待機予算だけであり、タスク失敗ではありません。
- async run の `--max-wall`：タスク全体の実行時間上限です。デフォルトは `600` 秒、終了コードは `125` です。
- async run の `--idle-timeout`：出力がない状態の timeout です。デフォルトは `120` 秒、終了コードは `124` です。

## 予算とモデルに関する注意

- 大きな context packet は、Claude が有用な出力を書く前に入力 token だけで予算を使い切ることがあります。
- wrapper は大きな prompt に警告を出し、budget-limit error 後に compacted input と concise output で一度だけ retry します。
- capability が存在しないという主張には高い証拠負担があります。capability-gap analysis では `pack-context.sh --inventory` を使い、ローカル検索で確認するまでは missing-feature の結論を未検証の仮定として扱ってください。inventory に `TRUNCATED` が出た場合は、欠落の結論を受け入れる前に対象を絞ったローカル検索を行ってください。
- `--model sonnet` などの alias が cost を下げたと仮定しないでください。JSON の `modelUsage` を確認してください。同期 wrapper は要求した文字列が `modelUsage` にない場合に警告します。

## セキュリティ

- `.env`、API key、Bearer token、プライベートエンドポイント、ローカルアカウント情報、Provider 認証情報を commit しないでください。
- もし secret を過去に commit したことがある場合は、新しいリポジトリを作成するか、公開前に Git 履歴をクリーンアップしてください。
- デフォルトの consult は read-only です：tools なし、`permission-mode dontAsk`、session persistence なし。
- Claude の出力は参考情報として扱い、行動前にローカルファイル、コマンド、テスト、diff で検証してください。
- `agents/openai.yaml` は Skill テンプレートが生成する Codex UI メタデータであり、この Skill が OpenAI Provider 専用であることを意味しません。

## Release Notes

### 2026-06-29

- 大きな Claude prompt に対する input-size warning を追加しました。
- 同期 `consult` 呼び出しに compacted-input budget recovery retry を追加しました。
- 要求した model alias と `modelUsage` が一致しない場合の警告を追加しました。

### 2026-06-28

- `consult <preset>` による構造化 agent collaboration preset を追加しました。
- 境界づけられ、redact された context packet を生成する `scripts/pack-context.sh` を追加しました。
- 長時間タスク管理として `start`、`status`、`wait`、`logs`、`result`、`cancel`、`list` を追加しました。
- role、consultation gate、finding contract、adjudication rule を含む collaboration protocol を追加しました。

## ライセンス

MIT
