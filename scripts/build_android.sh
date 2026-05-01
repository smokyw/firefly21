#!/usr/bin/env bash
# build_android.sh — Automated build script for VPN+TOR Android (arm64-v8a).
#
# Prerequisites:
#   - Android NDK r27d installed ($ANDROID_NDK_HOME)
#   - Go 1.22+ installed
#   - Rust toolchain with aarch64-linux-android target
#   - Flutter 3.24+ installed
#   - cargo-ndk installed (cargo install cargo-ndk)
#
# Usage: ./scripts/build_android.sh [--release]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_MODE="${1:-debug}"

echo "=== VPN+TOR Android Build ==="
echo "Project root: $PROJECT_ROOT"
echo "Build mode: $BUILD_MODE"
echo ""

# Validate environment.
check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: $1 is not installed or not in PATH."
        exit 1
    fi
}

check_tool go
check_tool cargo
check_tool flutter

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "WARNING: ANDROID_NDK_HOME is not set. Using default NDK path."
    ANDROID_NDK_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/27.2.12479018"
fi

if [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo "ERROR: Android NDK not found at $ANDROID_NDK_HOME"
    echo "Install NDK r27d: sdkmanager --install 'ndk;27.2.12479018'"
    exit 1
fi

echo "NDK: $ANDROID_NDK_HOME"
echo ""

# Output directory for native libraries.
JNI_DIR="$PROJECT_ROOT/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$JNI_DIR"

# ------------------------------------------------------------------
# Step 1: Build Go core with gomobile (xray-core + VPN service logic)
# ------------------------------------------------------------------
echo "--- Step 1: Building Go core for arm64-v8a ---"
cd "$PROJECT_ROOT/core"

# Set up Go environment for Android cross-compilation.
export CGO_ENABLED=1
export GOOS=android
export GOARCH=arm64
export CC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang"
export CXX="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang++"

# Build the Go core as a shared library for Android.
go build -buildmode=c-shared \
    -ldflags="-s -w" \
    -o "$JNI_DIR/libvpncore.so" \
    .

echo "Go core built: $JNI_DIR/libvpncore.so"
echo ""

# ------------------------------------------------------------------
# Step 2: Build Arti (Rust) for arm64-v8a
# ------------------------------------------------------------------
echo "--- Step 2: Building Arti TOR client for arm64-v8a ---"
cd "$PROJECT_ROOT/rust_arti"

# Add the Android arm64 target if not already present.
rustup target add aarch64-linux-android 2>/dev/null || true

# Build with cargo-ndk.
cargo ndk -t arm64-v8a build --release

# Copy the built library to the JNI directory.
ARTI_LIB="target/aarch64-linux-android/release/libvpntor_arti.so"
if [ -f "$ARTI_LIB" ]; then
    cp "$ARTI_LIB" "$JNI_DIR/libarti.so"
    echo "Arti built: $JNI_DIR/libarti.so"
else
    echo "WARNING: Arti library not found at expected path."
    echo "Expected: $ARTI_LIB"
fi
echo ""

# ------------------------------------------------------------------
# Step 3: Build hev-socks5-tunnel for arm64-v8a
# ------------------------------------------------------------------
echo "--- Step 3: Building hev-socks5-tunnel for arm64-v8a ---"

HEV_DIR="$PROJECT_ROOT/third_party/hev-socks5-tunnel"
if [ -d "$HEV_DIR" ]; then
    cd "$HEV_DIR"

    # Build with Android NDK.
    make clean 2>/dev/null || true
    make \
        CROSS_PREFIX="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-" \
        CFLAGS="-O2 -fPIC" \
        -j"$(nproc)"

    if [ -f "bin/hev-socks5-tunnel" ]; then
        cp "bin/hev-socks5-tunnel" "$JNI_DIR/libhev-socks5-tunnel.so"
        echo "hev-socks5-tunnel built: $JNI_DIR/libhev-socks5-tunnel.so"
    fi
else
    echo "WARNING: hev-socks5-tunnel source not found at $HEV_DIR"
    echo "Clone it: git clone https://github.com/heiher/hev-socks5-tunnel.git $HEV_DIR"
fi
echo ""

# ------------------------------------------------------------------
# Step 4: Build Flutter APK
# ------------------------------------------------------------------
echo "--- Step 4: Building Flutter APK ---"
cd "$PROJECT_ROOT/flutter_app"

flutter pub get

if [ "$BUILD_MODE" = "--release" ]; then
    flutter build apk --release --target-platform android-arm64
    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
else
    flutter build apk --debug --target-platform android-arm64
    APK_PATH="build/app/outputs/flutter-apk/app-debug.apk"
fi

echo ""
echo "=== Build Complete ==="
echo "APK: $APK_PATH"
echo ""
echo "To install: adb install $APK_PATH"
