#!/usr/bin/env bash
# =============================================================================
# Octop 内网离线包制作 —— 在【可联网的构建机】上执行
#
# 用途：把 Octop 运行所需的一切（Python 解释器、全部依赖包、前端产物、
#       wheel、uv 与构建工具）打成单个离线包，供无外网的内网服务器安装。
#
# 用法（在仓库根目录执行）:
#   bash scripts/offline_pack.sh                # 全量打包（首次安装用）
#   bash scripts/offline_pack.sh --wheel-only   # 增量打包：只出 octop wheel，约 17M
#   bash scripts/offline_pack.sh --list         # 列出已归档的所有离线包
#
# 产物（每次打包生成一个以打包时间命名的目录，全部产物都在其中）:
#   全量包  offline-dist/<YYYYmmdd-HHMMSS>/
#   ├── octop-offline-<arch>-<version>/            离线包目录（含 MANIFEST.sha256）
#   ├── octop-offline-<arch>-<version>.tar.gz      传输用的压缩包
#   └── octop-offline-<arch>-<version>.tar.gz.sha256
#
#   增量包  offline-dist/<YYYYmmdd-HHMMSS>-wheel/
#   ├── octop-<version>-py3-none-any.whl           供 offline_update.sh 更新用
#   └── octop-<version>-py3-none-any.whl.sha256
#
# 环境变量:
#   OCTOP_ARCH        目标 CPU 架构（默认 aarch64）
#   OCTOP_PY          Python 版本（默认 3.12）
#   OUT_DIR           输出目录（默认 <仓库>/offline-dist）
#   OCTOP_PYPI_INDEX  PyPI 镜像（默认腾讯云；内网构建机可换成内网源）
#
# 注意:
#   - 构建机的 CPU 架构无需与目标机相同（本脚本做的是跨平台下载）。
#   - 但目标机的 glibc 必须 >= 2.28（manylinux_2_28 要求）。
#   - Playwright Chromium 体积大且非必需，本脚本不下载；需要时见文档。
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OCTOP_ARCH="${OCTOP_ARCH:-aarch64}"
OCTOP_PY="${OCTOP_PY:-3.12}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/offline-dist}"
PYPI_INDEX="${OCTOP_PYPI_INDEX:-https://mirrors.cloud.tencent.com/pypi/simple}"
PYPI_HOST="$(printf '%s' "$PYPI_INDEX" | awk -F/ '{print $3}')"
ABI_TAG="cp${OCTOP_PY/./}"

info() { printf '\033[0;32m[pack]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[pack]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[pack]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

command -v uv >/dev/null 2>&1 || die "未找到 uv，请先安装：https://docs.astral.sh/uv/"
[ -f pyproject.toml ] && [ -f uv.lock ] || die "请在仓库根目录执行本脚本"

VERSION="$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' pyproject.toml | head -1)"
[ -n "$VERSION" ] || die "无法从 pyproject.toml 读取版本号"

BUNDLE_NAME="octop-offline-${OCTOP_ARCH}-${VERSION}"

# ── 参数解析 ────────────────────────────────────────────────────────────────
LIST_ONLY=0
WHEEL_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=1; shift ;;
        --wheel-only) WHEEL_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

