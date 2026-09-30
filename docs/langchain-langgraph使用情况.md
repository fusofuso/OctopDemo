# LangChain / LangGraph / DeepAgents 使用情况

Octop 与 LangChain 生态的实际耦合关系：**用了什么、用在哪、由谁引入、有哪些风险**。

> **基线**：`1.0.2b4`（`origin/main` = `232030f4`）。统计数据来自该版本的源码与 `.venv` 实际安装。
> 配套文档：
> - [`docs/architecture.md`](./architecture.md) —— 整体架构
> - [`docs/存储与记忆机制.md`](./存储与记忆机制.md) —— checkpoint / 记忆落盘
> - [`docs/切换PostgreSQL指引.md`](./切换PostgreSQL指引.md) —— PG 相关的 checkpoint 依赖

---

## 0. 结论速览

| 问题 | 答案 |
|------|------|
| 用了 LangChain 吗？ | ✅ **用了**，Octop 自身 27 个文件直接 import |
| 用了 LangGraph 吗？ | ✅ **用了**，是 agent 运行时内核 |
| 是可选依赖吗？ | ❌ **不是**，是核心运行时依赖 |
| Octop 自己实现 agent 循环吗？ | ❌ 不实现，编排 `octop-harness` |
| 还有一层没被注意到的依赖？ | ✅ **`deepagents`**（harness 基于它构建） |

**一句话**：Octop 的 agent 能力 = `LangChain 生态（langchain-core / langgraph / deepagents）→ octop-harness → Octop`。

---

## 1. 依赖分层

```
┌─────────────────────────────────────────────────────────────┐
│  Octop 自身代码（src/octop/）                                │
│    27 个文件直接 import langchain* / langgraph*               │
│    · 7 个自研中间件（继承 AgentMiddleware）                   │
│    · 消息序列化 / 历史投影 / 工具包装 / cron 工具             │
└───────────────────────────┬─────────────────────────────────┘
                            │ 依赖
┌───────────────────────────▼─────────────────────────────────┐
│  octop-harness（外部包，PyPI）                               │
│    54 个文件 import langchain* / langgraph*                  │
│    28 个文件 import deepagents*                              │
│    → Agent 运行时：模型路由、工具、技能、子代理、压缩         │
└───────────────────────────┬─────────────────────────────────┘
                            │ 基于
┌───────────────────────────▼─────────────────────────────────┐
│  deepagents 0.7.9 + deepagents-backends 0.2.0               │
│    → FilesystemMiddleware、CompositeBackend、LocalShell...   │
└───────────────────────────┬─────────────────────────────────┘
                            │ 基于
┌───────────────────────────▼─────────────────────────────────┐
│  langchain 1.3.18 / langchain-core 1.6.0                    │
│  langgraph 1.2.11 / langgraph-prebuilt 1.1.0                │
│  各 provider 适配器 + checkpoint 存储                        │
└─────────────────────────────────────────────────────────────┘
```

另外 `octop-memory` 独立依赖 langgraph 的 checkpoint 存储层。

---

## 2. Octop 自身的使用

### 2.1 使用矩阵（27 个文件）

| LangChain / LangGraph 子模块 | 引用文件数 | 用途 |
|------------------------------|:---:|------|
| `langchain_core.messages` | 19 | 消息模型：`HumanMessage` / `AIMessage` / `SystemMessage` / `messages_from_dict` / `message_to_dict` |
| `langgraph.config` | 8 | 运行时上下文：`get_config()` 取 thread / 用户 / agent 信息 |
| `langchain.agents.middleware` | 8 | **自研中间件基类** `AgentMiddleware` |
| `langchain_core.tools` | 5 | `StructuredTool` 工具定义 |
| `langgraph.types` | 4 | `Command`（图内状态指令） |
| `langgraph.prebuilt.tool_node` | 4 | `ToolCallRequest`（工具调用请求对象） |
| `langgraph.checkpoint.sqlite` | 1 | `SqliteSaver`，读取历史 checkpoint |
| `langchain_openai` | 1 | `ChatOpenAI`，provider 连通性探测 |
| `langchain_core.tools.base` | 1 | 工具基类 |
| `langchain_core.runnables` | 1 | `RunnableConfig` |

