<h1 align="center">⚔️ ai-battle</h1>

<p align="center">
  <strong>让多个 AI Agent 对同一问题进行结构化圆桌讨论</strong>
</p>

<p align="center">
  自动管理轮次 · 检测共识 · 保存全部记录
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/ai-battle"><img src="https://img.shields.io/npm/v/ai-battle?style=flat-square&logo=npm&logoColor=white&color=CB3837" alt="npm version" /></a>
  <a href="https://github.com/Alfonsxh/ai-battle/actions/workflows/publish.yml"><img src="https://img.shields.io/github/actions/workflow/status/Alfonsxh/ai-battle/publish.yml?style=flat-square&logo=githubactions&logoColor=white" alt="publish" /></a>
  <img src="https://img.shields.io/badge/Bash-4%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="Bash 4+" />
  <img src="https://img.shields.io/badge/Dep-jq-blue?style=flat-square" alt="jq" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow?style=flat-square" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="https://www.npmjs.com/package/ai-battle">NPM</a> ·
  <a href="https://github.com/Alfonsxh/ai-battle/issues">Issues</a> ·
  <a href="https://github.com/Alfonsxh/ai-battle/pulls">PRs</a> ·
  <a href="LICENSE">许可证</a>
</p>

---

<details>
<summary><b>目录</b></summary>

