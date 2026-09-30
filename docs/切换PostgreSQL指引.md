# 切换控制面到 PostgreSQL

面向内网环境的 SQLite → PostgreSQL 迁移指引，包含完整步骤与**影响面清单**。

> **基线**：`1.0.2b4`（`origin/main` = `232030f4`）
> 配套文档：
> - [`docs/adr/002-database-backends.md`](./adr/002-database-backends.md) —— 双后端设计决策（**先读**）
> - [`docs/configuration.md`](./configuration.md) —— 数据库配置项与环境变量
> - [`docs/存储与记忆机制.md`](./存储与记忆机制.md) —— 存储分层与隔离粒度
> - [`docs/内网离线部署.md`](./内网离线部署.md) —— 离线包安装

---

## 0. 先读这一节

### 0.1 最重要的一句话

> **没有 SQLite → PostgreSQL 的数据迁移工具。**

ADR 002 明确写了 `Greenfield only — no SQLite→PG data migrator.`（`docs/adr/002-database-backends.md:45`）。
这意味着：**切换后控制面数据不会自动带过去**。你必须先决定"旧数据怎么办"。

### 0.2 决策表

| 你的情况 | 建议路径 | 章节 |
|---------|---------|------|
| 全新部署 / 可以放弃现有数据 | **方案 A：全新切换** | §3.1 |
| 必须保留用户、agent、会话、渠道、cron 配置 | **方案 B：手工迁移**（需写脚本，工作量大） | §3.2 + 附录 A |
| 已经在生产用了一段时间 | 先做**方案 B**，或接受"用 API 重建配置 + 保留 workspace 文件" | §3.2 |
| 只是想评估 | 在测试环境试，不要动生产 | — |

### 0.3 内网可行性速判

| 项 | 内网是否可行 |
|----|------------|
| 装 PostgreSQL 16（rpm/deb 离线包或摆渡 Docker 镜像） | ✅ |
| 依赖（`psycopg[binary]`、`langgraph-checkpoint-postgres`） | ✅ **已包含在 wheel 里**，无需额外下载 |
| pgvector 扩展 | ⚠️ **不需要**（见 §2.2） |
| `pg_dump` 二进制（备份要用） | ⚠️ **需要额外准备**，见 §2.3 |
| 迁移现有数据 | ❌ 无官方工具 |

---

## 1. 影响面总览

这是本文最重要的一张表——**切换后哪些会变、哪些不变**。

| 对象 | 切换前（SQLite） | 切换后（PostgreSQL） | 影响 |
|------|-----------------|---------------------|------|
| **控制面数据库** | `~/.octop/octop.db` | PG 实例（库 `octop`） | 🔴 数据不迁移 |
| **Agent 记忆** | `agents/<id>/.octop/memory.sqlite` | **跟随控制面 DSN**（每 agent 独立 namespace） | 🔴 不迁移；见 §1.2 |
| **短期记忆（checkpoint）** | 同上文件 | **跟随记忆后端**（PG 存储） | 🔴 不迁移 |
| **Agent 工作区文件** | `agents/<id>/` | `agents/<id>/` | 🟢 **不变**（与数据库无关） |
| **用户产出文件**（`outbound/`） | 同上 | 同上 | 🟢 不变 |
| **人格文件**（`SOUL.md` 等） | 同上 | 同上 | 🟢 不变 |
| **知识库向量索引** | `knowledge/<kb>/index.sqlite` | **仍是 SQLite sidecar** | 🟢 不变 |
| **history_v2 归档** | `~/.octop/history_v2.sqlite` | ❌ **不可用**（PG 下拒绝启动该功能） | 🔴 见 §1.3 |
| **系统备份** | 打包 `octop.db` 文件 | 调 `pg_dump -Fc` | 🟡 格式变化，见 §1.4 |
| **记忆便携包**（pack/adopt） | 可用 | ❌ **被明确拒绝** | 🔴 见 §1.5 |
| **CLI 离线命令** | 直连 SQLite 文件 | 连 PG（需网络可达） | 🟡 见 §1.6 |
| **connection pool** | 单连接 + RLock | `min 1 / max 8`（硬编码） | 🟡 见 §4.4 |

### 1.1 三层存储的关系（不要混淆）

