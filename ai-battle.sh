#!/usr/bin/env bash
# ============================================================
# ai-battle.sh — AI 圆桌讨论工具
#
# 让多个 AI Agent（Claude/Codex/Gemini…）对同一问题进行
# 结构化讨论，自动管理轮次、检测共识、保存全部讨论记录。
#
# 用法:
#   ai-battle [--agents claude,codex] [--rounds 10] [--god] [--referee]
#   ai-battle --help
#
# 依赖: jq, bash 4+, (可选) codex, claude, gemini
# ============================================================
set -euo pipefail

# ======================== 加载 .env ========================
# 如果执行目录存在 .env 文件，自动加载环境变量
if [ -f ".env" ]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

# ======================== 版本 ========================
VERSION="0.1.0"

# ======================== 颜色 ========================
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ======================== 默认配置 ========================
DEFAULT_AGENTS="claude,codex"
DEFAULT_MAX_ROUNDS=10
PROBLEM_FILE="problem.md"
ROUNDS_DIR="rounds"
CONSENSUS_FILE="consensus.md"
LOG_FILE=".debate.log"
CONFIG_FILE=".debate.json"
REFEREE_PROMPT_FILE="referee.md"
SESSIONS_DIR=".sessions"

# ======================== Codex 配置 ========================
CODEX_MODEL="${CODEX_MODEL:-gpt-5.3-codex}"

# ======================== Agent 注册表 ========================
# 已注册的 agent 名称列表
REGISTERED_AGENTS=()

# 注册 agent
# 用法: register_agent <name>
# 要求: 必须实现 check_<name>() 和 call_<name>() 两个函数
register_agent() {
  REGISTERED_AGENTS+=("$1")
}

# ======================== Agent: Claude (CLI) ========================
# 前置条件: 用户需自行设置 claude 所需的环境变量, 例如:
#   export ANTHROPIC_BASE_URL="https://open.bigmodel.cn/api/anthropic"
#   export ANTHROPIC_AUTH_TOKEN="your-token"
#   export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
#   export API_TIMEOUT_MS=600000
#   export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-4.7"

# 检查 Claude CLI 是否可用
# 返回: 0=可用, 1=不可用
check_claude() {
  if ! command -v claude &>/dev/null; then
    echo -e "    ${RED}✗ claude 命令不在 PATH 中${NC}" >&2
    return 1
  fi
  # 调用测试：分离 stdout/stderr，检查退出码
  local resp errmsg
  local tmperr
  tmperr=$(mktemp)
  resp=$(claude -p "hello" --output-format text 2>"$tmperr") && local rc=0 || local rc=$?
  errmsg=$(cat "$tmperr" 2>/dev/null)
  rm -f "$tmperr"

  if [ $rc -ne 0 ] || [ -z "$resp" ]; then
    # 输出具体错误信息帮助诊断
    if [ -n "$errmsg" ]; then
      echo -e "    ${RED}✗ claude 调用失败: ${errmsg}${NC}" >&2
    elif [ -n "$resp" ]; then
      # 退出码非零但有 stdout（可能是错误信息输出到了 stdout）
      echo -e "    ${RED}✗ claude 调用失败: ${resp}${NC}" >&2
    else
      echo -e "    ${RED}✗ claude 命令无响应 (请检查环境变量配置)${NC}" >&2
    fi
    return 1
  fi
  return 0
}

# 调用 Claude CLI（支持原生 --system-prompt）
# 参数: $1=system_prompt  $2=user_message
# 输出: stdout 回复文本
call_claude() {
  local system_prompt="$1"
  local user_msg="$2"
  local session_tag="${3:-}"  # 可选: session 文件名标识
  local max_retries=3
  local retry_delay=10

  local attempt=1
  while [ $attempt -le $max_retries ]; do
    local raw_out
    raw_out=$(mktemp)

    # 捕获原始输出（stream-json 格式）
    claude -p "$user_msg" --system-prompt "$system_prompt" --output-format stream-json \
      > "$raw_out" 2>&1 || true

    # 保存原始 session 记录
    if [ -n "$session_tag" ] && [ -d "$SESSIONS_DIR" ]; then
      cp "$raw_out" "$SESSIONS_DIR/${session_tag}_claude.jsonl"
    fi

    # 从 stream-json 提取文本内容 (Claude CLI 格式: type=result 的 .result 字段)
    local text
    text=$(jq -r 'select(.type=="result") | .result // empty' "$raw_out" 2>/dev/null || true)

    # 备选: 从 type=assistant 的 message.content[].text 提取
    if [ -z "$text" ]; then
      text=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text // empty' "$raw_out" 2>/dev/null || true)
    fi

    # 如果 stream-json 提取失败，回退到 text 格式
    if [ -z "$text" ]; then
      text=$(claude -p "$user_msg" --system-prompt "$system_prompt" --output-format text 2>/dev/null || true)
    fi

    rm -f "$raw_out"

    if [ -n "$text" ]; then
      echo "$text"
      return 0
    fi

    echo -e "${YELLOW}WARN: Claude CLI 第 $attempt 次失败，${retry_delay}s 后重试...${NC}" >&2
    sleep $retry_delay
    attempt=$((attempt + 1))
    retry_delay=$((retry_delay * 2))
  done

  echo -e "${RED}ERROR: Claude CLI $max_retries 次重试均失败${NC}" >&2
  return 1
}