### 2.2 七个自研中间件

全部位于 `src/octop/infra/agents/middleware/`，**全部继承 `langchain.agents.middleware.AgentMiddleware`**：

| 中间件 | 职责 |
|--------|------|
| `octop_ui_offload.py` | 把大的 UI 载荷（图片/音频等）卸载到工作区，避免塞进上下文 |
| `thread_artifacts.py` | 从工具调用中收集会话产物路径 |
| `token_quota.py` | token 用量配额校验与记账 |
| `reasoning.py` | 推理内容（thinking）的处理 |
| `workspace_image.py` | 工作区图片引用（`workspace://…`）处理 |
| `browser_profile.py` | 浏览器 profile 相关处理 |
| `binary_read_guard.py` | 阻止直接读取二进制文件 |

> 这是 Octop 对 LangChain 生态**侵入最深**的地方——用官方中间件机制实现平台级横切逻辑（配额、产物、UI 优化），而不是改 harness 内部。

### 2.3 其它典型场景

| 场景 | 实现方式 | 位置 |
|------|---------|------|
| 历史读取 / 序列化 | 从 checkpoint 读 LangGraph 消息并投影成 dashboard 结构 | `api/routers/chat/serialize.py:14-15,324,927` |
| 会话分叉 | 复制 checkpoint 消息到新 thread | `agents/threads/fork.py:195` |
| 团队协作 | 用 `HumanMessage`/`AIMessage` 构造成员间消息 | `agents/teams/team_manager.py:21,1724` |
| 主动关怀 | 绕过 ReAct 循环，直接一次性 LLM 调用 | `infra/proactive/service.py:3,20,87` |
| cron 内置工具 | `StructuredTool` + `get_config()` 取当前 agent | `infra/cron/tools.py:1,8-9` |
| 外部 MCP 工具包装 | 包装成 `StructuredTool` 供 LangGraph `ToolNode` 接受 | `infra/connectors/mcp_tool_cache.py:10,41-44` |
| Provider 探测 | `ChatOpenAI` 试连 | `agents/providers/probe.py:57` |
| 运行限制映射 | `max_iters` → LangGraph `recursion_limit`；模型绑定参数 | `agents/settings/runtime_limits.py:5,48,91` |

---

## 3. octop-harness 的使用

### 3.1 基于 deepagents

这是容易漏看的一层。harness 里有 **28 个文件** import `deepagents*`：

```
from deepagents.backends import CompositeBackend
from deepagents.backends import FilesystemBackend, LocalShellBackend
from deepagents.backends import StateBackend
from deepagents.backends import StoreBackend
from deepagents.backends.protocol import BackendProtocol
from deepagents_backends import PostgresBackend, PostgresConfig
```

这解释了 Octop 侧的若干设计：

- `BackendWorkspace`（AGENTS.md 要求所有工作区 I/O 走它）来自 harness，而 harness 的 backend 体系来自 `deepagents.backends`
- `resolver.py:18-19` 提到 "deepagents conversation history"
- `resolver.py:205-206` 提到 "deepagents `FilesystemMiddleware` rejects filesystem `permissions`"
- `resolver.py:34-65` 的 `windows_neutralize_host_root` 是为绕开 deepagents 的 virtual-path 校验

### 3.2 harness 使用的模块