```text
Layer 1 — Octop 控制面       SQLite 文件  OR  PostgreSQL（改这里）
Layer 2 — Harness checkpoint  跟随 Layer 3 的选择
Layer 3 — Agent 记忆（octop-memory）
          SQLite 控制面 → {workspace}/.octop/memory.sqlite
          PG 控制面     → 默认复用同一 DSN
Layer 4 — 工作区内容文件（SOUL / skills / inbound / outbound）
          始终是文件，与数据库无关
```

（`docs/adr/002-database-backends.md:16-37`）

### 1.2 记忆后端会跟着变

```187:192:docs/configuration.md
- Control plane SQLite → agent memory stays `{workspace}/memory.sqlite`
  (or `{workspace}/.octop/memory.sqlite` for new agents).
- Control plane PostgreSQL → agent memory **defaults to the same DSN**
  (octop-memory per-agent PG schema `agent_<id>`). Runtime also needs
  ``langgraph-checkpoint-postgres`` (pulled in via
  ``octop-memory[langgraph-postgres]``) so LangGraph checkpoints work.
```

**这是最容易忽略的一点**：只是改了控制面数据库，**记忆和 checkpoint 会一起搬到 PG**。原 `memory.sqlite` 里的长期记忆不会自动导入。

想保留文件记忆，必须在**每个 agent** 的配置里显式声明：

```json
"memory": { "backend": { "type": "sqlite" } }
```

> ⚠️ **关于 PG 记忆的隔离方式，代码里有两种表述不一致**，实测前请注意：
> - `docs/configuration.md:190` 与 ADR 002:31 描述为「per-agent PG schema `agent_<id>`」
> - `api/routers/memory_portable.py:54` 描述为「所有 agent 共享 `octop_memory` schema 的固定表，用 `namespace` 列隔离」
>
> 传入 octop-memory 的 `namespace` 确实是 `agent_<agent_id>`（`infra/agents/memory/backend.py:76`）。实际建表方式以 octop-memory 内部实现为准，**建议切换后在 PG 里核对 schema 名称**。

### 1.3 history_v2 归档在 PG 下不可用

```38:38:docs/versioned-history.md
适用范围：SQLite 主库、单个 Octop 服务进程。PostgreSQL 开启此功能会明确拒绝启动。
```

如果你当前**已经开启了** `history_v2_enabled`，切到 PG 会导致**服务启动失败**。切换前必须：

1. 把 `history_v2_enabled` 设为 `false`
2. 注意：已写入 `history_v2.sqlite` 的 v2 内容**无法退回到不认识的旧程序**（`versioned-history.md:92`），该文件需要一并保留存档

而且 `rebind_control_plane` 也会拒绝带 v2 归档的实例热切换（`infra/db/rebind.py:117-122`）。

### 1.4 备份格式改变，跨引擎恢复被拒绝

| 控制面 | 备份内容 | `database_dump_format` |
|--------|---------|----------------------|
| SQLite | 打包 `octop.db` 文件 | `sqlite_file` |
| PostgreSQL | `pg_dump -Fc` 自定义格式 | `pg_custom` |

（`infra/backup/system_archive.py:212-219`）

恢复时会校验引擎一致：

```467:471:src/octop/infra/backup/system_archive.py
        archive_driver = manifest.database_driver or "sqlite"
        ...
                f"backup database_driver={archive_driver!r} does not match "
```

**后果**：
- 切换前的 SQLite 备份**不能恢复到 PG 实例**
- 切换后的 PG 备份**不能恢复到 SQLite 实例**
- 所以"备份"在切换场景下主要用于**回滚到原 SQLite**，不是数据搬运手段

### 1.5 记忆便携包在 PG 下被拒绝

`pack` / `adopt`（记忆的跨主机搬运）是纯 SQLite 文件机制。PG 下会直接报错，且代码注释特别警告：

```54:59:src/octop/api/routers/memory_portable.py
    PostgreSQL: all agents share fixed tables in the ``octop_memory`` schema,
    isolated by a ``namespace`` column. There is no per-agent file to pack, and
    ``pg_dump`` of the schema must NOT be suggested as a substitute — it would
    export every agent's memory, not just this one. The supported way to give
    another host (e.g. OpenClaw) access is to point it at the same DSN and
    namespace, where the memory is simply shared rather than migrated.
```

**不要**用 `pg_dump` 来做单 agent 的记忆迁移——它会导出**所有 agent** 的记忆。

### 1.6 CLI 行为变化

`cli/support/db.py:21-32` 的 `open_cli_services` 走的是通用 `open_database(config)`，所以：

