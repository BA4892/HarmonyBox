#!/bin/bash
set -e
START=$(date +%s%N)

# ================================================================
# 0. Environment
# ================================================================
export OHOS_SDK=${OHOS_SDK:-/home/seina/ohos-sdk/linux}
export OHOS_TOOLCHAIN="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake"
export OHOS_CMAKE=${OHOS_SDK}/native/build-tools/cmake/bin/cmake
export OHOS_NINJA=${OHOS_SDK}/native/build-tools/cmake/bin/ninja
export OHOS_ARCH=arm64-v8a

ROOT=$(cd "$(dirname "$0")" && pwd)
SRC=$ROOT/src/abitest
BUILD=$ROOT/build_abitest
OUT=$ROOT/out

HNP_NAME=abitest
HNP_VERSION=1.0.0
HNP_STAGING=$ROOT/hnp_staging_abitest

# ================================================================
# 1. Sanity checks
# ================================================================
if [ ! -d "$SRC" ]; then
    echo "ERROR: source dir not found: $SRC"
    exit 1
fi
if [ ! -f "$OHOS_TOOLCHAIN" ]; then
    echo "ERROR: OHOS toolchain not found: $OHOS_TOOLCHAIN"
    echo "       set OHOS_SDK env var (current: $OHOS_SDK)"
    exit 1
fi

# ================================================================
# 2. Clean
# ================================================================
if [ -d "$BUILD" ]; then
    echo "==> cleaning $BUILD"
    rm -rf "$BUILD"
fi

# ================================================================
# 3. Configure
# ================================================================
echo "==> CMake configure"
mkdir -p "$BUILD"
cd "$BUILD"

"$OHOS_CMAKE" "$SRC" \
    -GNinja \
    -DCMAKE_MAKE_PROGRAM="$OHOS_NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$OHOS_TOOLCHAIN" \
    -DOHOS_ARCH="$OHOS_ARCH" \
    -DOHOS_PLATFORM=OHOS \
    -DCMAKE_BUILD_TYPE=Release

# ================================================================
# 4. Build
# ================================================================
LOG_DIR=$ROOT/logs
mkdir -p "$LOG_DIR"
TS=$(date +%Y%m%d_%H%M%S)
BUILD_LOG="$LOG_DIR/abitest_build_${TS}.log"

echo "==> building (log: $BUILD_LOG)"

set +e
"$OHOS_NINJA" -j"$(nproc)" 2>&1 | tee "$BUILD_LOG"
NINJA_RC=${PIPESTATUS[0]}
set -e

if [ "$NINJA_RC" -ne 0 ]; then
    echo "============================================================"
    echo "  build failed (ninja exit=$NINJA_RC)"
    echo "  log: $BUILD_LOG"
    echo "============================================================"
    grep -nE 'error:|FAILED:' "$BUILD_LOG" | head -50 || true
    exit 1
fi

# ================================================================
# 5. Output & inspect
# ================================================================
mkdir -p "$OUT"
cp "$BUILD/abitest" "$OUT/abitest"
chmod +x "$OUT/abitest"

LLVM_BIN="$OHOS_SDK/native/llvm/bin"

echo ""
echo "============================================================"
echo "  abitest built"
echo "  output: $OUT/abitest"
ls -lh "$OUT/abitest"

if [ -x "$LLVM_BIN/llvm-readelf" ]; then
    echo ""
    echo "  ELF info:"
    "$LLVM_BIN/llvm-readelf" -h "$OUT/abitest" \
        | grep -E 'Class|Machine|Type' | sed 's/^/    /' || true
    echo ""
    echo "  dynamic deps:"
    "$LLVM_BIN/llvm-readelf" -d "$OUT/abitest" \
        | grep -E 'NEEDED|SONAME|RUNPATH|RPATH' | sed 's/^/    /' || true
fi
echo "============================================================"

# ================================================================
# 6. HNP packaging
# ================================================================
if [ "${SKIP_HNP:-0}" = "1" ]; then
    echo "SKIP_HNP=1, skipping HNP packaging"
else
    echo ""
    echo "==> HNP packaging: ${HNP_NAME} v${HNP_VERSION}"

    rm -rf "$HNP_STAGING"
    mkdir -p "$HNP_STAGING/bin"
    cp "$OUT/abitest" "$HNP_STAGING/bin/abitest"
    chmod +x "$HNP_STAGING/bin/abitest"

    cat > "$HNP_STAGING/hnp.json" << EOF_HNP
{
    "type": "hnp-config",
    "name": "${HNP_NAME}",
    "version": "${HNP_VERSION}",
    "install": {
        "links": [
            {
                "source": "./bin/abitest",
                "target": "abitest"
            }
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
            echo "ERROR: neither hnpcli nor zip available"
            exit 1
        fi
        # 显式列出 bin 和 hnp.json,避免 'zip -r .' 产生 ./ 前缀
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

            # 校验 bin/abitest 条目存在且无 ./ 前缀
            if unzip -l "$HNP_FILE" | awk '{print $NF}' | grep -Fxq 'bin/abitest'; then
                echo "    [OK] structure verified: bin/abitest"
            else
                echo "    [WARN] 'bin/abitest' entry not found at expected path."
                echo "           Installed binary may end up at wrong location."
            fi
        fi
    else
        echo "ERROR: HNP file not generated"
        exit 1
    fi
fi

END=$(date +%s%N)
SEC=$(( (END-START)/1000000000 ))
MS=$(( ((END-START)/1000000)%1000 ))
echo ""
echo "  done in ${SEC}.${MS}s"