- [特性](#特性)
- [快速开始](#快速开始)
- [安装](#安装)
- [前置依赖](#前置依赖)
- [用法](#用法)
- [示例](#示例)
- [工作流程](#工作流程)
- [产出结构](#产出结构)
- [扩展 Agent](#扩展-agent)
- [环境变量](#环境变量)
- [参与贡献](#参与贡献)
- [许可](#许可)

</details>

## ✨ 特性

| 特性 | 说明 |
| :--- | :--- |
| 🤖 **多 Agent 圆桌** | 支持 Claude / Codex / Gemini 自由组合 |
| 🔁 **同类自辩** | 同一 Agent 可参加多席位（如 `gemini,gemini`） |
| 🔨 **裁判模式** | 独立裁判每轮总结差异、自动检测共识、生成最终报告 |
| 👁️ **上帝视角** | 每轮结束后人工注入补充信息引导讨论方向 |
| 💾 **Session 录制** | 保存 Agent CLI 原始输出（stream-json / json / raw） |
| 🔄 **断点续讨** | 中断后自动恢复到上次轮次继续讨论 |
| 🔌 **可扩展** | 实现 3 个函数 + 注册即可接入新 Agent |

## 🚀 快速开始

```bash
# 创建讨论目录
mkdir my-topic && cd my-topic

# 写入问题
echo "微服务 vs 单体架构的优缺点？" > problem.md

# 启动讨论（自动拉取最新版）
npx ai-battle --agents claude,gemini --rounds 8
```

## 📦 安装

**推荐：无需安装，直接使用 npx**

```bash
npx ai-battle --agents claude,gemini --rounds 5
```

> npx 每次执行自动拉取最新版本，无需手动更新。

**全局安装：**

```bash
npm install -g ai-battle
```

### 前置依赖

- `bash` 4+
- [`jq`](https://jqlang.github.io/jq/)
- Agent CLI 工具（至少安装 2 个）：`claude` / `codex` / `gemini`

## 📖 用法

```text
ai-battle [options]
ai-battle help
```

| 参数 | 说明 | 默认值 |
| :--- | :--- | :--- |
| `--agents, -a <a1,a2>` | 选择参与的 Agent，支持同类 | `claude,codex` |
| `--rounds, -r <N>` | 最大讨论轮次 | `10` |
| `--god, -g` | 开启上帝视角（每轮可注入补充信息） | — |
| `--referee [agent]` | 开启裁判模式（每轮总结 + 生成 SUMMARY.md） | — |

### 💡 示例

```bash
# 同类 Agent 自我辩论
ai-battle --agents gemini,gemini

# 三方圆桌讨论
ai-battle --agents claude,codex,gemini --rounds 5

# 裁判模式
ai-battle --agents claude,codex,gemini --referee --rounds 5

# 指定 claude 做裁判
ai-battle --agents codex,gemini --referee claude --rounds 5

# 上帝视角 + 裁判
ai-battle --agents claude,codex --referee --god
```

## 🔄 工作流程

```mermaid
sequenceDiagram
    participant U as 👤 用户
    participant S as 📜 ai-battle
    participant A as 🤖 Agent A
    participant B as 🤖 Agent B
    participant R as 🔨 裁判

    U->>S: ai-battle --agents A,B --referee

    rect rgb(40, 40, 60)
        Note over S: 阶段 1: 初始化
        S->>S: 加载 .env / 检查 problem.md
        S->>A: check_A() 可用性检查
        S->>B: check_B() 可用性检查
    end

    rect rgb(30, 50, 40)
        Note over S: Round 1: 并发独立思考
        par
            S->>A: call_A(problem)
            A-->>S: 回复 A
        and
            S->>B: call_B(problem)
            B-->>S: 回复 B
        end
    end

    rect rgb(40, 40, 60)
        Note over S: Round 2+: 顺序交互
        loop 每个 Agent 依次发言
            S->>A: call_A(B 的上轮回复)
            A-->>S: 回复 A
            S->>B: call_B(A 的最新回复)
            B-->>S: 回复 B
        end

        opt --referee 模式
            S->>R: call_referee(所有回复)
            R-->>S: 裁判总结 / CONSENSUS 判定
        end

        opt --god 模式
            S->>U: 请输入补充信息
            U-->>S: 上帝视角注入
        end
    end

    alt 达成共识
        S->>S: 保存 consensus.md
        opt 裁判模式
            S->>R: generate_final_summary()
            R-->>S: SUMMARY.md
        end
        S->>U: 🎉 达成共识！
    else 未达成
        S->>U: 是否追加轮次？
    end
```

## 📁 产出结构

```text
my-topic/
├── problem.md                    # 讨论问题（用户创建）
├── referee.md                    # 裁判自定义提示词（可选）
├── SUMMARY.md                    # 最终总结（裁判自动生成）
├── .env                          # 环境变量（启动时自动加载）
└── .ai-battle/                   # 所有运行时产物
    ├── rounds/                   # 讨论轮次记录
    │   ├── round_1_claude.md
    │   ├── round_1_gemini.md
    │   ├── referee_round_2.md    # 裁判总结（--referee）
    │   └── god_round_1.md        # 上帝注入（--god）
    ├── sessions/                 # Agent CLI 原始输出
    ├── agents/                   # Agent 指令文件
    ├── consensus.md              # 共识结论（如达成）
    ├── config.json               # 会话配置
    └── battle.log                # 运行日志（tail -f 实时查看）
```

## 🔌 扩展 Agent

只需实现 3 个函数并注册：

```bash
# 1. 实现函数
check_myagent()          { ... }  # 可用性检查，返回 0/1
call_myagent()           { ... }  # 调用 Agent: $1=system_prompt $2=user_msg $3=session_tag
generate_myagent_md()    { ... }  # 生成指令文件: $1=max_rounds $2=problem

# 2. 注册
register_agent "myagent"
```

## 🔑 环境变量

| 变量 | 说明 | 默认值 |
| :--- | :--- | :--- |
| `ANTHROPIC_BASE_URL` | Claude API 地址 | — |
| `ANTHROPIC_AUTH_TOKEN` | Claude 认证 Token | — |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Claude 模型名称 | — |
| `API_TIMEOUT_MS` | Claude 超时时间（毫秒） | — |
| `CODEX_MODEL` | Codex 模型名称 | `gpt-5.3-codex` |
| `GEMINI_API_KEY` | Gemini API Key | — |

## 🤝 参与贡献

欢迎提交 [Issue](https://github.com/Alfonsxh/ai-battle/issues) 和 [Pull Request](https://github.com/Alfonsxh/ai-battle/pulls)！

## 📄 许可

[MIT](LICENSE) © [Alfons](https://github.com/Alfonsxh)