- 配置指向 PG 后，**离线 CLI 命令会连 PG**（需要网络可达）
- `user` / `agent list` / `cron list` 等命令依赖 PG 可用性
- 原本"纯本地文件、无网络依赖"的特性消失

---

## 2. 前置条件（内网）

### 2.1 PostgreSQL 实例

| 项 | 要求 |
|----|------|
| 版本 | **16**（与项目 `docker/docker-compose.postgres.yml` 的 `pgvector/pgvector:pg16` 一致）；`psycopg3` 需要 PG ≥ 12 |
| 编码 | UTF-8 |
| 时区 | 建议与 `OCTOP_DEFAULT_TIMEZONE` 一致（默认 `Asia/Shanghai`） |
| 连接数 | 单实例连接池 `max 8`，另加记忆连接；建议 `max_connections ≥ 50` |

清单：

- [ ] PG 服务已启动并开机自启
- [ ] 建库 `octop`（owner 为 `octop`）
- [ ] 建用户 `octop` 并设置强密码
- [ ] 从 Octop 主机 `psql` 可连通
- [ ] `pg_hba.conf` 允许来自 Octop 主机的连接（`scram-sha-256`）
- [ ] 防火墙放行 5432

### 2.2 关于 pgvector：**不需要**

```55:59:docs/adr/002-database-backends.md
| Control-plane tables / indexes | Octop migrate | `migrations/NNN_*.sql` and `NNN_*.pg.sql` |
| Connection / session settings | Pool connect | SQLite: `PRAGMA` in `SqlitePool`; PG: defaults (FK on) — **not** in migrations |
| Instance extensions (`vector`, …) | Ops / docker | `docker/postgres/init-vector.sql` via `initdb.d`, or DBA on managed PG |
| Agent memory DDL | octop-memory | Runtime `_init_schema` per `agent_*` schema |

**Hard rule:** Octop control-plane `*.pg.sql` must **not** run `CREATE EXTENSION`. Many managed Postgres roles cannot create extensions; the control plane also does not need `vector` (plain types only). octop-memory today uses built-in `tsvector`, not pgvector. Keep `CREATE EXTENSION vector` in docker/ops for optional future embedding use.
```

结论：

- 控制面**不需要** vector 扩展（只用普通类型）
- octop-memory 用的是内置 `tsvector`，**不是** pgvector
- 知识库的向量索引是独立的 SQLite sidecar（`knowledge/<kb>/index.sqlite`），与控制面无关

所以内网可以**不装 pgvector**，省掉一次源码编译（pgvector 需 `make` + `pg_config`）。只有将来要用向量能力时再启用。

### 2.3 `pg_dump` / `pg_restore` 二进制（备份与恢复必需）

PG 下备份与恢复都会调用外部工具，**缺任何一个都会直接报错**：

```23:31:src/octop/infra/backup/pg_dump.py
def dump_postgres(
    conninfo: str,
    dest: Path,
    *,
    exclude_table_data: Sequence[str] = (),
) -> None:
    pg_dump = _require_tool("pg_dump")
    dest.parent.mkdir(parents=True, exist_ok=True)
    cmd = [pg_dump, "-Fc", "-f", str(dest), "--dbname", conninfo]
```

```47:48:src/octop/infra/backup/pg_dump.py
def restore_postgres(conninfo: str, dump_file: Path) -> None:
    pg_restore = _require_tool("pg_restore")
```

清单：

- [ ] `pg_dump` 在 **Octop 服务进程**的 `PATH` 中（注意 systemd 服务的 PATH，见下）
- [ ] `pg_restore` 同样可用（**恢复时才用得上，容易漏装**）
- [ ] 版本不低于服务端主版本（`pg_dump` 兼容规则）
- [ ] Octop 运行用户对 dump 输出目录有写权限
- [ ] 备份归档内数据库文件名固定为 `db/octop.dump`（`_PG_DUMP_ARC`）

> ⚠️ systemd 服务的 PATH 默认不含 `/usr/pgsql-16/bin`。若 `pg_dump` 装在非标准路径，需按 [`docs/内网可用性审计.md`](./内网可用性审计.md) §5.1 的方式把该目录加进 `PATH`（写入 `~/.octop/env` 或 systemd drop-in）。

> 验证：`~/.octop/bin/octop backup create -o /tmp/probe.tar.gz` 能成功，即说明 `pg_dump` 可用。

