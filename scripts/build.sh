#!/usr/bin/env bash
# Box64 build for HarmonyOS HNP (clean baseline, NO PATCHES).
#
# 用途:
#   一份干净的脚手架,验证 toolchain / CMake / 打包链路通畅,
#   然后从这里出发逐项加补丁,定位每个 patch 解决的具体问题.
#
# 用法:
#   bash build_box64_ohos_clean.sh
#
# 环境变量:
#   OHOS_SDK         默认 /home/seina/ohos-sdk/linux
#   HOST_HNP_DIR     默认 /mnt/c/Myws/hm/HarmonyBox/hnp/arm64-v8a
#   SKIP_HNP=1       跳过 HNP 打包
#   SKIP_COPY=1      跳过拷贝到 Windows 主机
#   RESET_SOURCE=1   编译前 git reset --hard 源码 (移除以前残留的补丁)

set -e
START=$(date +%s%N)

# ================================================================
# 0. 环境
# ================================================================
export OHOS_SDK="${OHOS_SDK:-/home/seina/ohos-sdk/linux}"
export OHOS_TOOLCHAIN="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake"
export OHOS_CMAKE="$OHOS_SDK/native/build-tools/cmake/bin/cmake"
export OHOS_NINJA="$OHOS_SDK/native/build-tools/cmake/bin/ninja"
export OHOS_ARCH="${OHOS_ARCH:-arm64-v8a}"

ROOT=~/HarmonyBox
BOX64=$ROOT/box64
BUILD=$ROOT/build_box64_clean
OUT=$ROOT/out

HNP_NAME=box64
HNP_VERSION=1.0.0
HNP_STAGING=$ROOT/hnp_staging_clean

THIRD_PARTY=$ROOT/thirdparty
mkdir -p "$THIRD_PARTY"

RESET_SOURCE=0
for arg in "$@"; do
    case "$arg" in
        --reset-source) RESET_SOURCE=1 ;;
        *) echo "未知参数: $arg"; exit 1 ;;
    esac
done

# ================================================================
# 1. 源码与工具链检查
# ================================================================
if [ ! -d "$BOX64" ]; then
    echo "ERROR: box64 源码不存在: $BOX64"
    echo "       git clone https://github.com/ptitSeb/box64.git $BOX64"
    exit 1
fi
for f in "$OHOS_TOOLCHAIN" "$OHOS_CMAKE" "$OHOS_NINJA"; do
    if [ ! -e "$f" ]; then
        echo "ERROR: 找不到 $f"
        exit 1
    fi
done

echo "==> environment"
echo "    OHOS_SDK   = $OHOS_SDK"
echo "    OHOS_ARCH  = $OHOS_ARCH"
echo "    box64 src  = $BOX64"
echo "    build dir  = $BUILD"
echo "    out  dir   = $OUT"

# ================================================================
# 2. 清理
# ================================================================
if [ $RESET_SOURCE -eq 1 ]; then
    echo "==> git reset --hard (清除以前补丁残留)"
    cd "$BOX64"
    git reset --hard
    git clean -fdx
    cd - > /dev/null
fi

if [ -d "$BUILD" ]; then
    echo "==> 清理 $BUILD"
    rm -rf "$BUILD"
fi
mkdir -p "$BUILD"

# ================================================================
# 3. 应用 HarmonyOS 适配补丁
# ================================================================

PATCH_SCRIPT="$(dirname "$(readlink -f "$0")")/patches.sh"
if [ ! -f "$PATCH_SCRIPT" ]; then
    echo "ERROR: 找不到 patches.sh: $PATCH_SCRIPT"
    exit 1
fi

if [ $RESET_SOURCE -eq 0 ]; then
    echo "==> SKIP_PATCHES=1, 不打 patch (clean baseline 模式)"
else
    echo "==> apply patches"
    BOX64="$BOX64" bash "$PATCH_SCRIPT"
fi

# ================================================================
# 4. CMake 配置 (executable, PIE, 不打任何补丁)
# ================================================================
echo "==> CMake configure"
cd "$BUILD"

