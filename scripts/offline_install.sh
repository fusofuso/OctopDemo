#!/usr/bin/env bash
# =============================================================================
# Octop 内网离线安装 —— 在【无外网的目标机】上执行
#
# 前提：已用 scripts/offline_pack.sh 生成离线包，并解压到目标机。
#
# 用法:
#   bash scripts/offline_install.sh --bundle ./octop-offline-aarch64-1.0.2b4
#
# 常用选项:
#   --bundle DIR        离线包目录（默认自动探测当前目录下的 octop-offline-*）
#   --home DIR          安装根目录（默认 ~/.octop）
#   --admin-username U  管理员用户名（默认 admin）
#   --admin-password P  管理员密码（≥8 位且含字母和数字；不填则随机生成并打印）
#   --host H            绑定地址（默认沿用 config.json 的 127.0.0.1；跨机访问填 0.0.0.0）
#   --port N            绑定端口（默认 8088）
#   --service           安装并启动 systemd 服务（需要 root）
#   --skip-init         跳过数据库与管理员初始化
#   --skip-verify       跳过离线包完整性校验（仅在确认包可信时使用）
#   -h, --help          显示帮助
#
# 说明:
#   - 本脚本完全离线：pip 使用 --no-index，不会访问任何网络。
#   - crcmod / evdev 是源码包，需要 gcc 现场编译（Python 头文件由离线解释器自带）。
# =============================================================================
set -euo pipefail

# 不让解释器把字节码缓存写回离线包：否则会就地改写包内 __pycache__/*.pyc，
# 导致下次安装时完整性校验误报失败。
export PYTHONDONTWRITEBYTECODE=1

BUNDLE_DIR=""
OCTOP_HOME="${OCTOP_HOME:-$HOME/.octop}"
BIND_HOST=""
BIND_PORT=""
ADMIN_USERNAME="${OCTOP_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${OCTOP_ADMIN_PASSWORD:-}"
INSTALL_SERVICE=0
SKIP_INIT=0
SKIP_VERIFY=0

info() { printf '\033[0;32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[install]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[install]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bundle) BUNDLE_DIR="${2:-}"; shift 2 ;;
        --home) OCTOP_HOME="${2:-}"; shift 2 ;;
        --admin-username) ADMIN_USERNAME="${2:-}"; shift 2 ;;
        --admin-password) ADMIN_PASSWORD="${2:-}"; shift 2 ;;
        --host) BIND_HOST="${2:-}"; shift 2 ;;
        --port) BIND_PORT="${2:-}"; shift 2 ;;
        --service) INSTALL_SERVICE=1; shift ;;
        --skip-init) SKIP_INIT=1; shift ;;
        --skip-verify) SKIP_VERIFY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

# ── 定位离线包 ──────────────────────────────────────────────────────────────
if [ -z "$BUNDLE_DIR" ]; then
    BUNDLE_DIR="$(find . -maxdepth 2 -type d -name 'octop-offline-*' 2>/dev/null | head -1 || true)"
fi
[ -n "$BUNDLE_DIR" ] || die "未找到离线包目录，请用 --bundle 指定"
[ -d "$BUNDLE_DIR" ] || die "目录不存在: $BUNDLE_DIR"
BUNDLE_DIR="$(cd "$BUNDLE_DIR" && pwd)"
BUNDLE_DIR="${BUNDLE_DIR%/}"

[ -d "$BUNDLE_DIR/wheelhouse" ] || die "离线包不完整：缺少 wheelhouse/"
[ -d "$BUNDLE_DIR/dist" ] || die "离线包不完整：缺少 dist/"

info "离线包: $BUNDLE_DIR"
info "安装目录: $OCTOP_HOME"

# ── 完整性校验 ──────────────────────────────────────────────────────────────
# __pycache__ / *.pyc 由解释器运行时生成并会就地刷新，属预期行为，不计入校验：
# 校验清单生成时已排除，这里对旧包再做一次过滤（兼容早期打包的离线包）。
if [ "$SKIP_VERIFY" -eq 1 ]; then
    warn "已跳过离线包完整性校验（--skip-verify）"