离线环境安装（麒麟 / RHEL 系）：

```bash
# 离线 rpm 摆渡后本地安装
sudo rpm -Uvh postgresql16-*.rpm postgresql16-libs-*.rpm postgresql16-server-*.rpm
# 或使用系统离线源
sudo yum install -y postgresql-server postgresql-contrib

# 初始化与启动（RHEL 系）
sudo /usr/pgsql-16/bin/postgresql-16-setup initdb
sudo systemctl enable --now postgresql-16

# 或 Docker（摆渡镜像）
docker load -i pg16.tar
docker run -d --name octop-pg -p 5432:5432 \
  -e POSTGRES_USER=octop -e POSTGRES_PASSWORD='<强密码>' -e POSTGRES_DB=octop \
  -v octop_pgdata:/var/lib/postgresql/data postgres:16
```

建库与账号：

```bash
sudo -u postgres psql <<'SQL'
CREATE USER octop WITH PASSWORD '<强密码>';
CREATE DATABASE octop OWNER octop ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE octop TO octop;
SQL

# 验证连通（在 Octop 主机上）
PGPASSWORD='<强密码>' psql -h <PG_HOST> -U octop -d octop -c 'SELECT version();'
```

### 2.4 Python 依赖：无需额外准备

`pyproject.toml` 已把 PG 支持作为**核心依赖**（不是可选）：

```
"psycopg[binary]>=3.2",
"langgraph-checkpoint-postgres>=2.0",
```

所以只要装过 Octop（含离线包），依赖就齐了。可用以下命令确认：

```bash
~/.octop/venv/bin/python -c "import psycopg, psycopg_pool, langgraph.checkpoint.postgres; print('PG 依赖 OK')"
```

---

## 3. 切换步骤

### 3.0 通用前置动作（两种方案都要做）

```bash
# 1. 停服务，避免切换期间写入
sudo ~/.octop/bin/octop service stop

# 2. 完整备份（含工作区），并另存整个数据目录
~/.octop/bin/octop backup create -o /backup/octop-before-pg.tar.gz
sudo tar -czf /backup/octop-home-before-pg.tar.gz -C ~ .octop

# 3. 记录当前状态（用于回滚核对）
~/.octop/bin/octop --version
sqlite3 ~/.octop/octop.db "SELECT COUNT(*) FROM users; SELECT COUNT(*) FROM agents;"

# 4. 关闭 history_v2（如已开启，否则切 PG 后服务起不来）
#    编辑 ~/.octop/config.json，令 "history_v2_enabled": false
#    并保留 ~/.octop/history_v2.sqlite 与 history_v2.required 作为存档
```

### 3.1 方案 A：全新切换（推荐）

适用于可以放弃现有控制面数据的场景。切完是一个**全新的空实例**，workspace 文件仍在磁盘上（但会成为孤儿目录，见 §3.3）。

**步骤 1：选择配置方式**（三选一，环境变量优先）

方式 1 —— 写入 `~/.octop/env`（推荐，与 §内网可用性审计 的 PATH 修复共用同一文件）：

```bash
cat >> ~/.octop/env <<'EOF'
OCTOP_DATABASE_DRIVER=postgresql
OCTOP_DATABASE_HOST=<PG_HOST>
OCTOP_DATABASE_PORT=5432
OCTOP_DATABASE_NAME=octop
OCTOP_DATABASE_USER=octop
OCTOP_DATABASE_PASSWORD=<强密码>
EOF
chmod 600 ~/.octop/env
```

方式 2 —— 单条 DSN（更简洁，优先级最高）：

```bash
echo 'OCTOP_DATABASE_URL=postgresql://octop:<密码>@<PG_HOST>:5432/octop' >> ~/.octop/env
```

方式 3 —— 写 `config.json` 的 `database` 段：

```json
{
  "database": {
    "driver": "postgresql",
    "host": "<PG_HOST>",
    "port": 5432,
    "database": "octop",
    "user": "octop",
    "password": null,
    "url": null
  }
}
```

> 生产环境建议 **不要把密码写进 `config.json`**（`configuration.md:105-110`），用环境变量或 DSN。
> ⚠️ 编辑 `config.json` 务必保证 JSON 合法——历史上有过一次因尾部逗号导致 `database` 段被整段清空、PG 实例被静默切回 SQLite 的事故（`cli/commands/run.py:112-115`）。

**步骤 2：初始化并启动**

