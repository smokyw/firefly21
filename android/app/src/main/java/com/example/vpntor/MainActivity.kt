package com.example.vpntor

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.VpnService
import android.os.IBinder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Main activity for VPN+TOR application.
 *
 * Handles Flutter platform channels for:
 * - VPN service lifecycle (prepare, start, stop)
 * - Installed apps listing for per-app routing
 * - Log streaming via EventChannel
 * - IPC socket path communication
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val VPN_CHANNEL = "com.example.vpntor/vpn"
        private const val APPS_CHANNEL = "com.example.vpntor/apps"
        private const val LOG_CHANNEL = "com.example.vpntor/logs"
        private const val VPN_PREPARE_REQUEST = 100
    }

    private var vpnService: VpnTorService? = null
    private var serviceBound = false
    private var pendingResult: MethodChannel.Result? = null
    private var logEventSink: EventChannel.EventSink? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as? VpnTorService.LocalBinder
            vpnService = binder?.getService()
            serviceBound = true

            // Set up log forwarding from the service to Flutter.
            vpnService?.setLogCallback { logJson ->
                activity.runOnUiThread {
                    logEventSink?.success(logJson)
                }
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            vpnService = null
            serviceBound = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // VPN control channel.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "prepareVpn" -> prepareVpn(result)
                "startVpn" -> startVpn(call.arguments as? Map<*, *>, result)
                "stopVpn" -> stopVpn(result)
                "getSocketPath" -> getSocketPath(result)
                else -> result.notImplemented()
            }
        }

        // Installed apps channel.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APPS_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstalledApps" -> getInstalledApps(result)
                else -> result.notImplemented()
            }
        }

        // Log streaming event channel.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LOG_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    logEventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    logEventSink = null
                }
            }
        )
    }

    /**
     * Requests VPN permission from the system.
     * Shows the system VPN consent dialog if not already granted.
     */
    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            pendingResult = result
            startActivityForResult(intent, VPN_PREPARE_REQUEST)
        } else {
            // VPN permission already granted.
            result.success(true)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PREPARE_REQUEST) {
            pendingResult?.success(resultCode == Activity.RESULT_OK)
            pendingResult = null
        }
    }

    /**
     * Starts the VPN foreground service.
     */
    private fun startVpn(params: Map<*, *>?, result: MethodChannel.Result) {
        try {
            val intent = Intent(this, VpnTorService::class.java).apply {
                action = VpnTorService.ACTION_START

                params?.let {
                    putExtra("config_url", it["config_url"] as? String ?: "")
                    putExtra("app_mode", it["app_mode"] as? String ?: "all")

                    @Suppress("UNCHECKED_CAST")
                    val allowedApps = it["allowed_apps"] as? List<String>
                    if (allowedApps != null) {
                        putStringArrayListExtra("allowed_apps", ArrayList(allowedApps))
                    }

                    @Suppress("UNCHECKED_CAST")
                    val disallowedApps = it["disallowed_apps"] as? List<String>
                    if (disallowedApps != null) {
                        putStringArrayListExtra("disallowed_apps", ArrayList(disallowedApps))
                    }
                }
            }

            startForegroundService(intent)

            // Bind to the service for log forwarding and status queries.
            bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)

            result.success(true)
        } catch (e: Exception) {
            result.error("VPN_START_ERROR", e.message, null)
        }
    }

    /**
     * Stops the VPN service.
     */
    private fun stopVpn(result: MethodChannel.Result) {
        try {
            if (serviceBound) {
                unbindService(serviceConnection)
                serviceBound = false
            }

            val intent = Intent(this, VpnTorService::class.java).apply {
                action = VpnTorService.ACTION_STOP
            }
            startService(intent)

            vpnService = null
            result.success(true)
        } catch (e: Exception) {
            result.error("VPN_STOP_ERROR", e.message, null)
        }
    }

    /**
     * Returns the IPC Unix socket path for the Go core service.
     */
    private fun getSocketPath(result: MethodChannel.Result) {
        val socketPath = vpnService?.getSocketPath() ?: ""
        result.success(socketPath)
    }

    /**
     * Returns the list of installed apps for per-app routing.
     * Each entry includes: packageName, label, icon (as PNG bytes).
     */
    private fun getInstalledApps(result: MethodChannel.Result) {
        Thread {
            try {
                val pm = packageManager
                val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
                    .filter { app ->
                        // Include user apps and selected system apps.
                        (app.flags and ApplicationInfo.FLAG_SYSTEM) == 0 ||
                        (app.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
                    }
                    .map { app ->
                        val label = pm.getApplicationLabel(app).toString()
                        val iconBytes = try {
                            val drawable = pm.getApplicationIcon(app)
                            val bitmap = if (drawable is BitmapDrawable) {
                                drawable.bitmap
                            } else {
                                val bmp = Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888)
                                val canvas = Canvas(bmp)
                                drawable.setBounds(0, 0, 48, 48)
                                drawable.draw(canvas)
                                bmp
                            }
                            val stream = ByteArrayOutputStream()
                            bitmap.compress(Bitmap.CompressFormat.PNG, 80, stream)
                            stream.toByteArray()
                        } catch (e: Exception) {
                            null
                        }

                        mapOf(
                            "packageName" to app.packageName,
                            "label" to label,
                            "icon" to iconBytes
                        )
                    }

                activity.runOnUiThread {
                    result.success(apps)
                }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    result.error("APPS_ERROR", e.message, null)
                }
            }
        }.start()
    }

    override fun onDestroy() {
        if (serviceBound) {
            unbindService(serviceConnection)
            serviceBound = false
        }
        super.onDestroy()
    }
}