elif [ -f "$BUNDLE_DIR/MANIFEST.sha256" ]; then
    VERIFY_OUT="$( cd "$BUNDLE_DIR" && sha256sum -c MANIFEST.sha256 --quiet 2>&1 || true )"
    REAL_FAIL="$(printf '%s\n' "$VERIFY_OUT" \
        | grep -E '(失败|FAILED)$' \
        | grep -v '__pycache__' \
        | grep -v '\.pyc' \
        || true)"
    if [ -n "$REAL_FAIL" ]; then
        printf '%s\n' "$REAL_FAIL" >&2
        die "离线包校验失败（文件损坏或传输不完整）；确认包可信时可用 --skip-verify 继续"
    fi
    info "离线包完整性校验通过"
fi

# ── 定位离线 Python 解释器 ──────────────────────────────────────────────────
PY_BIN="$(find "$BUNDLE_DIR/python" -maxdepth 3 -type f -name 'python3.[0-9]*' ! -name '*-config' 2>/dev/null | sort | head -1 || true)"
[ -n "$PY_BIN" ] || die "离线包中未找到 Python 解释器（python/cpython-*/bin/）"
"$PY_BIN" -c 'import sys' >/dev/null 2>&1 \
    || die "解释器无法执行：请确认离线包架构与本机一致（本机 uname -m = $(uname -m)）"
info "解释器: $PY_BIN ($("$PY_BIN" --version 2>&1))"

# ── 编译工具检查（sdist 需要）───────────────────────────────────────────────
if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
    warn "未检测到 gcc/cc：crcmod 与 evdev 需要现场编译，安装可能失败"
    warn "请先安装 gcc（麒麟：yum install -y gcc）"
fi

# ── 创建虚拟环境 ────────────────────────────────────────────────────────────
mkdir -p "$OCTOP_HOME"
info "创建虚拟环境..."
"$PY_BIN" -m venv "$OCTOP_HOME/venv"
VENV_PY="$OCTOP_HOME/venv/bin/python"
[ -x "$VENV_PY" ] || die "虚拟环境创建失败: $OCTOP_HOME/venv"

# ── 安装构建工具，再安装 Octop ──────────────────────────────────────────────
info "安装构建工具（setuptools / wheel）..."
"$VENV_PY" -m pip install --quiet --no-index \
    --find-links "$BUNDLE_DIR/wheelhouse" \
    setuptools wheel

OCTOP_WHL="$(find "$BUNDLE_DIR/dist" -maxdepth 1 -name 'octop-*.whl' | head -1 || true)"
[ -n "$OCTOP_WHL" ] || die "离线包中未找到 octop wheel"

info "离线安装 Octop（含依赖，sdist 将现场编译）..."
"$VENV_PY" -m pip install --no-index \
    --find-links "$BUNDLE_DIR/wheelhouse" \
    --find-links "$BUNDLE_DIR/dist" \
    --no-build-isolation \
    "$OCTOP_WHL"

# ── CLI 包装脚本 ────────────────────────────────────────────────────────────
info "安装 CLI 包装脚本..."
mkdir -p "$OCTOP_HOME/bin"
cat > "$OCTOP_HOME/bin/octop" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
export OCTOP_HOME="\${OCTOP_HOME:-$OCTOP_HOME}"
exec "\$OCTOP_HOME/venv/bin/octop" "\$@"
WRAPPER
chmod +x "$OCTOP_HOME/bin/octop"

if ! grep -qF "$OCTOP_HOME/bin" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# Octop\nexport PATH="%s/bin:$PATH"\n' "$OCTOP_HOME" >> "$HOME/.bashrc"
    info "已将 $OCTOP_HOME/bin 写入 ~/.bashrc"
fi
export PATH="$OCTOP_HOME/bin:$PATH"

# ── 初始化数据库与管理员 ────────────────────────────────────────────────────
if [ "$SKIP_INIT" -eq 0 ] && [ ! -f "$OCTOP_HOME/octop.db" ]; then
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)"
        GENERATED_PASSWORD=1
    else
        GENERATED_PASSWORD=0
    fi
    info "初始化数据库与管理员账号..."
    OCTOP_HOME="$OCTOP_HOME" \
    OCTOP_ADMIN_USERNAME="$ADMIN_USERNAME" \
    OCTOP_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    "$VENV_PY" - <<'PY'