```bash
# 初始化（会在 PG 上建表；此时还没有任何用户）
~/.octop/bin/octop init --yes \
  --admin-username admin \
  --admin-password '<强密码>'

# 启动
sudo ~/.octop/bin/octop service start
```

**步骤 3：验证**

```bash
# 控制面表已建在 PG 上（应为 30+ 张表）
PGPASSWORD='<强密码>' psql -h <PG_HOST> -U octop -d octop -c '\dt' | head -20

curl -s http://127.0.0.1:8088/api/health
curl -s http://127.0.0.1:8088/api/setup/status
```

**步骤 4：重建业务配置**

控制面数据没带过来，需要重建：

- [ ] 用户（`octop user create` 或控制台）
- [ ] 模型 Provider 与 API Key
- [ ] Agent / 专家（重新创建会生成**新的 agent_id**）
- [ ] IM 渠道、cron 任务、连接器、知识库

> 参考 `agent list` / `provider list` 的旧输出来恢复配置。**旧输出建议在切换前先导出留档**。

### 3.2 方案 B：保留现有数据（手工迁移）

**官方没有工具**，需要自己写脚本。工作量取决于数据量，核心难点：

| 难点 | 说明 |
|------|------|
| 表结构双份 | 迁移是 `NNN_*.sql`（SQLite）与 `NNN_*.pg.sql`（PG）两套，字段类型/默认值可能有差异 |
| 主键与自增 | SQLite `INTEGER PRIMARY KEY AUTOINCREMENT` vs PG `GENERATED BY DEFAULT AS IDENTITY`，需要 `setval` 校正序列 |
| 布尔与时间 | SQLite 用 0/1 与整数时间戳，PG 同（项目设计如此），但需逐表确认 |
| 外键顺序 | 必须按依赖顺序插入，或先禁用外键 |
| `config_json` 字段 | 迁移后 `system_files_path` / `workspace_dir` 需与新实例匹配 |
| 记忆与 checkpoint | **不走控制面迁移**，需要单独处理（见 §1.2、§1.5） |

**推荐替代路线**（工作量小得多，风险也低）：

1. 先做**方案 A** 把 PG 实例跑起来
2. 用 API / CLI **重建配置类数据**（用户、provider、agent、渠道、cron）——这些量通常不大
3. **workspace 文件不做迁移**，直接保留在磁盘；如需继续使用旧会话产物，从 `agents/<旧 agent_id>/outbound/` 里手工取文件

> 会话历史（`thread_messages` / `trajectory_events`）在方案 A 下会丢失。如果需要保留历史阅读能力，建议**保留 SQLite 实例作为只读归档**（切换前用 `octop backup` 存好），而不是强行迁移。

### 3.3 ⚠️ 切换后旧 workspace 会变成孤儿

这是方案的**必然后果**，必须提前知晓：

1. 切换后是空控制面 → `agents` 表没有记录
2. 但 `~/.octop/agents/<旧 agent_id>/` 目录**仍在磁盘上**
3. 新创建的 agent 会有**新的 agent_id**，无法复用旧目录名
4. 结果：旧目录成为无入口的孤儿（与 [`存储与记忆机制.md`](./存储与记忆机制.md) §7 P1 同类问题）

**处理建议**：

```bash
# 切换前先记录旧 agent 清单与工作区大小
~/.octop/bin/octop agent list > /backup/agents-before-pg.txt
du -sh ~/.octop/agents/*/ >> /backup/agents-before-pg.txt

# 切换后确认哪些目录已成孤儿（数据库中查不到）
python3 - <<'EOF'
import sqlite3, pathlib
print("旧 workspace 目录（切换后需人工判断去留）：")
for d in sorted((pathlib.Path.home()/".octop"/"agents").iterdir()):
    if d.is_dir():
        print("  ", d.name)
EOF

# 确认不再需要后，手工清理（谨慎！会永久删除会话产物与记忆）
# rm -rf ~/.octop/agents/<旧 agent_id>/
```

> 建议先整体打包留存，观察一段时间再删。

### 3.4 回滚到 SQLite

```bash
# 1. 停服务
sudo ~/.octop/bin/octop service stop

# 2. 恢复配置：移除 OCTOP_DATABASE_* 或把 driver 改回 sqlite
#    从 ~/.octop/env 中删除 PG 相关行，或修改 config.json 的 database 段

# 3. 从备份恢复
~/.octop/bin/octop backup restore /backup/octop-before-pg.tar.gz --yes

# 4. 启动
sudo ~/.octop/bin/octop service start
```

