# CMakeLists.txt for native library integration.
# This is a placeholder for the hev-socks5-tunnel and Arti native libraries.
# The actual native libraries are built separately and linked as pre-built shared libs.

cmake_minimum_required(VERSION 3.22)
project(vpntor-native)

# hev-socks5-tunnel — pre-built shared library for arm64-v8a.
add_library(hev-socks5-tunnel SHARED IMPORTED)
set_target_properties(hev-socks5-tunnel PROPERTIES
    IMPORTED_LOCATION "${CMAKE_SOURCE_DIR}/../jniLibs/arm64-v8a/libhev-socks5-tunnel.so"
)

# Arti TOR client — pre-built shared library for arm64-v8a.
add_library(arti SHARED IMPORTED)
set_target_properties(arti PROPERTIES
    IMPORTED_LOCATION "${CMAKE_SOURCE_DIR}/../jniLibs/arm64-v8a/libarti.so"
)