# ── --list：列出已归档的离线包（不做打包）────────────────────────────────────
if [ "$LIST_ONLY" -eq 1 ]; then
    printf '%-22s %-6s %-38s %8s  %s\n' "打包时间" "类型" "包名" "大小" "状态"
    printf '%s\n' "--------------------------------------------------------------------------------------------------------"
    found=0
    for dir in "$OUT_DIR"/*/; do
        [ -d "$dir" ] || continue
        found=1
        stamp="$(basename "${dir%/}")"
        tarball="$(find "$dir" -maxdepth 1 -name 'octop-offline-*.tar.gz' 2>/dev/null | head -1)"
        wheelfile="$(find "$dir" -maxdepth 1 -name 'octop-*.whl' 2>/dev/null | head -1)"
        if [ -n "$tarball" ]; then
            kind="全量"
            artifact="$tarball"
        elif [ -n "$wheelfile" ]; then
            kind="增量"
            artifact="$wheelfile"
        else
            printf '%-22s %-6s %-38s %8s  %s\n' "$stamp" "-" "-" "-" "未打包完成"
            continue
        fi
        name="$(basename "$artifact")"
        size="$(du -h "$artifact" | cut -f1)"
        sumfile="$(basename "$artifact").sha256"
        if [ ! -f "$dir/$sumfile" ]; then
            status="缺少校验文件"
        elif ( cd "$dir" && sha256sum -c "$sumfile" --quiet ) >/dev/null 2>&1; then
            status="校验通过"
        else
            status="校验失败"
        fi
        printf '%-22s %-6s %-38s %8s  %s\n' "$stamp" "$kind" "$name" "$size" "$status"
    done
    [ "$found" -eq 1 ] || info "暂无离线包（$OUT_DIR 为空）"
    exit 0
fi

# 每次打包归档到「以打包时间命名」的目录，所有产物都放在其中
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$OUT_DIR/$STAMP"
BUNDLE_DIR="$RUN_DIR/$BUNDLE_NAME"

PLATFORM_ARGS=(
    --platform manylinux_2_28_aarch64
    --platform manylinux_2_17_aarch64
    --platform manylinux2014_aarch64
    --platform linux_aarch64
)

# 用一个不依赖项目环境的临时 uv 环境来跑 pip（避免 uv sync 项目依赖）
_pip() {
    uv run --no-project --index-url "$PYPI_INDEX" --with pip python -m pip "$@"
}

# 前端产物是否需要重建：缺失，或 dashboard 源码比已有产物新
_frontend_stale() {
    [ -f src/octop/dashboard/index.html ] || return 0
    [ -n "$(find dashboard/src dashboard/index.html dashboard/package.json \
        -newer src/octop/dashboard/index.html 2>/dev/null | head -1)" ]
}

# node_modules 是否必须重装：缺失，或 package-lock.json 比已安装的更新。
# 已有依赖时跳过 npm ci —— 它会先删除整个 node_modules，在启用了批量删除
# 保护的环境里会直接失败（SAFE_DELETE_BULK_CONFIRM_REQUIRED）。
_need_npm_ci() {
    [ -d dashboard/node_modules ] || return 0
    [ -f dashboard/node_modules/.package-lock.json ] || return 0
    [ dashboard/package-lock.json -nt dashboard/node_modules/.package-lock.json ]
}

_ensure_frontend() {
    if _frontend_stale; then
        command -v npm >/dev/null 2>&1 || die "缺少 npm，无法构建前端；请安装 Node.js"
        if _need_npm_ci; then
            info "安装前端依赖并构建（npm ci && npm run build）..."
            ( cd dashboard && npm ci && NODE_ENV=production npm run build )
        else
            info "构建前端产物（复用已有 node_modules，package-lock.json 未变）..."
            ( cd dashboard && NODE_ENV=production npm run build )
        fi
    else
        info "复用已有前端产物 src/octop/dashboard/"
    fi
}

# ── 增量模式：只重建 octop wheel，供内网 offline_update.sh 做轻量更新 ────────
if [ "$WHEEL_ONLY" -eq 1 ]; then
    RUN_DIR="$OUT_DIR/${STAMP}-wheel"
    info "增量打包：octop wheel 为 py3-none-any，与目标架构无关"
    _ensure_frontend
    info "构建 octop wheel（版本 $VERSION）..."
    rm -rf "$RUN_DIR"
    mkdir -p "$RUN_DIR"
    uv build --out-dir "$RUN_DIR"
    rm -f "$RUN_DIR/octop-${VERSION}.tar.gz"
    WHEEL_FILE="$(find "$RUN_DIR" -maxdepth 1 -name 'octop-*.whl' | head -1)"
    [ -n "$WHEEL_FILE" ] || die "wheel 构建失败"
    ( cd "$RUN_DIR" && sha256sum "$(basename "$WHEEL_FILE")" > "$(basename "$WHEEL_FILE").sha256" )
    echo ""
    info "增量包制作完成"
    printf '  %-14s %s\n' "归档目录:" "$RUN_DIR"
    printf '  %-14s %s\n' "wheel:" "$(basename "$WHEEL_FILE")"
    printf '  %-14s %s\n' "大小:" "$(du -h "$WHEEL_FILE" | cut -f1)"
    echo ""
    echo "下一步："
    echo "  1) 传输整个目录（含 .sha256）到内网"
    echo "  2) 在内网执行："
    echo "       bash scripts/offline_update.sh --bundle ./${STAMP}-wheel"
    echo ""
    warn "仅在依赖未变（pyproject.toml / uv.lock 未改动）时适用；"
    warn "依赖有变化时请改用全量打包并重跑 offline_install.sh。"
    exit 0
fi

info "Octop 版本: $VERSION / 目标架构: $OCTOP_ARCH / Python: $OCTOP_PY"
info "归档目录: $RUN_DIR"

# ── 1. 前端产物（平台无关，可跨架构复用）─────────────────────────────────────
info "[1/7] 准备前端产物..."
_ensure_frontend

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/wheelhouse" "$BUNDLE_DIR/dist" "$BUNDLE_DIR/python"

# ── 2. Octop 自身 wheel（py3-none-any，平台无关）────────────────────────────
info "[2/7] 构建 octop wheel..."
uv build --out-dir "$BUNDLE_DIR/dist"

# ── 3. 导出锁定依赖（去掉 hash：跨平台哈希不同）──────────────────────────────
info "[3/7] 导出依赖清单..."
uv export --frozen --no-dev --extra browser --no-emit-project --no-hashes \
    -o "$BUNDLE_DIR/requirements.txt"
REQ_COUNT="$(grep -cE '^[A-Za-z0-9]' "$BUNDLE_DIR/requirements.txt" || true)"
info "      依赖条目: $REQ_COUNT"

# ── 4. 目标架构的 Python 解释器（python-build-standalone，免编译）────────────
info "[4/7] 下载 ${OCTOP_ARCH} 的 CPython ${OCTOP_PY} 解释器..."
uv python install "cpython-${OCTOP_PY}-linux-${OCTOP_ARCH}-gnu" \
    --install-dir "$BUNDLE_DIR/python"

# ── 5. 全部依赖包（有 wheel 用 wheel，没 wheel 回退 sdist）───────────────────
info "[5/7] 下载 ${OCTOP_ARCH} 依赖包（wheel + sdist，体积较大请耐心等待）..."
_pip download -q --no-deps \
    "${PLATFORM_ARGS[@]}" \
    --python-version "$OCTOP_PY" --implementation cp --abi "$ABI_TAG" \
    --index-url "$PYPI_INDEX" --trusted-host "$PYPI_HOST" \
    -r "$BUNDLE_DIR/requirements.txt" \
    -d "$BUNDLE_DIR/wheelhouse"

# ── 6. uv 本体与构建工具（供内网创建 venv / 编译 sdist）──────────────────────
info "[6/7] 下载 uv 与构建工具（setuptools / wheel）..."
_pip download -q --no-deps --only-binary=:all: \
    "${PLATFORM_ARGS[@]}" \
    --python-version "$OCTOP_PY" --implementation cp --abi "$ABI_TAG" \
    --index-url "$PYPI_INDEX" --trusted-host "$PYPI_HOST" \
    uv setuptools wheel \
    -d "$BUNDLE_DIR/wheelhouse"

# ── 7. 校验清单与压缩包 ─────────────────────────────────────────────────────
info "[7/7] 生成校验清单并打包..."
# 排除 __pycache__/*.pyc：解释器首次运行会就地刷新字节码缓存，
# 那属于预期行为，不应计入完整性校验（否则二次安装必然误报校验失败）。
( cd "$BUNDLE_DIR" && find . -type f \
    ! -name MANIFEST.sha256 \
    ! -path '*/__pycache__/*' \
    ! -name '*.pyc' \
    | sort | xargs sha256sum > MANIFEST.sha256 )

WHL_COUNT="$(find "$BUNDLE_DIR/wheelhouse" -name '*.whl' | wc -l)"
SDIST_COUNT="$(find "$BUNDLE_DIR/wheelhouse" -name '*.tar.gz' | wc -l)"

tar -czf "$RUN_DIR/$BUNDLE_NAME.tar.gz" -C "$RUN_DIR" "$BUNDLE_NAME"
( cd "$RUN_DIR" && sha256sum "$BUNDLE_NAME.tar.gz" > "$BUNDLE_NAME.tar.gz.sha256" )

# ── 完成 ────────────────────────────────────────────────────────────────────
echo ""
info "离线包制作完成"
printf '  %-14s %s\n' "归档目录:" "$RUN_DIR"
printf '  %-14s %s\n' "压缩包:" "$RUN_DIR/$BUNDLE_NAME.tar.gz"
printf '  %-14s %s\n' "wheel:" "$WHL_COUNT 个"
printf '  %-14s %s\n' "sdist:" "$SDIST_COUNT 个（内网需现场编译）"
printf '  %-14s %s\n' "大小:" "$(du -sh "$RUN_DIR/$BUNDLE_NAME.tar.gz" | cut -f1)"
echo ""
echo "查看历史离线包: bash scripts/offline_pack.sh --list"
echo ""
echo "下一步："
echo "  1) 传输压缩包与 .sha256 文件到内网机器"
echo "  2) 在内网解压后执行："
echo "       bash scripts/offline_install.sh --bundle ./$BUNDLE_NAME"
echo ""
warn "注意：目标机 glibc 必须 >= 2.28；sdist 中的 crcmod / evdev 需要 gcc 现场编译。"