**回滚限制**：

- 如果用 PG 期间产生了新数据，**这些数据不会回滚到 SQLite**（同样没有反向迁移工具）
- 跨引擎恢复会被拒绝（§1.4），所以回滚必须用**切换前那份 SQLite 备份**
- 切换后如果在 PG 上开启了 history_v2，回滚前要先关掉

---

## 4. 配置参考

### 4.1 环境变量（优先级最高）

| 变量 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `OCTOP_DATABASE_URL` | string | 空 | **完整 DSN，覆盖下面所有分项字段** |
| `OCTOP_DATABASE_DRIVER` | `sqlite` \| `postgresql` | `sqlite` | 后端选择 |
| `OCTOP_DATABASE_HOST` | string | `127.0.0.1` | PG 主机 |
| `OCTOP_DATABASE_PORT` | int | `5432` | PG 端口 |
| `OCTOP_DATABASE_NAME` | string | `octop` | 库名 |
| `OCTOP_DATABASE_USER` | string | `octop` | 用户 |
| `OCTOP_DATABASE_PASSWORD` | string | 空 | 密码（**生产优先用环境变量**） |

（`docs/configuration.md:157-164`）

判定逻辑：`database_env_configured()` 在**任一项** `OCTOP_DATABASE_*` 被设置时返回 True，`OctopServer.start()` 据此在启动时选后端（`configuration.md:174-176`）。

### 4.2 DSN 格式

```
postgresql://<user>:<password>@<host>:<port>/<database>
```

URL 中若包含特殊字符，密码需要 URL 编码（`config.py:71-73` 内部用 `quote_plus`）。

### 4.3 配置优先级

```
OCTOP_DATABASE_URL  >  OCTOP_DATABASE_* 分项  >  config.json 的 database 段  >  内置默认（SQLite）
```

### 4.4 连接池（不可配置）

```151:163:src/octop/infra/db/pool.py
class PostgresPool:
    dialect: str = "postgresql"

    def __init__(self, conninfo: str, *, min_size: int = 1, max_size: int = 8) -> None:
        from psycopg_pool import ConnectionPool

        self._pool = ConnectionPool(
            conninfo=conninfo,
            min_size=min_size,
            max_size=max_size,
            kwargs={"row_factory": _compat_row_factory},
            open=True,
        )
```

**`min_size=1` / `max_size=8` 是硬编码的，没有环境变量可调。** 规划 PG 的 `max_connections` 时要把这 8 个加上记忆后端的连接数。

### 4.5 单写者模型

ADR 002:44 明确：`Single active Octop writer; no multi-instance write promise.`

**不要**让多个 Octop 实例同时连同一个 PG 库——不支持多实例写入。

---

## 5. 切换后验证清单

- [ ] 服务能正常启动：`sudo systemctl status octop --no-pager | head -5`
- [ ] 健康检查：`curl -s http://127.0.0.1:8088/api/health` → `{"ok":true,"db":true,...}`
- [ ] 控制面表已建：`psql -c '\dt'` 有 30+ 张表
- [ ] 管理员可登录控制台
- [ ] 创建 1 个 agent 并完成一轮对话
- [ ] **记忆后端已切到 PG**（在 PG 里能查到记忆/checkpoint 表或 schema）
- [ ] **备份可用**：`octop backup create -o /tmp/t.tar.gz` 成功（验证 `pg_dump` 可用）
- [ ] CLI 可用：`octop agent list`
- [ ] `history_v2` 相关配置已关闭
- [ ] 旧 `agents/*/` 目录的去留已确认（保留或清理）

验证记忆后端：

```bash
PGPASSWORD='<强密码>' psql -h <PG_HOST> -U octop -d octop -c '\dn'          # 看 schema
PGPASSWORD='<强密码>' psql -h <PG_HOST> -U octop -d octop -c '\dt *.*' | head -40
```

如果想确认某个 agent 的记忆落在哪：

```bash
~/.octop/venv/bin/python -c "
import json,pathlib
cfg=json.loads(next(pathlib.Path.home().glob('.octop/agents/*/.octop/manifest.json')).read_text())
print(cfg)
" 2>/dev/null || echo '在控制台查看该 agent 的 memory 配置'
```

---

## 6. 限制与坑（汇总）