| 子模块 | 引用文件数 |
|--------|:---:|
| `langchain_core.messages` | 29 |
| `langchain.agents.middleware` | 26 |
| `langchain_core.tools` | 21 |
| `langgraph.config` | 10 |
| `langgraph.types` | 6 |
| `langgraph.prebuilt.tool_node` | 5 |
| `langchain_core.tools.base` | 3 |
| `langchain_core.language_models` | 2 |
| `langgraph.checkpoint.sqlite` | 1 |
| `langchain.tools` / `langchain_openai` / `langchain_mcp_adapters.client` | 各 1 |
| `langchain_tavily` / `langchain_community.utilities` / `langchain_community.tools` | 各 1 |

### 3.3 harness 的模块划分

```
octop_harness/
├── agent.py            # HarnessAgent（Agent 门面）
├── manager.py          # HarnessAgentManager（生命周期）
├── compaction.py       # 上下文压缩
├── backends/           # 基于 deepagents.backends 的工作区后端
├── middleware/         # 中间件实现
├── llm/                # 模型接入
├── memory/             # 记忆接线
├── mcp.py              # MCP 集成
├── skills/             # 技能加载
├── subagents/          # 子代理
├── teams/              # 团队协作
├── protocols/          # 协议定义
├── providers/          # provider 抽象
├── security/           # 安全护栏
├── observability/      # 观测
├── slash/              # 斜杠命令
├── builtin/            # 内置技能
└── cli/                # harness 自带 CLI
```

> 注意 `create_agent` 是 **harness 自己的方法**（`manager.py:238`），不是 LangChain 的 API。harness 内部使用 LangGraph 的图与工具节点（`CompiledStateGraph`、`langgraph.prebuilt.tool_node.ToolNode`）。

---

## 4. octop-memory

`octop_memory` 独立依赖 LangGraph 的 checkpoint 存储层：

```
octop_memory/
├── adapters/      # 适配层
├── application/   # 应用服务（含 checkpoint 维护）
├── core.py        # 核心 API
├── domain/        # 领域模型
├── operations/    # 操作
├── pipeline/      # 抽取管线
├── ports/         # 端口定义
├── service.py     # 服务门面
├── storage/       # 存储后端（sqlite / postgres）
└── types.py
```

Octop 侧通过 `CompactSqliteSaver`（`octop_memory.storage.backends.sqlite_checkpoint`）存取 checkpoint（`infra/agents/memory/slim.py:64`），这也是**短期记忆与长期记忆同库**的原因（见 [`存储与记忆机制.md`](./存储与记忆机制.md) §7 P6）。

---

## 5. 依赖清单

### 5.1 `pyproject.toml` 显式声明（只有两个）

```toml
"langchain-core>=1.4.8",
"langgraph-checkpoint-postgres>=2.0",
```

### 5.2 `.venv` 实际安装的 lang\* 包

| 类别 | 包与版本 |
|------|---------|
| 核心 | `langchain 1.3.18`、`langchain-core 1.6.0`、`langgraph 1.2.11`、`langchain-classic 1.0.8` |
| Checkpoint | `langgraph-checkpoint 4.1.1`、`langgraph-checkpoint-sqlite 3.1.0`、`langgraph-checkpoint-postgres 3.1.0` |
| 预构建 | `langgraph-prebuilt 1.1.0` |
| Provider 适配 | `langchain-openai 1.3.3`、`langchain-anthropic 1.7.0`、`langchain-aws 1.1.0`、`langchain-google-genai 4.3.6` |
| MCP | `langchain-mcp-adapters 0.3.0` |
| 其它 | `langchain-community 0.4.2`、`langchain-text-splitters 1.1.2`、`langchain-tavily 0.2.18`、`langchain-protocol 0.0.18` |
| 观测 | `langfuse 4.14.0`、`langsmith 0.11.2`、`langgraph-sdk 0.4.2` |
| Deep Agents | `deepagents 0.7.9`、`deepagents-backends 0.2.0` |

### 5.3 ⚠️ 隐式依赖问题

**Octop 代码直接 import 了 `langchain`（主包）与 `langgraph`（主包），但 `pyproject.toml` 里没有声明这两个包。**

它们是通过 `octop-harness[all]` **间接**进入环境的：

