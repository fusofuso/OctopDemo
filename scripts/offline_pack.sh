#!/usr/bin/env bash
# =============================================================================
# Octop 内网离线包制作 —— 在【可联网的构建机】上执行
#
# 用途：把 Octop 运行所需的一切（Python 解释器、全部依赖包、前端产物、
#       wheel、uv 与构建工具）打成单个离线包，供无外网的内网服务器安装。
#
# 用法（在仓库根目录执行）:
#   bash scripts/offline_pack.sh
#
# 产物:
#   offline-dist/octop-offline-<arch>-<version>/            离线包目录
#   offline-dist/octop-offline-<arch>-<version>.tar.gz      传输用的压缩包
#   offline-dist/octop-offline-<arch>-<version>.tar.gz.sha256
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

command -v uv >/dev/null 2>&1 || die "未找到 uv，请先安装：https://docs.astral.sh/uv/"
[ -f pyproject.toml ] && [ -f uv.lock ] || die "请在仓库根目录执行本脚本"

VERSION="$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' pyproject.toml | head -1)"
[ -n "$VERSION" ] || die "无法从 pyproject.toml 读取版本号"

BUNDLE_NAME="octop-offline-${OCTOP_ARCH}-${VERSION}"
BUNDLE_DIR="$OUT_DIR/$BUNDLE_NAME"
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

info "Octop 版本: $VERSION / 目标架构: $OCTOP_ARCH / Python: $OCTOP_PY"
info "产物目录: $BUNDLE_DIR"

# ── 1. 前端产物（平台无关，可跨架构复用）─────────────────────────────────────
if [ ! -f src/octop/dashboard/index.html ]; then
    info "[1/7] 构建前端产物..."
    command -v npm >/dev/null 2>&1 || die "缺少 npm，无法构建前端；请安装 Node.js 或先用 make build-frontend"
    ( cd dashboard && npm ci && NODE_ENV=production npm run build )
else
    info "[1/7] 复用已有前端产物 src/octop/dashboard/"
fi

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
( cd "$BUNDLE_DIR" && find . -type f ! -name MANIFEST.sha256 | sort | xargs sha256sum > MANIFEST.sha256 )

WHL_COUNT="$(find "$BUNDLE_DIR/wheelhouse" -name '*.whl' | wc -l)"
SDIST_COUNT="$(find "$BUNDLE_DIR/wheelhouse" -name '*.tar.gz' | wc -l)"

tar -czf "$OUT_DIR/$BUNDLE_NAME.tar.gz" -C "$OUT_DIR" "$BUNDLE_NAME"
( cd "$OUT_DIR" && sha256sum "$BUNDLE_NAME.tar.gz" > "$BUNDLE_NAME.tar.gz.sha256" )

# ── 完成 ────────────────────────────────────────────────────────────────────
echo ""
info "离线包制作完成"
printf '  %-14s %s\n' "目录:" "$BUNDLE_DIR"
printf '  %-14s %s\n' "压缩包:" "$OUT_DIR/$BUNDLE_NAME.tar.gz"
printf '  %-14s %s\n' "wheel:" "$WHL_COUNT 个"
printf '  %-14s %s\n' "sdist:" "$SDIST_COUNT 个（内网需现场编译）"
printf '  %-14s %s\n' "大小:" "$(du -sh "$OUT_DIR/$BUNDLE_NAME.tar.gz" | cut -f1)"
echo ""
echo "下一步："
echo "  1) 校验并传输压缩包与 .sha256 文件到内网机器"
echo "  2) 在内网解压后执行："
echo "       bash scripts/offline_install.sh --bundle ./$BUNDLE_NAME"
echo ""
warn "注意：目标机 glibc 必须 >= 2.28；sdist 中的 crcmod / evdev 需要 gcc 现场编译。"
