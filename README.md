<h1 align="center">⚔️ ai-battle</h1>

<p align="center">
  <strong>Structured roundtable discussions among multiple AI Agents</strong>
</p>

<p align="center">
  Auto-managed rounds · Consensus detection · Full session recording
</p>

<p align="center">
  <a href="https://www.npmjs.com/package/ai-battle"><img src="https://img.shields.io/npm/v/ai-battle?style=flat-square&logo=npm&logoColor=white&color=CB3837" alt="npm version" /></a>
  <img src="https://img.shields.io/badge/Bash-4%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="Bash 4+" />
  <img src="https://img.shields.io/badge/Dep-jq-blue?style=flat-square" alt="jq" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow?style=flat-square" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="README_CN.md">📖 中文文档</a>
</p>

---

## ✨ Features

| Feature | Description |
| :--- | :--- |
| 🤖 **Multi-Agent Roundtable** | Mix and match Claude / Codex / Gemini freely |
| 🔁 **Self-Debate** | Same agent can take multiple seats (e.g. `gemini,gemini`) |
| 🔨 **Referee Mode** | Independent referee summarizes each round, detects consensus, generates final report |
| 👁️ **God Mode** | Inject supplementary instructions after each round to steer the discussion |
| 💾 **Session Recording** | Saves raw Agent CLI output (stream-json / json / raw) |
| 🔄 **Resume Support** | Automatically resumes from the last round after interruption |
| 🔌 **Extensible** | Implement 3 functions + register to add a new agent |

## 🚀 Quick Start

```bash
# Create a discussion directory
mkdir my-topic && cd my-topic

# Define the topic
echo "Microservices vs Monolith: pros and cons?" > problem.md

# Start the discussion (auto-fetches latest version)
npx ai-battle --agents claude,gemini --rounds 8
```

## 📦 Installation

**Recommended: No install needed, use npx directly**

```bash
npx ai-battle --agents claude,gemini --rounds 5
```

> npx fetches the latest version automatically — no manual updates required.

**Global install:**

```bash
npm install -g ai-battle
```

### Prerequisites

- `bash` 4+
- [`jq`](https://jqlang.github.io/jq/)
- At least 2 Agent CLI tools: `claude` / `codex` / `gemini`

## 📖 Usage

```
ai-battle [options]
ai-battle help
```

| Option | Description | Default |
| :--- | :--- | :--- |
| `--agents, -a <a1,a2>` | Select participating agents (supports same-type) | `claude,codex` |
| `--rounds, -r <N>` | Max discussion rounds | `10` |
| `--god, -g` | Enable god mode (inject info after each round) | — |
| `--referee [agent]` | Enable referee mode (per-round summary + SUMMARY.md) | — |

### 💡 Examples

```bash
# Same-type agent self-debate
ai-battle --agents gemini,gemini

# Three-way roundtable
ai-battle --agents claude,codex,gemini --rounds 5

# Referee mode
ai-battle --agents claude,codex,gemini --referee --rounds 5

# Specify claude as referee
ai-battle --agents codex,gemini --referee claude --rounds 5

# God mode + Referee
ai-battle --agents claude,codex --referee --god
```

## 🔄 How It Works

```mermaid
sequenceDiagram
    participant U as 👤 User
    participant S as 📜 ai-battle
    participant A as 🤖 Agent A
    participant B as 🤖 Agent B
    participant R as 🔨 Referee

    U->>S: ai-battle --agents A,B --referee

    rect rgb(40, 40, 60)
        Note over S: Phase 1: Initialize
        S->>S: Load .env / Check problem.md
        S->>A: check_A() availability
        S->>B: check_B() availability
    end

    rect rgb(30, 50, 40)
        Note over S: Round 1: Concurrent independent thinking
        par
            S->>A: call_A(problem)
            A-->>S: Response A
        and
            S->>B: call_B(problem)
            B-->>S: Response B
        end
    end

    rect rgb(40, 40, 60)
        Note over S: Round 2+: Sequential interaction
        loop Each agent takes turn
            S->>A: call_A(B's last response)
            A-->>S: Response A
            S->>B: call_B(A's latest response)
            B-->>S: Response B
        end

        opt --referee mode
            S->>R: call_referee(all responses)
            R-->>S: Summary / CONSENSUS verdict
        end

        opt --god mode
            S->>U: Enter supplementary info
            U-->>S: God mode injection
        end
    end

    alt Consensus reached
        S->>S: Save consensus.md
        opt Referee mode
            S->>R: generate_final_summary()
            R-->>S: SUMMARY.md
        end
        S->>U: 🎉 Consensus reached!
    else No consensus
        S->>U: Add more rounds?
    end
```

## 🤖 Built-in Agents

| Agent | Backend | Check Command |
| :--- | :--- | :--- |
| `claude` | Claude CLI | `claude -p "hello"` |
| `codex` | Codex CLI | `codex exec "hello"` |
| `gemini` | Gemini CLI | `gemini -p "hello"` |

## 📁 Output Structure

```text
my-topic/
├── problem.md                    # Discussion topic (user-created)
├── referee.md                    # Custom referee prompt (optional)
├── SUMMARY.md                    # Final summary (generated by referee)
├── .env                          # Environment variables (auto-loaded)
└── .ai-battle/                   # All runtime artifacts
    ├── rounds/                   # Per-round discussion records
    │   ├── round_1_claude.md
    │   ├── round_1_gemini.md
    │   ├── referee_round_2.md    # Referee summary (--referee)
    │   └── god_round_1.md        # God mode injection (--god)
    ├── sessions/                 # Raw Agent CLI output
    ├── agents/                   # Agent instruction files
    ├── consensus.md              # Consensus conclusion (if reached)
    ├── config.json               # Session config
    └── battle.log                # Full log (tail -f to watch live)
```

## 🔌 Extend Agent

Implement 3 functions and register:

```bash
# 1. Implement functions
check_myagent()          { ... }  # Availability check, return 0/1
call_myagent()           { ... }  # Call agent: $1=system_prompt $2=user_msg $3=session_tag
generate_myagent_md()    { ... }  # Generate instruction file: $1=max_rounds $2=problem

# 2. Register
register_agent "myagent"
```

## 🔑 Environment Variables

<details>
<summary><b>Claude</b></summary>

| Variable | Description |
| :--- | :--- |
| `ANTHROPIC_BASE_URL` | API endpoint |
| `ANTHROPIC_AUTH_TOKEN` | Auth token |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | Model name |
| `API_TIMEOUT_MS` | Timeout (ms) |

</details>

<details>
<summary><b>Codex</b></summary>

| Variable | Description | Default |
| :--- | :--- | :--- |
| `CODEX_MODEL` | Model name | `gpt-5.3-codex` |

</details>

<details>
<summary><b>Gemini</b></summary>

| Variable | Description |
| :--- | :--- |
| `GEMINI_API_KEY` | API key |

</details>

## 🤝 Contributing

[Issues](https://github.com/Alfonsxh/ai-battle/issues) and [Pull Requests](https://github.com/Alfonsxh/ai-battle/pulls) are welcome!

## 📄 License

[MIT](LICENSE) © [Alfons](https://github.com/Alfonsxh)