| 实际被 Octop 直接 import 的模块 | 是否在 pyproject 声明 |
|--------------------------------|:---:|
| `langchain_core.*` | ✅ 已声明 |
| `langgraph.checkpoint.postgres` | ✅ 已声明（作为 `langgraph-checkpoint-postgres`） |
| **`langchain.agents.middleware`** | ❌ 未声明 |
| **`langgraph.config`** | ❌ 未声明 |
| **`langgraph.types`** | ❌ 未声明 |
| **`langgraph.prebuilt.tool_node`** | ❌ 未声明 |
| **`langgraph.checkpoint.sqlite`** | ❌ 未声明 |
| **`langchain_openai`** | ❌ 未声明 |

**风险**：若 harness 某天收窄 `[all]` extra 或调整依赖树，Octop 会在运行时 `ImportError`，而依赖解析阶段不会报错（因为没人声明它需要）。

**建议**：把实际直接使用的包提到 `dependencies`，与 `langchain-core` 并列。至少应显式声明 `langchain`、`langgraph`、`langgraph-checkpoint-sqlite`、`langchain-openai`。

---

## 6. 版本矩阵

| 包 | 版本 | 声明方 |
|----|------|--------|
| `langchain` | 1.3.18 | 间接（harness） |
| `langchain-core` | 1.6.0 | **Octop 显式**（`>=1.4.8`） |
| `langgraph` | 1.2.11 | 间接（harness） |
| `langgraph-prebuilt` | 1.1.0 | 间接（harness） |
| `langgraph-checkpoint` | 4.1.1 | 间接（harness） |
| `langgraph-checkpoint-sqlite` | 3.1.0 | 间接（harness） |
| `langgraph-checkpoint-postgres` | 3.1.0 | **Octop 显式**（`>=2.0`） |
| `deepagents` | 0.7.9 | 间接（harness） |
| `deepagents-backends` | 0.2.0 | 间接（harness） |

> LangChain 1.x 是**大版本跃迁**（对应旧 `langchain 0.x` 的 `langchain-classic 1.0.8` 仍共存）。升级时需同时验证 Octop 自研中间件与 harness 两侧。

---

## 7. 影响与注意事项

### 7.1 升级 LangChain 生态的风险面

| 改动 | 影响 |
|------|------|
| `langchain.agents.middleware.AgentMiddleware` 签名变化 | **直接影响 Octop 的 7 个中间件**（最脆弱的一处） |
| `langchain_core.messages` 结构变化 | 影响历史序列化、投影、团队消息（19 个文件） |
| `langgraph.config.get_config()` 行为变化 | 影响 thread/user 上下文解析（8 个文件） |
| `langgraph.prebuilt.tool_node.ToolCallRequest` 变化 | 影响 `octop_ui_offload`、`thread_artifacts` |
| checkpoint 格式变化 | 影响历史读取与记忆（需与 `octop-memory` 同步升级） |
| `deepagents` 版本变化 | 影响工作区后端体系（`BackendWorkspace`） |

**结论**：LangChain 生态升级不是单纯"升个依赖"，而是需要 Octop + octop-harness + octop-memory **三者协同**。

### 7.2 内网离线打包

这些包**全部由 wheel 携带**，内网无需额外准备——但离线包体积中它们占相当比例。相关清单见 [`内网可用性审计.md`](./内网可用性审计.md) §2.1。

需要注意的例外：`langgraph-checkpoint-postgres` 虽然是 Octop 显式依赖，但只有切换到 PostgreSQL 时才会真正加载和使用（见 [`切换PostgreSQL指引.md`](./切换PostgreSQL指引.md)）。

### 7.3 为什么 agent 循环不写在 Octop 里

按 `AGENTS.md` 的模块边界，`infra/` 是业务编排层，agent 运行时属于 harness 的职责。这个分工带来的好处：

