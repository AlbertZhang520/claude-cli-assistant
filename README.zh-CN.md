# Claude CLI Assistant

语言：[English](README.md) | 简体中文 | [日本語](README.ja.md) | [한국어](README.ko.md)

Claude CLI Assistant 是一个面向 Codex 的凭据中立 Skill，用于把本机 Claude Code CLI 作为咨询型协作者调用。它本身是 Codex Skill；`claude` 是被它调用的外部 CLI。

仓库不包含 API key、私有端点、Bearer token、本地 shell alias 或机器专属路径。Claude 的认证和 Provider 路由应保留在用户本机环境里。

## 使用场景

- **Codex 与 Claude 交叉开发**：让 Codex 在本地实现，再让 Claude CLI 审查方案、检查 diff、补充遗漏测试或挑战高风险假设。
- **多代理代码评审**：一个助手负责主要实现，Claude 作为独立 reviewer，在接受改动前给出第二意见。
- **调试辅助**：把失败命令输出、日志或最小复现说明交给 Claude 生成根因假设，再在本地验证每条结论。
- **架构和影响面评估**：让 Claude 检查跨模块契约、公开 API、迁移、数据完整性风险或生产影响。
- **测试规划**：在变更范围确定后，让 Claude 补充高信号测试用例和边界条件。
- **长任务协作**：把 Claude 放到本地 async supervisor 下运行，让外层 agent 可以停止等待而不杀掉 Claude 任务。

## 安装

将仓库克隆到 Codex skills 目录：

```bash
mkdir -p ~/.codex/skills
git clone https://github.com/AlbertZhang520/claude-cli-assistant.git ~/.codex/skills/claude-cli-assistant
```

请单独安装并登录 Claude Code CLI，然后确认可用：

```bash
claude --version
claude auth status
```

## 配置

wrapper 会继承调用方当前 shell 环境。如果你的本地 shell 配置提供 Anthropic 或网关变量，`claude` 可能会继承这些变量。

可选 wrapper 设置可以通过环境变量提供，也可以写入该 Skill 目录下的本地 `.env`。`.env` 解析器只接受 `CLAUDE_CLI_` 前缀变量。

常用设置：

- `CLAUDE_CLI_BIN`：Claude CLI 路径或命令名。
- `CLAUDE_CLI_DEFAULT_BUDGET_USD`：`consult` 默认成本上限，默认 `0.12`。
- `CLAUDE_CLI_OUTPUT_WORDS`：默认输出字数预算，默认 `900`。
- `CLAUDE_CLI_RETRY_OUTPUT_WORDS`：预算恢复重试的输出字数预算，默认 `450`。
- `CLAUDE_CLI_RETRY_INPUT_CHARS`：预算错误后重试 prompt 的目标字符数，默认 `16000`。
- `CLAUDE_CLI_WARN_INPUT_CHARS`：触发大 prompt 预警的字符数，默认 `24000`。

检查配置：

```bash
cd ~/.codex/skills/claude-cli-assistant
./scripts/run-claude-cli.sh --check
./scripts/run-claude-cli.sh --print-config
```

`--print-config` 会脱敏 Provider 值，只显示它们是否已配置。

## 使用

```bash
printf '%s' "Review this plan for missing cases. Do not modify files." \
  | ./scripts/run-claude-cli.sh consult plan-critique
```

也可以在 Codex 中调用该 Skill：

```text
Use $claude-cli-assistant to consult local Claude CLI on this implementation plan.
```

## Agent 协作

当 Claude 需要和另一个 code agent 协作，而不是只回答一次临时 prompt 时，使用结构化 presets：

```bash
./scripts/pack-context.sh --status --diff --output /tmp/claude-context.md
./scripts/run-claude-cli.sh consult review --context /tmp/claude-context.md --async --wait-timeout 30
```

可用 presets：

- `review`：对代码或 diff 做对抗式审查。
- `plan-critique`：审查实现计划。
- `spec-rederive`：独立复述任务理解。
- `test-design`：生成独立测试思路。
- `debug-root-cause`：分析失败和日志根因。
- `blast-radius`：评估生产和集成风险。

Preset prompt 会要求 Claude 返回 `BEGIN_RESULT` / `END_RESULT` 结果块。异步 run 完成后，用 `result <run_id>` 读取提取后的答案。

## 长任务

当其他 code agent 可能在 Claude CLI 完成前停止等待时，使用异步模式：

```bash
run_id=$(printf '%s' "Review this large refactor. Do not modify files." \
  | ./scripts/run-claude-cli.sh consult review --async --wait-timeout 25)
./scripts/run-claude-cli.sh status "$run_id"
./scripts/run-claude-cli.sh logs "$run_id" --tail 80
./scripts/run-claude-cli.sh result "$run_id"
```

异步命令：

- `consult <preset> --async`：构造 preset prompt，并在 supervisor 下启动 Claude。
- `start`：用同一个 supervisor 启动原始 Claude CLI 参数。
- `status <run_id>`：查看状态、运行时间、空闲时间、原因和退出码。
- `wait <run_id> --timeout N`：只等待调用方预算。如果任务仍在运行，返回当前状态，不会杀掉 Claude。
- `logs <run_id>`：查看 stdout；用 `--stderr` 或 `--events` 查看其他日志。
- `result <run_id>`：查看提取后的结果块；没有结果块时显示 stdout。
- `cancel <run_id>`：终止 Claude 进程组，并把任务标记为 cancelled。
- `list`：查看最近任务。

超时语义是分开的：

- `wait --timeout`：只是调用方等待预算，不代表任务失败。
- async run 的 `--max-wall`：任务总运行时长硬上限，默认 `600` 秒，退出码 `125`。
- async run 的 `--idle-timeout`：无输出超时，默认 `120` 秒，退出码 `124`。

## 预算和模型说明

- 大上下文包可能在 Claude 产出有效内容前，就因为输入 token 消耗完配置预算。
- wrapper 会对大 prompt 发出预警，并在预算上限错误后用压缩输入和精简输出自动重试一次。
- 不要假设 `--model sonnet` 或其他 alias 已经降低成本。请检查 JSON `modelUsage`；同步 wrapper 调用会在请求模型字符串不出现在 `modelUsage` 时发出警告。

## 安全

- 不要提交 `.env`、API key、Bearer token、私有端点、本地账户细节或 Provider 凭据。
- 如果密钥曾经被提交过，请创建全新仓库或清理 Git 历史后再发布。
- 默认咨询是只读的：不开放工具、`permission-mode dontAsk`、不持久化 session。
- Claude 输出只作为参考；在采取行动前，用本地文件、命令、测试或 diff 验证。
- `agents/openai.yaml` 是 Skill 模板生成的 Codex UI 元数据，并不表示该 Skill 只支持 OpenAI Provider。

## Release Notes

### 2026-06-29

- 新增大 Claude prompt 的输入体积预警。
- 为同步 `consult` 调用新增压缩输入的预算恢复重试。
- 新增请求模型 alias 与 `modelUsage` 不一致时的警告。

### 2026-06-28

- 通过 `consult <preset>` 新增结构化 agent 协作 presets。
- 新增 `scripts/pack-context.sh`，用于生成有边界且经过脱敏的上下文包。
- 新增长任务异步管理：`start`、`status`、`wait`、`logs`、`result`、`cancel`、`list`。
- 新增协作协议，覆盖角色分工、调用门槛、finding contract 和分歧裁决规则。

## 许可证

MIT