# 生成 Claude 指令文件
# 参数: $1=max_rounds  $2=problem_text
generate_claude_md() {
  local max_rounds="$1"
  local problem="$2"
  cat << CLAUDE_EOF
# AI 圆桌讨论 — Claude 参与者

## 身份
你是 **Claude**，正在与其他 AI 进行结构化技术讨论。

## 讨论规则
1. 阅读 \`$PROBLEM_FILE\` 了解讨论主题
2. 查看 \`$ROUNDS_DIR/\` 目录确定当前轮次 N
3. 如果对方的回复已存在，先仔细阅读
4. 将你的回复写入 \`$ROUNDS_DIR/round_N_claude.md\`

## 当前配置
- 最大轮次: **$max_rounds**
- 讨论问题: $problem

## 回复要求
- 深入分析，不要敷衍；如不同意对方，明确反驳
- 达成共识时在回复最后一行写: \`AGREED: <结论>\`
- 不要过早同意，确保分析完整

## 约束
- 每次只写一轮，写完等待下一轮指示
- 不要修改其他 Agent 的文件
CLAUDE_EOF
}

register_agent "claude"

# ======================== Agent: Codex ========================

# 检查 Codex 是否可用
check_codex() {
  if ! command -v codex &>/dev/null; then
    echo -e "    ${RED}✗ codex 命令不在 PATH 中${NC}" >&2
    return 1
  fi
  # 实际调用验证认证和可用性
  local resp errmsg
  local tmperr
  tmperr=$(mktemp)
  resp=$(codex exec "hello" 2>"$tmperr") && local rc=0 || local rc=$?
  errmsg=$(cat "$tmperr" 2>/dev/null)
  rm -f "$tmperr"

  if [ $rc -ne 0 ] || [ -z "$resp" ]; then
    if [ -n "$errmsg" ]; then
      echo -e "    ${RED}✗ codex 调用失败: ${errmsg}${NC}" >&2
    elif [ -n "$resp" ]; then
      echo -e "    ${RED}✗ codex 调用失败: ${resp}${NC}" >&2
    else
      echo -e "    ${RED}✗ codex 命令无响应 (请检查认证配置)${NC}" >&2
    fi
    return 1
  fi
  return 0
}

# 调用 Codex
# 参数: $1=system_prompt  $2=user_message  $3=session_tag(可选)
# 输出: stdout 回复文本
call_codex() {
  local system_prompt="$1"
  local user_msg="$2"
  local session_tag="${3:-}"  # 可选: session 文件名标识
  local max_retries=3
  local retry_delay=10

  local full_prompt="$system_prompt

$user_msg

重要：直接输出你的分析内容，不要写任何文件，不要输出方案图或伪代码，直接给出你的讨论观点。"

  # 确保 codex 有 git 仓库
  if [ ! -d ".git" ]; then
    git init -q
    git add -A 2>/dev/null || true
    git commit -q -m "debate-init" 2>/dev/null || true
  fi

  local attempt=1
  while [ $attempt -le $max_retries ]; do
    local tmpout
    tmpout=$(mktemp)

    codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \
      -m "$CODEX_MODEL" "$full_prompt" \
      2>&1 | tee "$tmpout" > /dev/null || true

    # 保存原始 session 记录
    if [ -n "$session_tag" ] && [ -d "$SESSIONS_DIR" ]; then
      cp "$tmpout" "$SESSIONS_DIR/${session_tag}_codex.raw"
    fi

    local text=""

    # 从输出中提取有效内容（跳过 codex 元数据行）
    text=$(grep -v '^\(thinking\|exec\|mcp startup\|OpenAI Codex\|--------\|workdir:\|model:\|provider:\|approval:\|sandbox:\|reasoning\|session id:\|user$\|tokens used\|Exit code:\|^$\)' "$tmpout" 2>/dev/null | sed '/^$/d')

    rm -f "$tmpout"

    if [ -n "$text" ]; then
      echo "$text"
      return 0
    fi

    echo -e "${YELLOW}WARN: Codex 第 $attempt 次失败，${retry_delay}s 后重试...${NC}" >&2
    sleep $retry_delay
    attempt=$((attempt + 1))
    retry_delay=$((retry_delay * 2))
  done

  echo -e "${RED}ERROR: Codex $max_retries 次重试均失败${NC}" >&2
  return 1
}

# 生成 Codex 指令文件
generate_codex_md() {
  local max_rounds="$1"
  local problem="$2"
  cat << CODEX_EOF
# AI 圆桌讨论 — Codex 参与者

## 身份
你是 **Codex**，正在与其他 AI 进行结构化技术讨论。

## 讨论规则
1. 阅读 \`$PROBLEM_FILE\` 了解讨论主题
2. 查看 \`$ROUNDS_DIR/\` 目录确定当前轮次 N
3. 如果对方的回复已存在，先仔细阅读
4. 将你的回复写入 \`$ROUNDS_DIR/round_N_codex.md\`

## 当前配置
- 最大轮次: **$max_rounds**
- 讨论问题: $problem

## 回复要求
- 深入分析，不要敷衍；如不同意对方，明确反驳
- 达成共识时在回复最后一行写: \`AGREED: <结论>\`
- 不要过早同意，确保分析完整

## 约束
- 每次只写一轮，写完等待下一轮指示
- 不要修改其他 Agent 的文件
CODEX_EOF
}

register_agent "codex"

# ======================== Agent: Gemini (CLI) ========================
# 前置条件: 安装 Gemini CLI (npm install -g @anthropic-ai/gemini-cli 或参考官方文档)
#   可选环境变量:
#   export GEMINI_API_KEY="your-key"

# 检查 Gemini CLI 是否可用
# 返回: 0=可用, 1=不可用
check_gemini() {
  if ! command -v gemini &>/dev/null; then
    echo -e "    ${RED}✗ gemini 命令不在 PATH 中${NC}" >&2
    return 1
  fi
  # 调用测试：分离 stdout/stderr，检查退出码
  local resp errmsg tmperr
  tmperr=$(mktemp)
  resp=$(gemini -p "hello" --output-format text 2>"$tmperr") && local rc=0 || local rc=$?
  errmsg=$(cat "$tmperr" 2>/dev/null)
  rm -f "$tmperr"

  if [ $rc -ne 0 ] || [ -z "$resp" ]; then
    if [ -n "$errmsg" ]; then
      echo -e "    ${RED}✗ gemini 调用失败: ${errmsg}${NC}" >&2
    elif [ -n "$resp" ]; then
      echo -e "    ${RED}✗ gemini 调用失败: ${resp}${NC}" >&2
    else
      echo -e "    ${RED}✗ gemini 命令无响应 (请检查 API Key 配置)${NC}" >&2
    fi
    return 1
  fi
  return 0
}

# 调用 Gemini CLI
# 参数: $1=system_prompt  $2=user_message
# 输出: stdout 回复文本
call_gemini() {
  local system_prompt="$1"
  local user_msg="$2"
  local session_tag="${3:-}"  # 可选: session 文件名标识
  local max_retries=3
  local retry_delay=10

  local full_msg="${system_prompt}

${user_msg}"

  local attempt=1
  while [ $attempt -le $max_retries ]; do
    local raw_out
    raw_out=$(mktemp)

    # 捕获原始输出
    gemini -p "$full_msg" --output-format json \
      > "$raw_out" 2>&1 || true

    # 保存原始 session 记录
    if [ -n "$session_tag" ] && [ -d "$SESSIONS_DIR" ]; then
      cp "$raw_out" "$SESSIONS_DIR/${session_tag}_gemini.json"
    fi

    # 从 json 提取文本内容 (Gemini CLI 格式: type=result 的 .result 字段)
    local text
    text=$(jq -r 'select(.type=="result") | .result // empty' "$raw_out" 2>/dev/null || true)

    # 备选: 尝试数组格式
    if [ -z "$text" ]; then
      text=$(jq -r '.[] | select(.type=="text") | .text // empty' "$raw_out" 2>/dev/null || true)
    fi

    # 如果 json 提取失败，回退到 text 格式
    if [ -z "$text" ]; then
      text=$(gemini -p "$full_msg" --output-format text 2>/dev/null || true)
    fi

    rm -f "$raw_out"

    if [ -n "$text" ]; then
      echo "$text"
      return 0
    fi

    echo -e "${YELLOW}WARN: Gemini CLI 第 $attempt 次失败，${retry_delay}s 后重试...${NC}" >&2
    sleep $retry_delay
    attempt=$((attempt + 1))
    retry_delay=$((retry_delay * 2))
  done

  echo -e "${RED}ERROR: Gemini CLI $max_retries 次重试均失败${NC}" >&2
  return 1
}

# 生成 Gemini 指令文件
# 参数: $1=max_rounds  $2=problem_text
generate_gemini_md() {
  local max_rounds="$1"
  local problem="$2"
  cat << GEMINI_EOF
# AI 圆桌讨论 — Gemini 参与者

## 身份
你是 **Gemini**，正在与其他 AI 进行结构化技术讨论。

## 讨论规则
1. 阅读 \`$PROBLEM_FILE\` 了解讨论主题
2. 查看 \`$ROUNDS_DIR/\` 目录确定当前轮次 N
3. 如果对方的回复已存在，先仔细阅读
4. 将你的回复写入 \`$ROUNDS_DIR/round_N_gemini.md\`

## 当前配置
- 最大轮次: **$max_rounds**
- 讨论问题: $problem

## 回复要求
- 深入分析，不要敷衍；如不同意对方，明确反驳
- 达成共识时在回复最后一行写: \`AGREED: <结论>\`
- 不要过早同意，确保分析完整

## 约束
- 每次只写一轮，写完等待下一轮指示
- 不要修改其他 Agent 的文件
GEMINI_EOF
}

register_agent "gemini"

# ======================== 工具函数 ========================

# Round 层级重试包装器
# 当 agent 内部重试耗尽后，询问用户是否继续重试
# 参数: $1=agent名称(display)  $2+=要执行的命令
# 输出: stdout 命令结果
# 返回: 0=成功, 1=用户选择退出
retry_call_agent() {
  local agent_display="$1"
  shift

  while true; do
    local result
    result=$("$@" 2>/dev/null) && local rc=0 || local rc=$?

    if [ $rc -eq 0 ] && [ -n "$result" ]; then
      echo "$result"
      return 0
    fi

    echo "" >&2
    echo -e "${RED}━━━ ⚠️  ${agent_display} 调用失败 ━━━${NC}" >&2
    echo -e "  ${BOLD}r)${NC} 重试" >&2
    echo -e "  ${BOLD}s)${NC} 跳过该 agent 本轮发言" >&2
    echo -e "  ${BOLD}q)${NC} 退出讨论" >&2
    echo -ne "${BOLD}请选择 [r/s/q]: ${NC}" >&2
    local choice
    read -er choice
    case "$choice" in
      s|S)
        echo -e "${YELLOW}  跳过 ${agent_display}${NC}" >&2
        echo ""  # 返回空字符串
        return 0
        ;;
      q|Q)
        echo -e "${CYAN}已退出。${NC}" >&2
        exit 1
        ;;
      *)  # 默认重试
        echo -e "${CYAN}  重试 ${agent_display}...${NC}" >&2
        ;;
    esac
  done
}

# 从实例名提取基础 agent 类型
# 用法: agent_base "claude_1" → "claude"，agent_base "claude" → "claude"
agent_base() {
  echo "$1" | sed 's/_[0-9]*$//'
}

# 日志输出（同时写终端和日志文件）
log_and_print() {
  echo -e "$1"
  echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# 检查 AGREED 关键字（支持行内匹配，不要求行首）
has_agreed() {
  echo "$1" | grep -qiE '\*{0,2}AGREED:'
}

# 提取 AGREED 后的结论
extract_agreed() {
  echo "$1" | grep -ioE '\*{0,2}AGREED:[[:space:]]*.*' | head -1 \
    | sed 's/^\*\{0,2\}[Aa][Gg][Rr][Ee][Ee][Dd]:[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/\*\{1,2\}$//'
}

# Agent 颜色映射（自动提取基础类型）
agent_color() {
  local base
  base=$(agent_base "$1")
  case "$base" in
    claude) echo "$BLUE" ;;
    codex)  echo "$GREEN" ;;
    gemini) echo "\033[1;35m" ;;  # 紫色
    *)      echo "$YELLOW" ;;
  esac
}

# Agent 指令文件名映射（支持实例名，如 claude_1 → CLAUDE_1.md）
agent_md_file() {
  local base
  base=$(agent_base "$1")
  local suffix=""
  if [ "$1" != "$base" ]; then
    suffix="_${1##*_}"  # 提取 _N 后缀
  fi
  case "$base" in
    claude) echo "CLAUDE${suffix}.md" ;;
    codex)  echo "AGENTS${suffix}.md" ;;
    gemini) echo "GEMINI${suffix}.md" ;;
    *)      echo "${1^^}.md" ;;
  esac
}

# 上帝视角: 等待用户输入补充信息
# 参数: $1=当前轮次
# 输出: stdout 用户输入的补充信息（可为空）
god_input() {
  local round="$1"
  echo "" >&2
  echo -e "${CYAN}━━━ 👁️  上帝视角 [Round ${round} 结束] ━━━${NC}" >&2
  echo -e "${CYAN}输入补充信息（直接回车跳过，多行输入以 END 结束）:${NC}" >&2
  echo -ne "${CYAN}> ${NC}" >&2

  local first_line
  read -er first_line

  # 直接回车 = 跳过
  if [ -z "$first_line" ]; then
    echo -e "${CYAN}  (跳过)${NC}" >&2
    echo ""
    return
  fi

  local input="$first_line"

  # 如果第一行不是 END，继续读取多行
  if [ "$first_line" != "END" ]; then
    while true; do
      echo -ne "${CYAN}> ${NC}" >&2
      local line
      read -er line
      if [ "$line" = "END" ] || [ -z "$line" ]; then
        break
      fi
      input+=$'\n'"$line"
    done
  fi

  # 保存上帝视角输入
  echo "$input" > "$ROUNDS_DIR/god_round_${round}.md"
  log_and_print "${CYAN}👁️  上帝视角注入: $(echo "$input" | head -1)...${NC}"
  echo "$input"
}

# 系统提示（通用）
build_system_prompt() {
  local max_rounds="$1"
  cat << SYSPROMPT
你正在参与一场 AI 圆桌讨论。规则：
1. 深入分析问题，给出有价值的观点
2. 积极回应对方——认同有道理的部分，挑战有漏洞的部分
3. 每轮回复应增加新信息或新见解，不要重复
4. 确信分析完整且正确时，在回复最后一行写 AGREED: <共识结论>
5. 不要过早同意。最多 $max_rounds 轮讨论。

重要格式要求：
- 当你要表示同意时，必须在回复中直接输出独立一行 AGREED: <结论>
- 不要描述你会写什么，直接写出来。错误示例："我在文件中写入 AGREED:" — 正确示例：直接输出 AGREED: xxx
- AGREED 行必须独占一行，不要嵌套在其他句子中
SYSPROMPT
}

# ======================== 裁判功能 ========================

# 裁判 system prompt（自由辩论模式）
# 裁判独立于参与者，客观总结并判断是否实质达成一致
build_referee_free_prompt() {
  cat << 'REFEREE_FREE'
你是一位公正的讨论裁判。你的职责是：
1. 客观总结各参与者本轮的核心观点
2. 识别各方的共识和分歧
3. 判断是否已实质达成一致（即使没有明确说 AGREED）

请严格按以下格式输出：

## 本轮总结
（简要概括各参与者的核心论点）

## 共识与分歧
（列出已达成一致的要点和仍有分歧的要点）

## 裁判判定
CONSENSUS: YES 或 CONSENSUS: NO
（如果 YES，必须紧接着下一行输出）
AGREED: <最终结论的简要概括>

注意：只有在各方观点确实在关键议题上没有实质分歧时才判定 YES。
不要过早判定共识，除非分歧已经真正解决。
REFEREE_FREE
}

# 裁判 system prompt（上帝视角模式）
# 格式化输出差异点，辅助上帝做出判断
build_referee_god_prompt() {
  cat << 'REFEREE_GOD'
你是一位公正的讨论裁判，你需要为「上帝视角」的操控者提供决策辅助。

请严格按以下格式输出：

## 本轮总结
（简要概括各参与者的核心论点，2-3 句话）

## 差异对比表
| 议题 | 参与者A | 参与者B | ... |
|------|---------|---------|-----|
| 议题1 | 立场/方案 | 立场/方案 | ... |
| 议题2 | 立场/方案 | 立场/方案 | ... |

（用实际参与者名称替换表头）

## 关键分歧点
（列出 2-3 个最重要的分歧，简要说明各方理由）

## 建议关注
（给上帝视角操控者的建议：哪些分歧值得介入引导？）

注意：保持客观，不要偏向任何一方。
REFEREE_GOD
}

# 裁判最终总结 prompt（讨论结束后生成综合总结）
build_referee_final_prompt() {
  cat << 'REFEREE_FINAL'
你是讨论裁判。请综合全部讨论记录，输出一份完整的总结文档。

输出格式要求（Markdown）：
# 总结：<主题标题>

## 1. 问题概述
简明扼要地总结讨论主题和核心问题。

## 2. 主要共识
列出讨论中各方达成一致的关键点。

## 3. 主要分歧
列出讨论中各方未达成一致的点，并说明各方理由。

## 4. 关键结论
列出讨论中确定的重要结论及其依据。

## 5. 待解决问题
列出仍需进一步讨论或行动的问题（如果有）。

规则：
- 直接输出 Markdown 内容，不要输出任何解释性前缀
- 使用中文
- 内容必须基于讨论记录中的实际观点，不要编造
- 保持结构清晰、客观中立
REFEREE_FINAL
}

# 调用裁判
# 参数: $1=裁判 agent 基础类型, $2=裁判 prompt, $3=用户消息, $4=session tag(可选)
# 输出: stdout 裁判总结文本
call_referee() {
  local referee_base="$1"
  local referee_prompt="$2"
  local user_msg="$3"
  local session_tag="${4:-}"
  "call_${referee_base}" "$referee_prompt" "$user_msg" "$session_tag"
}

# 裁判生成最终设计方案
# 参数: $1=裁判 base 类型, $2=自定义提示词(可空)
# 依赖全局: ROUNDS_DIR, PROBLEM_FILE, CONSENSUS_FILE, CONFIG_FILE
generate_final_summary() {
  local ref_base="$1"
  local custom_prompt="${2:-}"

  log_and_print ""
  log_and_print "${BOLD}📝 裁判正在生成最终总结...${NC}"

  # 收集所有轮次内容
  local all_rounds=""
  for f in $(ls -1 "$ROUNDS_DIR"/*.md 2>/dev/null | sort); do
    local fname
    fname=$(basename "$f")
    all_rounds+="\n--- ${fname} ---\n"
    all_rounds+=$(cat "$f")
    all_rounds+="\n"
  done

  local problem
  problem=$(cat "$PROBLEM_FILE")

  local consensus=""
  if [ -f "$CONSENSUS_FILE" ]; then
    consensus=$(cat "$CONSENSUS_FILE")
  fi

  local final_prompt
  final_prompt=$(build_referee_final_prompt)
  if [ -n "$custom_prompt" ]; then
    final_prompt+=$'\n\n[额外指示]\n'"$custom_prompt"
  fi

  local user_content="<discussion_topic>
${problem}
</discussion_topic>

<consensus>
${consensus:-未达成明确共识}
</consensus>

<discussion_records>
${all_rounds}
</discussion_records>"

  local summary_text
  summary_text=$(call_referee "$ref_base" "$final_prompt" "$user_content" "final_summary")

  if [ -z "$summary_text" ]; then
    log_and_print "${RED}❌ 生成最终总结失败${NC}"
    return 1
  fi

  local summary_file="SUMMARY.md"
  echo "$summary_text" > "$summary_file"

  log_and_print ""
  log_and_print "${BOLD}╔══════════════════════════════════════════╗${NC}"
  log_and_print "${BOLD}║      📋 最终总结已生成                    ║${NC}"
  log_and_print "${BOLD}╚══════════════════════════════════════════╝${NC}"
  log_and_print "  📄 文件: ${BOLD}${summary_file}${NC}"
  log_and_print "  🔨 裁判: ${ref_base}"
  log_and_print ""
}

# ======================== 命令: run ========================
cmd_run() {
  local agents="$DEFAULT_AGENTS"
  local max_rounds="$DEFAULT_MAX_ROUNDS"
  local god_mode=false
  local referee_mode=false
  local referee_agent=""  # 空=使用第一个 agent

  # 解析参数
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agents|-a)  agents="$2"; shift 2 ;;
      --rounds|-r)  max_rounds="$2"; shift 2 ;;
      --god|-g)     god_mode=true; shift ;;
      --referee)    referee_mode=true
                    # 可选参数: --referee [agent_name]
                    if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                      referee_agent="$2"; shift
                    fi
                    shift ;;
      *) echo -e "${RED}未知参数: $1${NC}"; cmd_help; exit 1 ;;
    esac
  done

  # ---- 阶段 0: 裁判提示词检查 ----
  local referee_custom_prompt=""
  if $referee_mode; then
    if [ -f "$REFEREE_PROMPT_FILE" ] && [ -s "$REFEREE_PROMPT_FILE" ]; then
      referee_custom_prompt=$(cat "$REFEREE_PROMPT_FILE")
      echo -e "${CYAN}📋 已加载裁判提示词: ${REFEREE_PROMPT_FILE}${NC}"
    else
      echo -e "${YELLOW}⚠️  未找到裁判提示词文件: ${REFEREE_PROMPT_FILE}${NC}"
      echo -e "  你可以创建该文件来自定义裁判的行为，例如:"
      echo -e "  ${CYAN}echo '重点关注架构设计的可行性和成本' > ${REFEREE_PROMPT_FILE}${NC}"
      echo ""
      echo -ne "${BOLD}是否跳过，使用默认裁判提示词？[Y/n]: ${NC}"
      local ref_choice
      read -er ref_choice
      case "$ref_choice" in
        n|N|no|NO)
          echo -e "${CYAN}请创建 ${REFEREE_PROMPT_FILE} 后重新运行。${NC}"
          exit 0
          ;;
        *)
          echo -e "${CYAN}使用默认裁判提示词。${NC}"
          ;;
      esac
      echo ""
    fi
  fi

  # ---- 阶段 1: 初始化 ----

  # 检查是否存在历史讨论记录
  local resume_mode=false
  if [ -f "$CONFIG_FILE" ] || [ -d "$ROUNDS_DIR" ] && [ "$(ls -A "$ROUNDS_DIR" 2>/dev/null)" ]; then
    local prev_status=""
    local prev_round=0
    local prev_agents=""
    local prev_max_rounds=0
    if [ -f "$CONFIG_FILE" ]; then
      prev_status=$(jq -r '.status // "unknown"' "$CONFIG_FILE" 2>/dev/null)
      prev_round=$(jq -r '.current_round // 0' "$CONFIG_FILE" 2>/dev/null)
      prev_agents=$(jq -r '.agents // ""' "$CONFIG_FILE" 2>/dev/null)
      prev_max_rounds=$(jq -r '.max_rounds // 0' "$CONFIG_FILE" 2>/dev/null)
    fi
    local round_count=0
    if [ -d "$ROUNDS_DIR" ]; then
      round_count=$(ls -1 "$ROUNDS_DIR"/*.md 2>/dev/null | wc -l | xargs)
    fi

    echo -e "${YELLOW}⚠️  检测到历史讨论记录${NC}"
    echo -e "  状态: ${BOLD}${prev_status}${NC}"
    echo -e "  轮次: ${BOLD}${prev_round}/${prev_max_rounds}${NC}"
    echo -e "  参与: ${BOLD}${prev_agents}${NC}"
    echo -e "  文件: ${round_count} 个回复记录"
    echo ""
    echo -e "  ${BOLD}1)${NC} 清理历史，重新开始"
    # 仅当配置完整且有历史轮次时，才提供继续选项
    if [ -n "$prev_agents" ] && [ "$prev_round" -gt 0 ] 2>/dev/null; then
      echo -e "  ${BOLD}2)${NC} 从 Round $((prev_round + 1)) 继续讨论"
      echo -e "  ${BOLD}3)${NC} 取消执行"
      echo ""
      echo -ne "${BOLD}请选择 [1/2/3]: ${NC}"
    else
      echo -e "  ${BOLD}2)${NC} 取消执行"
      echo ""
      echo -ne "${BOLD}请选择 [1/2]: ${NC}"
    fi
    local choice
    read -er choice

    case "$choice" in
      1)
        echo -e "${CYAN}清理历史记录...${NC}"
        rm -rf "$ROUNDS_DIR" "$SESSIONS_DIR" "$CONFIG_FILE" "$CONSENSUS_FILE" "$LOG_FILE" SUMMARY.md
        ;;
      2)
        # 仅当有完整配置时 2=继续，否则 2=取消
        if [ -n "$prev_agents" ] && [ "$prev_round" -gt 0 ] 2>/dev/null; then
          resume_mode=true
          # 恢复历史 agents（必须一致），max_rounds 使用命令行参数
          agents="$prev_agents"
          echo -e "${CYAN}从 Round $((prev_round + 1)) 继续讨论 (最大轮次: ${max_rounds})...${NC}"
        else
          echo -e "${CYAN}已取消。${NC}"
          exit 0
        fi
        ;;
      *)
        echo -e "${CYAN}已取消。${NC}"
        exit 0
        ;;
    esac
    echo ""
  fi

  # 检查 problem.md
  if [ ! -f "$PROBLEM_FILE" ]; then
    echo -e "${RED}❌ 当前目录缺少 $PROBLEM_FILE${NC}"
    echo -e "${CYAN}请先创建讨论问题:${NC}"
    echo -e "  echo \"你的问题\" > $PROBLEM_FILE"
    exit 1
  fi

  if [ ! -s "$PROBLEM_FILE" ]; then
    echo -e "${RED}❌ $PROBLEM_FILE 为空${NC}"
    exit 1
  fi

  local problem
  problem=$(cat "$PROBLEM_FILE")

  echo -e "${BOLD}🔍 检查 Agent 可用性...${NC}"
  echo ""

  # 解析 agent 列表，支持重复 agent（如 claude,claude）
  IFS=',' read -ra RAW_AGENT_LIST <<< "$agents"
  local available_agents=()

  # 统计每个 agent 类型出现次数（bash 3.x 兼容，用字符串模拟）
  # 格式: "|name:count|name:count|"
  local _agent_total="|"
  for agent in "${RAW_AGENT_LIST[@]}"; do
    agent=$(echo "$agent" | xargs)  # trim
    local _cur_total
    _cur_total=$(echo "$_agent_total" | sed -n "s/.*|${agent}:\([0-9]*\)|.*/\1/p")
    _cur_total=$(( ${_cur_total:-0} + 1 ))
    if echo "$_agent_total" | grep -q "|${agent}:"; then
      _agent_total=$(echo "$_agent_total" | sed "s/|${agent}:[0-9]*|/|${agent}:${_cur_total}|/")
    else
      _agent_total="${_agent_total}${agent}:${_cur_total}|"
    fi
  done

  # ---- Phase 1: 去重收集 agent 类型 + 注册验证 ----
  local unique_agents="|"  # 需要检查的不同 agent 类型（去重）

  for agent in "${RAW_AGENT_LIST[@]}"; do
    agent=$(echo "$agent" | xargs)  # trim

    # 检查是否已注册
    local registered=false
    for ra in "${REGISTERED_AGENTS[@]}"; do
      if [ "$ra" == "$agent" ]; then
        registered=true
        break
      fi
    done

    if ! $registered; then
      echo -e "  ${RED}✗ $agent — 未注册的 Agent${NC}"
      echo -e "    已注册: ${REGISTERED_AGENTS[*]}"
      exit 1
    fi

    # 收集不重复的 agent 类型
    if ! echo "$unique_agents" | grep -q "|${agent}|"; then
      unique_agents="${unique_agents}${agent}|"
    fi
  done

  # ---- Phase 2: 并发检查所有不同类型的可用性 ----
  # 为每个 agent 类型创建状态文件，后台并发执行
  local check_pids=()
  local check_agents=()
  local check_status_dir
  check_status_dir=$(mktemp -d)

  # 从 unique_agents 字符串解析出 agent 列表
  local _ua_list
  _ua_list=$(echo "$unique_agents" | tr '|' '\n' | sed '/^$/d')

  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    check_agents+=("$agent")
    # 后台执行可用性检查，结果写入状态文件
    (
      if "check_$agent" 2>"${check_status_dir}/${agent}.err"; then
        echo "ok" > "${check_status_dir}/${agent}.status"
      else
        echo "fail" > "${check_status_dir}/${agent}.status"
      fi
    ) &
    check_pids+=($!)
  done <<< "$_ua_list"

  echo -ne "  ${CYAN}并发检查 ${#check_agents[@]} 个 Agent...${NC}"

  # 等待所有检查完成
  for pid in "${check_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  echo "" # 检查完成后换行

  # 汇总检查结果
  for agent in "${check_agents[@]}"; do
    local status
    status=$(cat "${check_status_dir}/${agent}.status" 2>/dev/null || echo "fail")
    if [ "$status" = "ok" ]; then
      echo -e "  ${BOLD}$agent${NC} ${GREEN}✓ 可用${NC}"
    else
      echo -e "  ${BOLD}$agent${NC} ${RED}✗ 不可用${NC}"
      # 显示错误信息
      if [ -f "${check_status_dir}/${agent}.err" ] && [ -s "${check_status_dir}/${agent}.err" ]; then
        cat "${check_status_dir}/${agent}.err" >&2
      fi
      rm -rf "$check_status_dir"
      exit 1
    fi
  done
  rm -rf "$check_status_dir"

  # ---- Phase 3: 生成实例名 ----
  local _agent_count="|"
  for agent in "${RAW_AGENT_LIST[@]}"; do
    agent=$(echo "$agent" | xargs)  # trim

    # 生成实例名：有重复则添加 _1, _2 后缀
    local _cur_count
    _cur_count=$(echo "$_agent_count" | sed -n "s/.*|${agent}:\([0-9]*\)|.*/\1/p")
    _cur_count=$(( ${_cur_count:-0} + 1 ))
    if echo "$_agent_count" | grep -q "|${agent}:"; then
      _agent_count=$(echo "$_agent_count" | sed "s/|${agent}:[0-9]*|/|${agent}:${_cur_count}|/")
    else
      _agent_count="${_agent_count}${agent}:${_cur_count}|"
    fi

    local instance_name="$agent"
    local _total
    _total=$(echo "$_agent_total" | sed -n "s/.*|${agent}:\([0-9]*\)|.*/\1/p")
    if [ "${_total:-1}" -gt 1 ]; then
      instance_name="${agent}_${_cur_count}"
    fi

    available_agents+=("$instance_name")
  done

  echo ""

  if [ ${#available_agents[@]} -lt 2 ]; then
    echo -e "${RED}❌ 至少需要 2 个可用 Agent 才能进行讨论${NC}"
    exit 1
  fi

  # 创建 rounds 目录
  mkdir -p "$ROUNDS_DIR"
  mkdir -p "$SESSIONS_DIR"

  # 动态生成各 Agent 的指令文件（新建和恢复模式都需要更新）
  for agent in "${available_agents[@]}"; do
    local md_file base
    md_file=$(agent_md_file "$agent")
    base=$(agent_base "$agent")
    "generate_${base}_md" "$max_rounds" "$problem" > "$md_file"
    if $resume_mode; then
      echo -e "  ${CYAN}🔄 更新 $md_file (轮次: $max_rounds)${NC}"
    else
      echo -e "  ${CYAN}📝 生成 $md_file${NC}"
    fi
  done

  # 初始化 git（codex 需要）
  if [ ! -d ".git" ]; then
    git init -q
    echo ".debate.log" >> .gitignore 2>/dev/null || true
    echo ".debate.json" >> .gitignore 2>/dev/null || true
    git add -A 2>/dev/null || true
    git commit -q -m "ai-battle: init" 2>/dev/null || true
  fi

  # ---- 阶段 2: 开始讨论 ----

  local agent_count=${#available_agents[@]}

  local sys_prompt
  sys_prompt=$(build_system_prompt "$max_rounds")

  # 上帝视角累积信息
  local god_context=""

  # 构建 agents 显示标题
  local agents_display="${available_agents[0]}"
  for ((idx=1; idx<agent_count; idx++)); do
    agents_display+=" vs ${available_agents[$idx]}"
  done

  echo ""
  log_and_print "${BOLD}╔══════════════════════════════════════════╗${NC}"
  log_and_print "${BOLD}║    AI 圆桌讨论: ${agents_display}${NC}"
  log_and_print "${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo ""
  log_and_print "  📝 问题: $(head -1 "$PROBLEM_FILE")"
  log_and_print "  🤖 Agent: ${available_agents[*]}"
  log_and_print "  🔄 最大轮次: $max_rounds"
  if $god_mode; then
    log_and_print "${CYAN}  👁️  上帝视角: 开启${NC}"
  fi

  # 裁判 agent 解析: 默认使用第一个 available agent 的基础类型
  local referee_base=""
  if $referee_mode; then
    if [ -n "$referee_agent" ]; then
      # 验证指定的裁判 agent 是否已注册
      local ref_valid=false
      for ra in "${REGISTERED_AGENTS[@]}"; do
        if [ "$ra" == "$referee_agent" ]; then
          ref_valid=true
          break
        fi
      done
      if ! $ref_valid; then
        echo -e "${RED}❌ 裁判 agent '$referee_agent' 未注册${NC}"
        exit 1
      fi
      referee_base="$referee_agent"
    else
      referee_base=$(agent_base "${available_agents[0]}")
    fi
    log_and_print "  🔨 裁判: ${BOLD}${referee_base}${NC}"
  fi

  log_and_print "${CYAN}  日志: tail -f $LOG_FILE${NC}"
  echo ""

  # 使用普通数组存储每个 agent 的最新回复（索引与 available_agents 对应）
  local responses=()

  # 恢复模式起始轮次（默认从 Round 2 开始）
  local round=2

  if $resume_mode; then
    # ---- 恢复模式: 从历史记录恢复状态 ----
    local prev_round
    prev_round=$(jq -r '.current_round // 0' "$CONFIG_FILE" 2>/dev/null)
    round=$((prev_round + 1))

    # 更新配置: 状态为 running，max_rounds 使用命令行参数
    jq --argjson m "$max_rounds" '.status = "running" | .max_rounds = $m' \
      "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
      && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    log_and_print "${CYAN}🔄 恢复模式: 从 Round ${round} 继续${NC}"
    log_and_print "${CYAN}  加载历史回复 (Round ${prev_round})...${NC}"

    # 从最近一轮的回复文件恢复 responses[] 数组
    for ((i=0; i<agent_count; i++)); do
      local agent="${available_agents[$i]}"
      local reply_file="$ROUNDS_DIR/round_${prev_round}_${agent}.md"
      if [ -f "$reply_file" ]; then
        responses[$i]=$(cat "$reply_file")
        log_and_print "  ${GREEN}✓${NC} ${agent} Round ${prev_round} 回复已加载"
      else
        log_and_print "${RED}❌ 缺少 ${reply_file}，无法恢复${NC}"
        exit 1
      fi
    done

    # 恢复上帝视角历史信息
    local god_file="$ROUNDS_DIR/god_round_${prev_round}.md"
    if [ -f "$god_file" ]; then
      god_context=$(cat "$god_file")
      log_and_print "  ${GREEN}✓${NC} 上帝视角 Round ${prev_round} 信息已加载"
    fi

    echo ""
  else
    # ---- 正常模式: 写入配置并执行 Round 1 ----

    # 写入配置（供恢复模式使用）
    jq -n \
      --arg agents "$(IFS=,; echo "${available_agents[*]}")" \
      --argjson max_rounds "$max_rounds" \
      --arg problem "$problem" \
      '{agents: $agents, max_rounds: $max_rounds, problem: $problem,
        status: "running", current_round: 0}' \
      > "$CONFIG_FILE"

    # 清空日志
    : > "$LOG_FILE"

    # ---- Round 1: 所有 agent 并行独立思考 ----
    log_and_print "${CYAN}⏳ Round 1: ${agent_count} 位参与者独立思考中...${NC}"

    local tmp_files=()
    local pids=()
    for ((i=0; i<agent_count; i++)); do
      local agent="${available_agents[$i]}"
      local base
      base=$(agent_base "$agent")
      local tmp
      tmp=$(mktemp)
      tmp_files+=("$tmp")
      (
        "call_${base}" "$sys_prompt" "请对以下问题给出你的深入分析：

$problem" "round_1_${agent}" > "$tmp" 2>/dev/null
      ) &
      pids+=($!)
    done

    # 等待全部完成
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done

    # 读取所有回复，失败的 agent 交互式重试
    for ((i=0; i<agent_count; i++)); do
      local agent="${available_agents[$i]}"
      local base
      base=$(agent_base "$agent")
      local color
      color=$(agent_color "$agent")
      if [ -s "${tmp_files[$i]}" ]; then
        responses[$i]=$(cat "${tmp_files[$i]}")
        echo "${responses[$i]}" > "$ROUNDS_DIR/round_1_${agent}.md"
        log_and_print ""
        log_and_print "${color}━━━ ${agent} [Round 1/${max_rounds}] ━━━${NC}"
        log_and_print "${color}${responses[$i]}${NC}"
      else
        log_and_print "${YELLOW}⚠️ ${agent} Round 1 并发调用失败，进入交互式重试...${NC}"
        responses[$i]=$(retry_call_agent "${agent} [Round 1]" "call_${base}" "$sys_prompt" "请对以下问题给出你的深入分析：

$problem" "round_1_${agent}")
        if [ -n "${responses[$i]}" ]; then
          echo "${responses[$i]}" > "$ROUNDS_DIR/round_1_${agent}.md"
          log_and_print ""
          log_and_print "${color}━━━ ${agent} [Round 1/${max_rounds}] ━━━${NC}"
          log_and_print "${color}${responses[$i]}${NC}"
        else
          log_and_print "${YELLOW}⏭️  ${agent} Round 1 已跳过${NC}"
        fi
      fi
      rm -f "${tmp_files[$i]}"
    done

    log_and_print ""
    log_and_print "${CYAN}✅ Round 1 完成${NC}"

    # 检查 Round 1 共识（所有人都 AGREED 才算）
    local all_agreed_r1=true
    for ((i=0; i<agent_count; i++)); do
      if ! has_agreed "${responses[$i]}"; then
        all_agreed_r1=false
        break
      fi
    done
    if $all_agreed_r1; then
      local conclusion
      conclusion=$(extract_agreed "${responses[0]}")
      finish_consensus "$conclusion" 1 "$max_rounds"
      $referee_mode && generate_final_summary "$referee_base" "$referee_custom_prompt"
      exit 0
    fi

    # 上帝视角: Round 1 后注入
    if $god_mode; then
      god_context=$(god_input 1)
    fi
  fi

  # 恢复模式 + 上帝视角: 判断上次是否在上帝视角阶段退出
  if $resume_mode && $god_mode; then
    local prev_round_num=$((round - 1))
    local god_file="$ROUNDS_DIR/god_round_${prev_round_num}.md"
    if [ ! -f "$god_file" ]; then
      # 上次在上帝视角阶段退出，重新触发
      log_and_print "${CYAN}👁️  恢复上帝视角 (Round ${prev_round_num})${NC}"
      god_context=$(god_input "$prev_round_num")
    fi
    # 文件已存在的情况，god_context 在上面恢复阶段已加载
  fi

  # ---- Round 2+: N 方顺序对话 ----
  # 提取为函数逻辑，供主循环和追加轮次复用
  while [ "$round" -le "$max_rounds" ]; do
    local remaining=$((max_rounds - round))

    # 每个 agent 依次发言，看到所有其他 agent 的上一轮回复
    for ((i=0; i<agent_count; i++)); do
      local agent="${available_agents[$i]}"
      local base
      base=$(agent_base "$agent")
      local color
      color=$(agent_color "$agent")

      log_and_print ""
      log_and_print "${CYAN}⏳ Round $round: ${agent} 思考中...${NC}"

      # 构建其他 agent 回复的 XML 块
      local others_responses=""
      for ((j=0; j<agent_count; j++)); do
        if [ "$j" != "$i" ]; then
          local other="${available_agents[$j]}"
          others_responses+="<${other}_response>
${responses[$j]}
</${other}_response>

"
        fi
      done

      local prompt="以下是其他参与者的上一轮回复：\n\n${others_responses}请回应以上观点。剩余 $remaining 轮。"
      if [ -n "$god_context" ]; then
        prompt+="\n\n[上帝视角 - 额外补充信息]\n${god_context}"
      fi

      responses[$i]=$(retry_call_agent "${agent} [Round ${round}]" "call_${base}" "$sys_prompt" "$prompt" "round_${round}_${agent}")
      if [ -z "${responses[$i]}" ]; then
        log_and_print "${YELLOW}⏭️  ${agent} Round ${round} 已跳过${NC}"
        continue
      fi
      echo "${responses[$i]}" > "$ROUNDS_DIR/round_${round}_${agent}.md"
      log_and_print ""
      log_and_print "${color}━━━ ${agent} [Round ${round}/${max_rounds}] ━━━${NC}"
      log_and_print "${color}${responses[$i]}${NC}"

      # 检查该 agent 是否提出 AGREED
      if has_agreed "${responses[$i]}"; then
        local conclusion
        conclusion=$(extract_agreed "${responses[$i]}")
        log_and_print "${CYAN}${agent} 提出共识，等待其他 agent 确认...${NC}"

        # 向所有其他 agent 发送确认请求
        local all_confirmed=true
        for ((k=0; k<agent_count; k++)); do
          if [ "$k" != "$i" ]; then
            local other="${available_agents[$k]}"
            local other_base
            other_base=$(agent_base "$other")
            local other_color
            other_color=$(agent_color "$other")

            local confirm
            confirm=$(retry_call_agent "${other} [确认]" "call_${other_base}" "$sys_prompt" "${agent} 提出了共识：

<proposed_consensus>
$conclusion
</proposed_consensus>

请审查这个结论是否完整正确。如果同意，在回复末尾写 AGREED: <结论>。如果不同意，说明原因。" "round_${round}_${other}_confirm")
            if [ -z "$confirm" ]; then
              log_and_print "${YELLOW}⏭️  ${other} 确认已跳过，视为不同意${NC}"
              all_confirmed=false
              break
            fi
            echo "$confirm" > "$ROUNDS_DIR/round_${round}_${other}_confirm.md"
            log_and_print "${other_color}━━━ ${other} [确认] ━━━${NC}"
            log_and_print "${other_color}${confirm}${NC}"

            if has_agreed "$confirm"; then
              log_and_print "${CYAN}  ✓ ${other} 同意${NC}"
            else
              log_and_print "${YELLOW}  ✗ ${other} 不同意，讨论继续${NC}"
              responses[$k]="$confirm"  # 更新该 agent 的回复供后续轮次使用
              all_confirmed=false
              break
            fi
          fi
        done

        if $all_confirmed; then
          local final
          final=$(extract_agreed "${responses[$i]}")
          finish_consensus "$final" "$round" "$max_rounds"
          $referee_mode && generate_final_summary "$referee_base" "$referee_custom_prompt"
          exit 0
        fi
      fi
    done

    # ---- 裁判总结: 所有 agent 发言完毕后 ----
    if $referee_mode; then
      log_and_print ""
      log_and_print "${BOLD}\033[1;37m━━━ 🔨 裁判总结 [Round ${round}/${max_rounds}] ━━━${NC}"
      log_and_print "${CYAN}⏳ 裁判分析中...${NC}"

      # 构建所有 agent 回复的汇总
      local all_responses=""
      for ((ri=0; ri<agent_count; ri++)); do
        local ra="${available_agents[$ri]}"
        all_responses+="<${ra}_response>
${responses[$ri]}
</${ra}_response>

"
      done

      # 根据模式选择裁判 prompt
      local ref_prompt
      if $god_mode; then
        ref_prompt=$(build_referee_god_prompt)
      else
        ref_prompt=$(build_referee_free_prompt)
      fi
      # 追加自定义裁判提示词
      if [ -n "$referee_custom_prompt" ]; then
        ref_prompt+=$'\n\n[额外指示]\n'"$referee_custom_prompt"
      fi

      local referee_result
      referee_result=$(call_referee "$referee_base" "$ref_prompt" "以下是 Round ${round} 各参与者的回复：

${all_responses}请进行裁判总结。" "referee_round_${round}")

      # 保存裁判结果
      echo "$referee_result" > "$ROUNDS_DIR/referee_round_${round}.md"
      log_and_print "${BOLD}\033[1;37m${referee_result}${NC}"

      # 自由辩论模式: 裁判检测共识
      if ! $god_mode; then
        if echo "$referee_result" | grep -qiE 'CONSENSUS:[[:space:]]*YES'; then
          local ref_conclusion
          ref_conclusion=$(echo "$referee_result" | grep -ioE '\*{0,2}AGREED:[[:space:]]*.*' | head -1 \
            | sed 's/^\*\{0,2\}[Aa][Gg][Rr][Ee][Ee][Dd]:[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/\*\{1,2\}$//')
          if [ -n "$ref_conclusion" ]; then
            log_and_print "${CYAN}🔨 裁判判定: 已达成共识${NC}"
            finish_consensus "$ref_conclusion" "$round" "$max_rounds"
            generate_final_summary "$referee_base" "$referee_custom_prompt"
            exit 0
          fi
        fi
      fi
    fi

    # 更新配置
    jq --argjson r "$round" '.current_round = $r | .status = "running"' \
      "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 上帝视角: 每轮结束后注入（裁判总结后再让 god 输入）
    if $god_mode && [ "$round" -lt "$max_rounds" ]; then
      god_context=$(god_input "$round")
    fi

    round=$((round + 1))
  done

  # 超过最大轮次，询问是否追加
  while true; do
    log_and_print ""
    log_and_print "${YELLOW}╔════════════════════════════════════════╗${NC}"
    log_and_print "${YELLOW}║    讨论结束，未达成共识                  ║${NC}"
    log_and_print "${YELLOW}╚════════════════════════════════════════╝${NC}"
    log_and_print "${CYAN}已完成 $((round - 1)) 轮，所有回复保存在: $ROUNDS_DIR/${NC}"

    # 交互式询问是否追加轮次
    local extra_rounds=""
    echo ""
    echo -ne "${BOLD}是否追加讨论轮次？输入轮次数（默认 ${max_rounds}，0 或回车结束）: ${NC}"
    read -er extra_rounds

    # 空输入或 0 表示结束
    if [ -z "$extra_rounds" ] || [ "$extra_rounds" = "0" ]; then
      log_and_print "${CYAN}讨论结束。${NC}"
      jq '.status = "no_consensus"' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" \
        && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
      $referee_mode && generate_final_summary "$referee_base" "$referee_custom_prompt"
      return
    fi

    # 验证输入为正整数
    if ! [[ "$extra_rounds" =~ ^[1-9][0-9]*$ ]]; then
      echo -e "${RED}请输入正整数${NC}"
      continue
    fi

    local new_max=$((round - 1 + extra_rounds))
    max_rounds="$new_max"
    log_and_print "${CYAN}追加 $extra_rounds 轮，总轮次上限: $max_rounds${NC}"
    echo ""

    # 更新配置
    jq --argjson m "$max_rounds" '.max_rounds = $m' \
      "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

    # 继续讨论循环（逻辑与上方 Round 2+ 完全相同）
    while [ "$round" -le "$max_rounds" ]; do
      local remaining=$((max_rounds - round))

      for ((i=0; i<agent_count; i++)); do
        local agent="${available_agents[$i]}"
        local base
        base=$(agent_base "$agent")
        local color
        color=$(agent_color "$agent")

        log_and_print ""
        log_and_print "${CYAN}⏳ Round $round: ${agent} 思考中...${NC}"

        # 构建其他 agent 回复的 XML 块
        local others_responses=""
        for ((j=0; j<agent_count; j++)); do
          if [ "$j" != "$i" ]; then
            local other="${available_agents[$j]}"
            others_responses+="<${other}_response>
${responses[$j]}
</${other}_response>

"
          fi
        done

        local prompt="以下是其他参与者的上一轮回复：\n\n${others_responses}请回应以上观点。剩余 $remaining 轮。"
        if [ -n "$god_context" ]; then
          prompt+="\n\n[上帝视角 - 额外补充信息]\n${god_context}"
        fi

        responses[$i]=$(retry_call_agent "${agent} [Round ${round}]" "call_${base}" "$sys_prompt" "$prompt" "round_${round}_${agent}")
        if [ -z "${responses[$i]}" ]; then
          log_and_print "${YELLOW}⏭️  ${agent} Round ${round} 已跳过${NC}"
          continue
        fi
        echo "${responses[$i]}" > "$ROUNDS_DIR/round_${round}_${agent}.md"
        log_and_print ""
        log_and_print "${color}━━━ ${agent} [Round ${round}/${max_rounds}] ━━━${NC}"
        log_and_print "${color}${responses[$i]}${NC}"

        # 检查该 agent 是否提出 AGREED
        if has_agreed "${responses[$i]}"; then
          local conclusion
          conclusion=$(extract_agreed "${responses[$i]}")
          log_and_print "${CYAN}${agent} 提出共识，等待其他 agent 确认...${NC}"

          local all_confirmed=true
          for ((k=0; k<agent_count; k++)); do
            if [ "$k" != "$i" ]; then
              local other="${available_agents[$k]}"
              local other_base
              other_base=$(agent_base "$other")
              local other_color
              other_color=$(agent_color "$other")

              local confirm
              confirm=$(retry_call_agent "${other} [确认]" "call_${other_base}" "$sys_prompt" "${agent} 提出了共识：

<proposed_consensus>
$conclusion
</proposed_consensus>

请审查这个结论是否完整正确。如果同意，在回复末尾写 AGREED: <结论>。如果不同意，说明原因。" "round_${round}_${other}_confirm")
              if [ -z "$confirm" ]; then
                log_and_print "${YELLOW}⏭️  ${other} 确认已跳过，视为不同意${NC}"
                all_confirmed=false
                break
              fi
              echo "$confirm" > "$ROUNDS_DIR/round_${round}_${other}_confirm.md"
              log_and_print "${other_color}━━━ ${other} [确认] ━━━${NC}"
              log_and_print "${other_color}${confirm}${NC}"

              if has_agreed "$confirm"; then
                log_and_print "${CYAN}  ✓ ${other} 同意${NC}"
              else
                log_and_print "${YELLOW}  ✗ ${other} 不同意，讨论继续${NC}"
                responses[$k]="$confirm"
                all_confirmed=false
                break
              fi
            fi
          done

          if $all_confirmed; then
            local final
            final=$(extract_agreed "${responses[$i]}")
            finish_consensus "$final" "$round" "$max_rounds"
            $referee_mode && generate_final_summary "$referee_base" "$referee_custom_prompt"
            exit 0
          fi
        fi
      done

      # ---- 裁判总结: 追加轮次中同样执行 ----
      if $referee_mode; then
        log_and_print ""
        log_and_print "${BOLD}\033[1;37m━━━ 🔨 裁判总结 [Round ${round}/${max_rounds}] ━━━${NC}"
        log_and_print "${CYAN}⏳ 裁判分析中...${NC}"

        local all_responses=""
        for ((ri=0; ri<agent_count; ri++)); do
          local ra="${available_agents[$ri]}"
          all_responses+="<${ra}_response>
${responses[$ri]}
</${ra}_response>

"
        done

        local ref_prompt
        if $god_mode; then
          ref_prompt=$(build_referee_god_prompt)
        else
          ref_prompt=$(build_referee_free_prompt)
        fi
        # 追加自定义裁判提示词
        if [ -n "$referee_custom_prompt" ]; then
          ref_prompt+=$'\n\n[额外指示]\n'"$referee_custom_prompt"
        fi

        local referee_result
        referee_result=$(call_referee "$referee_base" "$ref_prompt" "以下是 Round ${round} 各参与者的回复：

${all_responses}请进行裁判总结。" "referee_round_${round}")

        echo "$referee_result" > "$ROUNDS_DIR/referee_round_${round}.md"
        log_and_print "${BOLD}\033[1;37m${referee_result}${NC}"

        if ! $god_mode; then
          if echo "$referee_result" | grep -qiE 'CONSENSUS:[[:space:]]*YES'; then
            local ref_conclusion
            ref_conclusion=$(echo "$referee_result" | grep -ioE '\*{0,2}AGREED:[[:space:]]*.*' | head -1 \
              | sed 's/^\*\{0,2\}[Aa][Gg][Rr][Ee][Ee][Dd]:[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's/\*\{1,2\}$//')
            if [ -n "$ref_conclusion" ]; then
              log_and_print "${CYAN}🔨 裁判判定: 已达成共识${NC}"
              finish_consensus "$ref_conclusion" "$round" "$max_rounds"
              generate_final_summary "$referee_base" "$referee_custom_prompt"
              exit 0
            fi
          fi
        fi
      fi

      # 更新配置
      jq --argjson r "$round" '.current_round = $r | .status = "running"' \
        "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

      # 上帝视角: 每轮结束后注入（裁判总结后再让 god 输入）
      if $god_mode && [ "$round" -lt "$max_rounds" ]; then
        god_context=$(god_input "$round")
      fi

      round=$((round + 1))
    done
  done
}

# 共识达成处理
finish_consensus() {
  local conclusion="$1" round="$2" max_rounds="$3"
  echo "$conclusion" > "$CONSENSUS_FILE"

  log_and_print ""
  log_and_print "${YELLOW}╔════════════════════════════════════════╗${NC}"
  log_and_print "${YELLOW}║        🎉 达成共识！                   ║${NC}"
  log_and_print "${YELLOW}╚════════════════════════════════════════╝${NC}"
  log_and_print "${BOLD}结论: ${conclusion}${NC}"
  log_and_print "${CYAN}轮次: ${round}/${max_rounds}${NC}"

  jq --arg c "$conclusion" '.status = "consensus" | .conclusion = $c' \
    "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}


# ======================== 命令: help ========================
cmd_help() {
  cat << HELP

  ai-battle — AI 圆桌讨论工具 (v${VERSION})

  让多个 AI Agent 对同一问题进行结构化讨论，自动管理轮次、
  检测共识、保存全部讨论记录。

  前置条件:
    1. 在当前目录创建 problem.md，写入讨论问题
    2. 确保参与讨论的 Agent CLI 工具已安装并可用

  依赖: jq, bash 4+, (可选) claude, codex, gemini

  用法:
    ai-battle [options]
    ai-battle help

  参数:
    --agents, -a <a1,a2>   选择参与的 Agent（默认: claude,codex）
                           支持同类 Agent: --agents gemini,gemini
    --rounds, -r <N>       最大讨论轮次（默认: 10）
    --god, -g              开启上帝视角（每轮结束后可注入补充信息）
    --referee [agent]      开启裁判模式（每轮总结差异/检测共识，结束时生成最终总结）
                           可选指定裁判使用的 Agent（默认: 第一个参与者）

  已注册 Agent:
    claude    通过 Claude CLI 调用 (需 claude 命令)
    codex     通过 codex exec 调用 (需 codex 命令)
    gemini    通过 Gemini CLI 调用 (需 gemini 命令)

  使用示例:
    # 快速开始
    mkdir my-topic && cd my-topic
    echo "微服务 vs 单体架构的优缺点？" > problem.md
    ai-battle --agents claude,gemini --rounds 8

    # 同类 Agent 自我辩论
    ai-battle --agents gemini,gemini

    # 三方圆桌讨论
    ai-battle --agents claude,codex,gemini --rounds 5

    # 裁判模式（每轮总结 + 结束时生成 SUMMARY.md）
    ai-battle --agents claude,codex,gemini --referee --rounds 5

    # 指定 claude 做裁判
    ai-battle --agents codex,gemini --referee claude --rounds 5

    # 上帝视角（每轮可人工补充信息）
    ai-battle --agents claude,codex --god

    # 裁判 + 上帝视角
    ai-battle --agents claude,codex --referee --god

  产出文件:
    rounds/                每轮讨论记录 (round_N_<agent>.md)
    rounds/referee_*.md    裁判总结记录 (开启 --referee 时)
    rounds/god_*.md        上帝视角注入记录 (开启 --god 时)
    .sessions/             Agent CLI 原始输出记录 (stream-json/json/raw)
    consensus.md           共识结论（如达成）
    SUMMARY.md             最终总结 (裁判自动生成)
    .debate.log            完整日志 (可用 tail -f 实时查看)

  扩展 Agent:
    在脚本中实现 check_<name>()、call_<name>()、generate_<name>_md()
    然后调用 register_agent "<name>"

  配置文件:
    .env                   自动加载环境变量 (启动时)
    referee.md             裁判自定义提示词 (开启 --referee 时)

  环境变量:
    Claude:
      ANTHROPIC_BASE_URL              API 地址
      ANTHROPIC_AUTH_TOKEN             认证 Token
      ANTHROPIC_DEFAULT_SONNET_MODEL   模型名称
      API_TIMEOUT_MS                  超时时间 (毫秒)

    Codex:
      CODEX_MODEL       模型名称 (默认: gpt-5.3-codex)

    Gemini:
      GEMINI_API_KEY    API Key (如需自定义)

HELP
}

# ======================== 主入口 ========================
main() {
  # 处理 help/version 等无参数命令
  case "${1:-}" in
    help|--help|-h) cmd_help; exit 0 ;;
    --version|-v)   echo "ai-battle v$VERSION"; exit 0 ;;
  esac

  # 默认行为: 启动讨论
  cmd_run "$@"
}

main "$@"