| # | 限制 | 后果 | 依据 |
|---|------|------|------|
| 1 | **无 SQLite→PG 迁移工具** | 数据需重建或手写脚本 | ADR 002:45 |
| 2 | **跨引擎恢复被拒绝** | 备份不能跨后端搬运数据 | `backup/system_archive.py:467-471` |
| 3 | **history_v2 仅支持 SQLite** | 已开启该功能的实例切 PG 会**启动失败** | `versioned-history.md:38` |
| 4 | **记忆便携包被拒** | PG 下无法按 agent 打包/搬运记忆 | `api/routers/memory_portable.py:47-69` |
| 5 | **`pg_dump` 不能替代记忆迁移** | 会导出所有 agent 的记忆，不是单个 | 同上注释 |
| 6 | **记忆与 checkpoint 跟随 DSN** | 只想换控制面，记忆也会一起搬 | `configuration.md:187-192` |
| 7 | **热切换条件苛刻** | 仅 `user_count == 0` 且无 history_v2 且目标库为空 | `db/rebind.py:102-129` |
| 8 | **连接池参数不可配** | `max_size=8` 写死，影响 PG 规划 | `db/pool.py:154` |
| 9 | **无多实例写入支持** | 不能水平扩展 Octop 进程 | ADR 002:44 |
| 10 | **CLI 失去纯本地特性** | 离线命令需要 PG 网络可达 | `cli/support/db.py:21-32` |
| 11 | **旧 workspace 变孤儿** | 新 agent 无法复用旧目录（agent_id 不同） | 本文 §3.3 |
| 12 | **`config.json` 损坏风险** | 编辑失误可能整段丢掉 database 配置 | `cli/commands/run.py:112-115` |

---

## 7. 数据保留对照表

切换时各类数据的命运，一表看清：

| 数据类型 | 物理位置 | 切换后 | 可迁移性 |
|---------|---------|--------|---------|
| 用户 / 角色 / 权限 | `octop.db` → PG | ❌ 不带过去 | 手工/API 重建 |
| Agent 定义 | `octop.db` → PG | ❌ | 手工/API 重建（agent_id 会变） |
| Provider / 渠道 / cron | `octop.db` → PG | ❌ | 手工/API 重建 |
| 会话历史（`thread_messages`） | `octop.db` → PG | ❌ | 难；建议留 SQLite 归档 |
| 轨迹事件 | `octop.db` → PG | ❌ | 同上 |
| 审计日志 / 用量 | `octop.db` → PG | ❌ | 可手工导出 CSV 备用 |
| 加密凭据（`secrets`） | `octop.db` → PG | ❌ | 需重新录入 API Key |
| **Agent 工作区文件** | `agents/<id>/` | ✅ **仍在** | 直接可用（但目录归属成孤儿） |
| **用户产出（PPT/Word）** | `agents/<id>/outbound/` | ✅ **仍在** | 手工取用 |
| 人格文件（SOUL.md 等） | `agents/<id>/` | ✅ 仍在 | 可复制进新 agent |
| 技能目录 | `agents/<id>/.octop/skills/` | ✅ 仍在 | 可复制 |
| **长期记忆** | `memory.sqlite` | ⚠️ 切到 PG，**旧内容不导入** | 无工具（便携包在 PG 被拒） |
| **短期记忆（checkpoint）** | 同上 | ⚠️ 同上 | 无工具 |
| 知识库索引 | `knowledge/<kb>/index.sqlite` | ✅ 仍在（仍是 SQLite） | 不变 |
| 知识库文档元数据 | `octop.db` → PG | ❌ | 需重新上传/索引 |
| history_v2 归档 | `history_v2.sqlite` | ❌ 功能不可用 | 保留文件作存档 |

---

## 附录 A. 手工迁移控制面（方案 B 参考思路）

如果你确实需要迁移控制面数据，可以参考这个骨架。**务必先在测试环境验证**。