- LangGraph 的版本升级与 API 变化被隔离在 harness 内
- Octop 只依赖**稳定的抽象**（`HarnessAgent`、`BackendWorkspace`、中间件机制）
- 代价是 Octop 仍需直接 import 一批 LangChain 类型（消息、工具、中间件基类），形成 §5.3 的隐式依赖

---

## 附录 A. Octop 直接引用清单（按模块）

| 文件 | 引用内容 |
|------|---------|
| `api/routers/chat/serialize.py` | `messages_from_dict`、`RunnableConfig`、`SqliteSaver` |
| `api/routers/chat/routes.py` | `HumanMessage`、`SystemMessage` |
| `api/routers/chat/history.py` | `messages_from_dict` |
| `api/routers/connectors.py` | MCP 适配器形状（注释） |
| `infra/connectors/mcp_tool_cache.py` | `StructuredTool` |
| `infra/connectors/gateway/langchain.py` | 工具工厂、`StructuredTool` |
| `infra/connectors/custom_mcp.py` | MCP 适配器字段处理 |
| `infra/proactive/service.py` | `HumanMessage`、`SystemMessage` |
| `infra/utils/llm_text.py` | 一次性 LLM 调用辅助 |
| `infra/cron/tools.py` | `StructuredTool`、`get_config` |
| `infra/cron/delivery.py` | `AIMessage`、`HumanMessage` |
| `infra/agents/settings/runtime_limits.py` | `recursion_limit`、model bind kwargs |
| `infra/agents/teams/team_manager.py` | `AIMessage`、`HumanMessage`、`SystemMessage` |
| `infra/agents/experts/manifest_generator.py` | `HumanMessage`、`SystemMessage` |
| `infra/agents/providers/probe.py` | `ChatOpenAI` |
| `infra/agents/threads/context_breakdown.py` | LangChain token 计数归一化 |
| `infra/agents/threads/fork.py` | `message_to_dict`、`messages_from_dict` |
| `infra/agents/middleware/octop_ui_offload.py` | `AgentMiddleware`、`ToolMessage`、`ToolCallRequest`、`Command` |
| `infra/agents/middleware/token_quota.py` | `AgentMiddleware`、`get_config` |
| `infra/agents/middleware/reasoning.py` | `AgentMiddleware`、`ModelRequest`、`ModelResponse`、`get_config` |
| `infra/agents/middleware/thread_artifacts.py` | `AgentMiddleware`、`ToolMessage`、`get_config`、`ToolCallRequest`、`Command` |
| `infra/agents/middleware/workspace_image.py` | `AgentMiddleware` |
| `infra/agents/middleware/browser_profile.py` | `AgentMiddleware` |
| `infra/agents/middleware/binary_read_guard.py` | `AgentMiddleware` |
| `infra/agents/manager.py` | checkpoint 清理相关（注释） |
| `api/routers/chat/models.py` | HITL 决策类型（注释） |

## 附录 B. 证据索引

| 主题 | 位置 / 命令 |
|------|-----------|
| 显式依赖 | `pyproject.toml:17,39` |
| Octop 引用文件数 | `grep -rlE "^\s*(from\|import)\s+(langchain\|langgraph)" src/octop --include=*.py` → 27 |
| 中间件基类 | `src/octop/infra/agents/middleware/*.py`（7 个文件均有 `AgentMiddleware`） |
| harness 引用数 | `.venv/.../octop_harness/` → 54 个文件 |
| deepagents 引用数 | 同上 → 28 个文件 |
| harness 的 `create_agent` | `.venv/.../octop_harness/manager.py:238` |
| checkpoint 存取 | `src/octop/infra/agents/memory/slim.py:63-64` |
| 运行时限制映射 | `src/octop/infra/agents/settings/runtime_limits.py:5,48,91` |
| deepagents 后端体系 | `.venv/.../octop_harness/backends/`、`deepagents.backends` |
| 安装版本 | `ls .venv/lib/python3.12/site-packages/ \| grep -i '^lang'` |
