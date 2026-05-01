# ProGuard rules for VPN+TOR application.

# Keep xray-core JNI bindings.
-keep class com.example.vpntor.** { *; }

# Keep Go mobile bindings.
-keep class go.** { *; }

# Keep Flutter engine.
-keep class io.flutter.** { *; }

# Keep VpnService implementation.
-keep class * extends android.net.VpnService { *; }