# 只静默 warning,不引入任何功能性宏定义,保持 clean baseline 语义
WARN_FLAGS=$(cat <<'EOF' | tr '\n' ' '
-Wno-macro-redefined
-Wno-unused-command-line-argument
-Wno-format
-Wno-format-security
-Wno-error=format-security
-Wno-deprecated-declarations
-Wno-unused-function
-Wno-unused-variable
-Wno-unused-but-set-variable
-Wno-int-conversion
-Wno-error=int-conversion
-Wno-incompatible-pointer-types
-Wno-implicit-function-declaration
-Wno-string-plus-int
-Wno-array-bounds
-Wno-ignored-pragmas
EOF
)

"$OHOS_CMAKE" "$BOX64" \
    -GNinja \
    -DCMAKE_MAKE_PROGRAM="$OHOS_NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$OHOS_TOOLCHAIN" \
    -DOHOS_ARCH="$OHOS_ARCH" \
    -DOHOS_PLATFORM=OHOS \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DARM_DYNAREC=ON \
    -DGENERIC_ARM=1 \
    -DNOLOADADDR=1 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$WARN_FLAGS" \
    -DCMAKE_CXX_FLAGS="$WARN_FLAGS"

# ================================================================
# 5. 编译
# ================================================================
LOG_DIR=$ROOT/logs
mkdir -p "$LOG_DIR"
TS=$(date +%Y%m%d_%H%M%S)
BUILD_LOG="$LOG_DIR/clean_${TS}.log"
LATEST_LOG="$LOG_DIR/clean_latest.log"

echo "==> ninja box64 (log: $BUILD_LOG)"

set +e
"$OHOS_NINJA" box64 -j"$(nproc)" 2>&1 | tee "$BUILD_LOG"
NINJA_RC=${PIPESTATUS[0]}
set -e

ln -sfn "$BUILD_LOG" "$LATEST_LOG"

if [ "$NINJA_RC" -ne 0 ]; then
    echo ""
    echo "============================================================"
    echo "  编译失败 (exit=$NINJA_RC)  这正是 'clean' 期望的入口"
    echo "  完整日志: $BUILD_LOG"
    echo "============================================================"
    echo ""
    echo "==== 第一段 FAILED ===="
    awk '/^FAILED:/{f=1} f{print; if(/^\[[0-9]+\/[0-9]+\]/ && !/^FAILED:/) exit}' \
        "$BUILD_LOG" | head -80
    echo ""
    echo "==== error: 行汇总 (前 50) ===="
    grep -nE 'error:|FAILED:' "$BUILD_LOG" | head -50
    echo ""
    echo "提示: 这份脚本不打补丁,失败是预期的.根据上面的 error 逐项加 patch."
    exit 1
fi

echo "==> 编译成功"

# ================================================================
# 6. 输出 & ELF 信息
# ================================================================
mkdir -p "$OUT"
BIN_PATH="$BUILD/box64"
if [ ! -f "$BIN_PATH" ]; then
    BIN_PATH=$(find "$BUILD" -maxdepth 2 -name 'box64' -type f -executable | head -1)
fi
if [ -z "$BIN_PATH" ] || [ ! -f "$BIN_PATH" ]; then
    echo "ERROR: 找不到 box64 可执行文件"
    exit 1
fi
cp "$BIN_PATH" "$OUT/box64"
chmod +x "$OUT/box64"

LLVM_BIN="$OHOS_SDK/native/llvm/bin"

echo ""
echo "============================================================"
echo "  box64 built"
echo "  output: $OUT/box64"
ls -lh "$OUT/box64"

if [ -x "$LLVM_BIN/llvm-readelf" ]; then
    echo ""
    echo "  ELF info:"
    "$LLVM_BIN/llvm-readelf" -h "$OUT/box64" \
        | grep -E 'Class|Machine|Type' | sed 's/^/    /' || true
    echo ""
    echo "  dynamic deps:"
    "$LLVM_BIN/llvm-readelf" -d "$OUT/box64" \
        | grep -E 'NEEDED|SONAME|RUNPATH|RPATH' | sed 's/^/    /' || true
    echo ""
    echo "  chksum:"
    md5sum "$OUT/box64"
fi
echo "============================================================"

# ================================================================
# 7. HNP 打包
# ================================================================
if [ "${SKIP_HNP:-0}" = "1" ]; then
    echo "SKIP_HNP=1, skipping HNP packaging"
