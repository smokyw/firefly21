#!/usr/bin/env bash
# strip_debug.sh — Strip debug symbols from native libraries before release.
#
# This reduces APK size significantly by removing debug information
# from the compiled native libraries (Go, Rust, C).
#
# Usage: ./scripts/strip_debug.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
JNI_DIR="$PROJECT_ROOT/android/app/src/main/jniLibs/arm64-v8a"

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    ANDROID_NDK_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/27.2.12479018"
fi

STRIP="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"

if [ ! -f "$STRIP" ]; then
    echo "ERROR: llvm-strip not found at $STRIP"
    echo "Ensure Android NDK r27d is installed."
    exit 1
fi

echo "=== Stripping debug symbols ==="
echo "NDK strip: $STRIP"
echo "Target dir: $JNI_DIR"
echo ""

if [ ! -d "$JNI_DIR" ]; then
    echo "WARNING: JNI directory not found. Run build_android.sh first."
    exit 0
fi

TOTAL_BEFORE=0
TOTAL_AFTER=0

for lib in "$JNI_DIR"/*.so; do
    if [ -f "$lib" ]; then
        BEFORE=$(stat -c%s "$lib")
        TOTAL_BEFORE=$((TOTAL_BEFORE + BEFORE))

        "$STRIP" --strip-debug --strip-unneeded "$lib"

        AFTER=$(stat -c%s "$lib")
        TOTAL_AFTER=$((TOTAL_AFTER + AFTER))

        SAVED=$((BEFORE - AFTER))
        echo "  $(basename "$lib"): $(numfmt --to=iec $BEFORE) -> $(numfmt --to=iec $AFTER) (saved $(numfmt --to=iec $SAVED))"
    fi
done

echo ""
TOTAL_SAVED=$((TOTAL_BEFORE - TOTAL_AFTER))
echo "Total: $(numfmt --to=iec $TOTAL_BEFORE) -> $(numfmt --to=iec $TOTAL_AFTER) (saved $(numfmt --to=iec $TOTAL_SAVED))"
echo "=== Done ==="
