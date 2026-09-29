#!/usr/bin/env bash
# =============================================================================
# Octop 内网离线增量更新 —— 在【已安装 Octop 的目标机】上执行
#
# 用途：本地代码有更新（Python 源码 / 前端）时，只替换 octop 自身，
#       无需重新安装整个离线包（依赖不变的前提下）。
#
# 前提：目标机已通过 scripts/offline_install.sh 安装过 Octop。
#
# 用法:
#   bash scripts/offline_update.sh --bundle ./20260929-153000-wheel
#   bash scripts/offline_update.sh --wheel ./octop-1.0.2b4-py3-none-any.whl
#
# 常用选项:
#   --wheel PATH    新的 octop wheel 文件
#   --bundle DIR    增量包目录（自动查找其中的 octop-*.whl）
#   --home DIR      安装根目录（默认 ~/.octop）
#   --no-restart    更新后不自动重启服务
#   -h, --help      显示帮助
#
# 注意:
#   - 本脚本只更新 octop 本体（--no-deps），要求依赖未变。
#     若 pyproject.toml / uv.lock 有改动（新增或升级依赖），
#     请改用全量包重新执行 offline_install.sh，否则可能缺依赖。
#   - 数据库结构会在服务重启后自动迁移，你的数据不会丢失。
# =============================================================================
set -euo pipefail

OCTOP_HOME="${OCTOP_HOME:-$HOME/.octop}"
WHEEL=""
BUNDLE_DIR=""
AUTO_RESTART=1

info() { printf '\033[0;32m[update]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[update]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[update]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --wheel) WHEEL="${2:-}"; shift 2 ;;
        --bundle) BUNDLE_DIR="${2:-}"; shift 2 ;;
        --home) OCTOP_HOME="${2:-}"; shift 2 ;;
        --no-restart) AUTO_RESTART=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

OCTOP_HOME="${OCTOP_HOME%/}"
VENV_PY="$OCTOP_HOME/venv/bin/python"
[ -x "$VENV_PY" ] || die "未找到已安装的 Octop（$VENV_PY 不存在）。请先执行 offline_install.sh"

# ── 定位新的 wheel ──────────────────────────────────────────────────────────
if [ -z "$WHEEL" ]; then
    if [ -z "$BUNDLE_DIR" ]; then
        BUNDLE_DIR="$(find . -maxdepth 2 -type d -name '*-wheel' -o -maxdepth 2 -type d -name 'octop-offline-*' 2>/dev/null | head -1 || true)"
    fi
    [ -n "$BUNDLE_DIR" ] || die "未指定 wheel：请用 --wheel 或 --bundle 指定"
    [ -d "$BUNDLE_DIR" ] || die "目录不存在: $BUNDLE_DIR"
    WHEEL="$(find "$BUNDLE_DIR" -maxdepth 1 -name 'octop-*.whl' | sort | head -1 || true)"
fi
[ -n "$WHEEL" ] || die "未找到 octop wheel"
[ -f "$WHEEL" ] || die "wheel 文件不存在: $WHEEL"
WHEEL="$(cd "$(dirname "$WHEEL")" && pwd)/$(basename "$WHEEL")"

info "安装目录: $OCTOP_HOME"
info "新 wheel:  $WHEEL"

# ── 校验（若随附 sha256）────────────────────────────────────────────────────
SUM_FILE="$WHEEL.sha256"
if [ -f "$SUM_FILE" ]; then
    if ( cd "$(dirname "$WHEEL")" && sha256sum -c "$(basename "$SUM_FILE")" --quiet ) >/dev/null 2>&1; then
        info "wheel 校验通过"
    else
        die "wheel 校验失败（文件损坏或传输不完整）"
    fi
fi

# ── 记录当前版本 ────────────────────────────────────────────────────────────
OLD_VERSION="$("$OCTOP_HOME/venv/bin/octop" --version 2>/dev/null || echo '未知')"
info "当前版本: $OLD_VERSION"

# ── 重装 octop 本体 ─────────────────────────────────────────────────────────
info "更新 octop（--no-deps，仅替换本体）..."
"$VENV_PY" -m pip install --quiet --no-index --no-deps --force-reinstall "$WHEEL"

NEW_VERSION="$("$OCTOP_HOME/venv/bin/octop" --version 2>/dev/null || echo '未知')"
info "更新后版本: $NEW_VERSION"

# ── 重启服务 ────────────────────────────────────────────────────────────────
if [ "$AUTO_RESTART" -eq 1 ]; then
    if "$OCTOP_HOME/bin/octop" service status --no-health >/dev/null 2>&1; then
        info "重启系统服务..."
        "$OCTOP_HOME/bin/octop" service restart || warn "服务重启失败，请手动检查"
    else
        warn "未检测到已安装的 systemd/launchd 服务。"
        warn "若 Octop 是前台运行（octop run），请 Ctrl-C 后重新启动。"
    fi
fi

# ── 健康检查 ────────────────────────────────────────────────────────────────
PORT="$(sed -n 's/.*"port"[: ]*\([0-9]\+\).*/\1/p' "$OCTOP_HOME/config.json" 2>/dev/null | head -1)"
PORT="${PORT:-8088}"
HEALTH="$(curl -s -m 5 "http://127.0.0.1:${PORT}/api/health" 2>/dev/null || true)"
echo ""
if [ -n "$HEALTH" ]; then
    info "健康检查: $HEALTH"
else
    warn "健康检查无响应（http://127.0.0.1:${PORT}/api/health）"
    warn "若刚重启，稍等数秒后重试；仍失败请查看 $OCTOP_HOME/logs/octop.log"
fi
echo ""
info "更新完成：$OLD_VERSION -> $NEW_VERSION"