import os

from octop.config import load_config
from octop.infra.agents.plugins.manager import PluginManager
from octop.infra.db.factory import open_database
from octop.infra.db.migrate import run_migrations
from octop.infra.db.repos.users import UserRepo
from octop.infra.users.password import hash_password, validate_password_policy
from octop.infra.utils.env_file import apply_env_file, env_file_path
from octop.infra.utils.paths import PathLayout

username = os.environ["OCTOP_ADMIN_USERNAME"]
password = os.environ["OCTOP_ADMIN_PASSWORD"]
validate_password_policy(password)

paths = PathLayout.from_env()
paths.ensure_root()
PluginManager(plugins_dir=paths.plugins_dir, config_path=paths.config).seed_bundled()
apply_env_file(env_file_path(paths.root))
config = load_config(paths.config)
db = open_database(config, paths)
try:
    run_migrations(db)
    UserRepo(db).create(
        username=username,
        password_hash=hash_password(password),
        role="admin",
        display_name=None,
    )
finally:
    db.close()
print(f"已创建管理员: {username}")
PY
    if [ "${GENERATED_PASSWORD:-0}" = "1" ]; then
        printf '%s\n' "username: $ADMIN_USERNAME" "password: $ADMIN_PASSWORD" \
            > "$OCTOP_HOME/credential.txt"
        chmod 600 "$OCTOP_HOME/credential.txt"
        warn "已生成随机管理员密码，并写入 $OCTOP_HOME/credential.txt"
        warn "请尽快登录后修改密码"
    fi
elif [ "$SKIP_INIT" -eq 0 ]; then
    info "检测到已有数据库，跳过初始化"
fi

# ── 绑定地址与端口 ──────────────────────────────────────────────────────────
if [ -n "$BIND_HOST" ] || [ -n "$BIND_PORT" ]; then
    info "更新 config.json 的绑定配置..."
    OCTOP_HOME="$OCTOP_HOME" OCTOP_BIND_HOST="$BIND_HOST" OCTOP_BIND_PORT="$BIND_PORT" \
        "$VENV_PY" - <<'PY'
import json
import os
from pathlib import Path

host = os.environ.get("OCTOP_BIND_HOST") or ""
port = os.environ.get("OCTOP_BIND_PORT") or ""
path = Path(os.environ["OCTOP_HOME"]) / "config.json"
data = json.loads(path.read_text()) if path.exists() else {}
if host:
    data["bind_host"] = host
if port:
    data["port"] = int(port)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print(f"config.json 已更新: {path}")
PY
fi

# ── 系统服务 ────────────────────────────────────────────────────────────────
if [ "$INSTALL_SERVICE" -eq 1 ]; then
    info "安装并启动系统服务..."
    "$OCTOP_HOME/bin/octop" service start \
        || warn "服务注册失败（systemd 通常需要 root）。可稍后手动执行: sudo octop service start"
fi

# ── 完成 ────────────────────────────────────────────────────────────────────
echo ""
info "Octop 离线安装完成"
echo ""
echo "  验证:"
echo "    $OCTOP_HOME/bin/octop --version"
echo ""
echo "  前台启动:"
echo "    $OCTOP_HOME/bin/octop run"
echo ""
echo "  后台启动（systemd）:"
echo "    sudo $OCTOP_HOME/bin/octop service start"
echo ""
echo "  新开终端后可直接使用 octop 命令（PATH 已写入 ~/.bashrc）"
echo ""
if [ "${BIND_HOST:-}" != "0.0.0.0" ]; then
    warn "当前绑定地址为 ${BIND_HOST:-127.0.0.1}，只有本机可访问。"
    warn "如需内网其他机器访问，重新执行并加 --host 0.0.0.0，"
    warn "或修改 $OCTOP_HOME/config.json 的 bind_host 后重启服务。"
    echo ""
fi
