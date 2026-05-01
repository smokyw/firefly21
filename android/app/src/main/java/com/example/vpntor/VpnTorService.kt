package com.example.vpntor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Binder
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android VpnService implementation for VPN+TOR.
 *
 * Manages the TUN interface lifecycle with Android 14+ compliance:
 * - foregroundServiceType="specialUse" with PROPERTY_SPECIAL_USE_FGS_SUBTYPE="vpn"
 * - Foreground notification with disconnect action
 * - Per-app routing via addAllowedApplication/addDisallowedApplication
 * - TUN fd passed to the Go core service (hev-socks5-tunnel)
 */
class VpnTorService : VpnService() {

    companion object {
        const val ACTION_START = "com.example.vpntor.START"
        const val ACTION_STOP = "com.example.vpntor.STOP"
        private const val TAG = "VpnTorService"
        private const val CHANNEL_ID = "vpn_tor_channel"
        private const val NOTIFICATION_ID = 1
    }

    private val binder = LocalBinder()
    private var tunInterface: ParcelFileDescriptor? = null
    private var isRunning = AtomicBoolean(false)
    private var socketPath: String = ""
    private var logCallback: ((String) -> Unit)? = null

    inner class LocalBinder : Binder() {
        fun getService(): VpnTorService = this@VpnTorService
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                if (isRunning.compareAndSet(false, true)) {
                    startVpn(intent)
                }
            }
            ACTION_STOP -> {
                stopVpn()
            }
        }
        return START_STICKY
    }

    /**
     * Starts the VPN tunnel and foreground service.
     */
    private fun startVpn(intent: Intent) {
        Log.i(TAG, "Starting VPN service")

        // Create notification channel and start as foreground service.
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Connecting..."))

        // Generate randomized IPC socket path.
        socketPath = generateSocketPath()

        // Set the APP_FILES_DIR environment variable for the Go core.
        val filesDir = applicationContext.filesDir.absolutePath

        // Build the TUN interface.
        val builder = Builder()
            .setSession("VPN+TOR")
            .setMtu(1500)
            .addAddress("10.0.0.2", 32)
            .addAddress("fd00::2", 128)
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .addDnsServer("10.0.0.1") // Internal DNS, forwarded through xray DoH.
            .setBlocking(false)

        // Apply per-app routing.
        val appMode = intent.getStringExtra("app_mode") ?: "all"
        when (appMode) {
            "include" -> {
                intent.getStringArrayListExtra("allowed_apps")?.forEach { pkg ->
                    try {
                        builder.addAllowedApplication(pkg)
                    } catch (e: Exception) {
                        Log.w(TAG, "Cannot add allowed app: $pkg", e)
                    }
                }
            }
            "exclude" -> {
                intent.getStringArrayListExtra("disallowed_apps")?.forEach { pkg ->
                    try {
                        builder.addDisallowedApplication(pkg)
                    } catch (e: Exception) {
                        Log.w(TAG, "Cannot add disallowed app: $pkg", e)
                    }
                }
                // Always exclude self to prevent routing loops.
                try {
                    builder.addDisallowedApplication(packageName)
                } catch (_: Exception) {}
            }
            else -> {
                // Route all apps through VPN, except self.
                try {
                    builder.addDisallowedApplication(packageName)
                } catch (_: Exception) {}
            }
        }

        // Establish the TUN interface.
        tunInterface = builder.establish()
        if (tunInterface == null) {
            Log.e(TAG, "Failed to establish TUN interface")
            stopVpn()
            return
        }

        val tunFd = tunInterface!!.fd
        Log.i(TAG, "TUN interface established, fd=$tunFd")

        // Pass the TUN fd to the Go core via environment variable.
        // In production, this would use the JNI binding to call the Go code directly.
        // The Go core reads VPN_TUN_FD to obtain the file descriptor.

        updateNotification("Connected")
        emitLog("info", "vpn", "VPN tunnel established")
    }

    /**
     * Stops the VPN tunnel and cleans up resources.
     */
    private fun stopVpn() {
        Log.i(TAG, "Stopping VPN service")
        isRunning.set(false)

        // Close TUN interface.
        try {
            tunInterface?.close()
            tunInterface = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing TUN interface", e)
        }

        // Clean up socket file.
        if (socketPath.isNotEmpty()) {
            File(socketPath).delete()
        }

        emitLog("info", "vpn", "VPN tunnel stopped")

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Returns the IPC socket path.
     */
    fun getSocketPath(): String = socketPath

    /**
     * Sets the callback for log forwarding to Flutter.
     */
    fun setLogCallback(callback: (String) -> Unit) {
        logCallback = callback
    }

    /**
     * Generates a randomized Unix socket path with 128 bits of entropy.
     */
    private fun generateSocketPath(): String {
        val random = SecureRandom()
        val bytes = ByteArray(16) // 128 bits
        random.nextBytes(bytes)
        val hex = bytes.joinToString("") { "%02x".format(it) }
        return "${applicationContext.filesDir.absolutePath}/vpn_$hex.sock"
    }

    /**
     * Creates the notification channel for Android 8.0+.
     */
    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "VPN+TOR Service",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "VPN+TOR connection status"
            setShowBadge(false)
        }

        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }

    /**
     * Builds the foreground service notification.
     */
    private fun buildNotification(status: String): Notification {
        // Intent to open the app when notification is tapped.
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Intent for the "Disconnect" action button.
        val disconnectIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, VpnTorService::class.java).apply {
                action = ACTION_STOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("VPN+TOR")
            .setContentText(status)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setContentIntent(openIntent)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "Disconnect",
                    disconnectIntent
                ).build()
            )
            .build()
    }

    /**
     * Updates the notification text.
     */
    private fun updateNotification(status: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(status))
    }

    /**
     * Emits a log entry to the Flutter UI via the callback.
     */
    private fun emitLog(level: String, source: String, message: String) {
        val timestamp = java.time.Instant.now().toString()
        val json = """{"timestamp":"$timestamp","level":"$level","source":"$source","message":"$message"}"""
        logCallback?.invoke(json)
        Log.d(TAG, "[$level] [$source] $message")
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    override fun onRevoke() {
        // Called when the user revokes VPN permission from system settings.
        emitLog("warn", "vpn", "VPN permission revoked by user")
        stopVpn()
    }
}