else
    echo ""
    echo "==> HNP packaging: ${HNP_NAME} v${HNP_VERSION}"

    rm -rf "$HNP_STAGING"
    mkdir -p "$HNP_STAGING/bin"
    cp "$OUT/box64" "$HNP_STAGING/bin/box64"
    chmod +x "$HNP_STAGING/bin/box64"

    cat > "$HNP_STAGING/hnp.json" << EOF_HNP
{
    "type": "hnp-config",
    "name": "${HNP_NAME}",
    "version": "${HNP_VERSION}",
    "install": {
        "links": [
            { "source": "./bin/box64", "target": "box64" }
        ]
    }
}
EOF_HNP

    echo "    [+] staging:"
    find "$HNP_STAGING" -type f | sed 's/^/        /'

    HNPCLI=""
    for cand in \
        "$OHOS_SDK/toolchains/hnpcli" \
        "$OHOS_SDK/native/build-tools/hnpcli/bin/hnpcli" \
        "$OHOS_SDK/native/build-tools/hnpcli/hnpcli" \
        "$(command -v hnpcli 2>/dev/null)" \
        "$(command -v hnp 2>/dev/null)"; do
        if [ -n "$cand" ] && [ -x "$cand" ]; then
            HNPCLI="$cand"; break
        fi
    done

    HNP_FILE=""
    if [ -n "$HNPCLI" ]; then
        echo "    [+] using $HNPCLI"
        "$HNPCLI" pack -i "$HNP_STAGING" -o "$OUT" -n "$HNP_NAME" -v "$HNP_VERSION"
        HNP_FILE=$(ls -t "$OUT"/*.hnp 2>/dev/null | head -1)
    else
        echo "    [+] hnpcli not found, falling back to zip"
        HNP_FILE="$OUT/${HNP_NAME}.hnp"
        rm -f "$HNP_FILE"
        if ! command -v zip >/dev/null 2>&1; then
            echo "ERROR: 既无 hnpcli 也无 zip"
            exit 1
        fi
        # 显式列文件名,避免 'zip -r .' 产生的 ./ 前缀
        (cd "$HNP_STAGING" && zip -qr "$HNP_FILE" bin hnp.json)
    fi

    if [ -n "$HNP_FILE" ] && [ -f "$HNP_FILE" ]; then
        echo ""
        echo "  HNP: $HNP_FILE"
        ls -lh "$HNP_FILE"
        if command -v unzip >/dev/null 2>&1; then
            echo ""
            echo "  contents:"
            unzip -l "$HNP_FILE" | sed 's/^/    /'
            if unzip -l "$HNP_FILE" | awk '{print $NF}' | grep -Fxq 'bin/box64'; then
                echo "    [OK] structure verified: bin/box64"
            else
                echo "    [WARN] 'bin/box64' not at expected path"
            fi
        fi
    else
        echo "WARN: HNP 文件未生成"
    fi
fi

# ================================================================
# 8. Copy HNP to Windows host (WSL convenience)
# ================================================================
HOST_HNP_DIR="${HOST_HNP_DIR:-/mnt/c/Myws/hm/HarmonyBox/hnp/arm64-v8a}"

if [ "${SKIP_COPY:-0}" = "1" ]; then
    echo "SKIP_COPY=1, skipping host copy"
elif [ -z "${HNP_FILE:-}" ] || [ ! -f "$HNP_FILE" ]; then
    : # 已经 warn 过
elif [ ! -d "/mnt/c" ]; then
    echo "INFO: not in WSL (no /mnt/c), skipping host copy"
else
    echo ""
    echo "==> copy HNP -> $HOST_HNP_DIR"
    if mkdir -p "$HOST_HNP_DIR" 2>/dev/null && cp -f "$HNP_FILE" "$HOST_HNP_DIR/"; then
        DEST="$HOST_HNP_DIR/$(basename "$HNP_FILE")"
        echo "    [OK] $DEST"
        ls -lh "$DEST" | sed 's/^/        /'
    else
        echo "    [ERR] copy failed"
    fi
fi

END=$(date +%s%N)
SEC=$(( (END-START)/1000000000 ))
MS=$(( ((END-START)/1000000)%1000 ))
echo ""
echo "  done in ${SEC}.${MS}s"
echo "============================================================"

LLVM=$OHOS_SDK/native/llvm/bin

# 用 out/box64 (跟设备上 hnp 装的是同一个二进制)
# for pc in 0x7ead5c 0x7b21e0 0x7abb5c; do
#     echo "=== PC = $pc ==="
#     $LLVM/llvm-addr2line -e out/box64 -f -C -i $pc
#     echo
# done