```python
"""SQLite → PostgreSQL 控制面数据迁移（参考骨架，非官方工具）

要点：
1. 先在 PG 上跑一次 Octop 迁移，建出完整表结构
2. 按外键依赖顺序逐表搬运
3. 自增主键需搬运后 setval 校正序列
4. 遇到 schema 差异（列名/类型）需逐表调整
"""
import sqlite3
import psycopg

# 建表顺序：父表在前
TABLES_IN_ORDER = [
    "users", "user_role", "sso_providers", "user_sso_identities",
    "agents", "published_experts", "storage_backends", "secrets",
    "providers", "channels", "voice_providers", "connectors",
    "threads", "sessions", "thread_messages", "trajectory_events",
    "thread_history_projection", "cron_jobs",
    "knowledge_bases", "knowledge_documents", "skill_packages",
    "settings", "usage_log", "audit_log",
    "user_invites", "user_policies", "connector_oauth_states",
    "sso_login_states", "proactive_care_config", "care_push_records",
    # 注意：跳过 'users_new' / 'knowledge_documents_legacy' 等迁移中间表
]

sqlite = sqlite3.connect("file:$HOME/.octop/octop.db?mode=ro", uri=True)
sqlite.row_factory = sqlite3.Row
pg = psycopg.connect("postgresql://octop:<密码>@<PG_HOST>:5432/octop")

with pg.cursor() as cur:
    cur.execute("SET session_replication_role = replica")  # 关闭外键检查（需超级用户或权限）
    for table in TABLES_IN_ORDER:
        rows = sqlite.execute(f'SELECT * FROM "{table}"').fetchall()
        if not rows:
            continue
        cols = rows[0].keys()
        col_list = ", ".join(f'"{c}"' for c in cols)
        placeholders = ", ".join(["%s"] * len(cols))
        sql = f'INSERT INTO "{table}" ({col_list}) VALUES ({placeholders}) ON CONFLICT DO NOTHING'
        cur.executemany(sql, [tuple(r) for r in rows])
        print(f"{table}: {len(rows)} 行")

        # 校正自增序列（有 id 列的表）
        if "id" in cols:
            cur.execute(
                f"SELECT setval(pg_get_serial_sequence('{table}', 'id'), "
                f"COALESCE((SELECT MAX(id) FROM \"{table}\"), 1))"
            )
    cur.execute("SET session_replication_role = DEFAULT")
pg.commit()

# 迁移后必须逐表核对行数
with pg.cursor() as cur:
    for table in TABLES_IN_ORDER:
        n_old = sqlite.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
        cur.execute(f'SELECT COUNT(*) FROM "{table}"')
        n_new = cur.fetchone()[0]
        flag = "OK " if n_old == n_new else "差异"
        print(f"{flag} {table}: sqlite={n_old} pg={n_new}")
```

**注意事项**：

- 该骨架**不覆盖**：记忆与 checkpoint（走 octop-memory）、`config_json` 中的路径字段适配、加密字段的兼容性
- `SET session_replication_role` 需要相应权限；无权限时改为按依赖顺序插入
- 表结构以**实际 PG 迁移结果**为准，本清单可能与最新版本有差异（用 `\dt` 核对）
- 迁移完成后**再次执行 `PRAGMA`-侧不可用的检查**：跑一次 `octop run`，观察启动日志与 `octop backup create`

## 附录 B. 证据索引

| 主题 | 位置 |
|------|------|
| 双后端设计决策、Greenfield only | `docs/adr/002-database-backends.md:14-70` |
| 无迁移工具 / 备份格式 / 热切换 | `docs/adr/002-database-backends.md:45-48` |
| 禁止在控制面迁移中 `CREATE EXTENSION` | `docs/adr/002-database-backends.md:59` |
| 数据库配置项与环境变量 | `docs/configuration.md:75-176` |
| 记忆 vs 控制面分层 | `docs/configuration.md:183-200` |
| history_v2 仅支持 SQLite | `docs/versioned-history.md:38` |
| 数据库默认值 | `config.py:43-50` |
| 环境变量覆盖 | `config.py:416-430` |
| PG 连接池 | `infra/db/pool.py:151-176` |
| 热切换条件 | `infra/db/rebind.py:102-129` |
| 空库校验 | `infra/db/rebind.py:82-99` |
| 备份 dump 格式 | `infra/backup/system_archive.py:212-219` |
| 跨引擎恢复拒绝 | `infra/backup/system_archive.py:467-471` |
| 记忆便携在 PG 被拒 | `api/routers/memory_portable.py:47-69` |
| 记忆后端解析 | `infra/agents/memory/backend.py:13-65` |
| config.json 损坏事故 | `cli/commands/run.py:112-115` |
| CLI 离线服务 | `cli/support/db.py:21-32` |
| PG compose 与 pgvector init | `docker/docker-compose.postgres.yml`、`docker/postgres/init-vector.sql` |
