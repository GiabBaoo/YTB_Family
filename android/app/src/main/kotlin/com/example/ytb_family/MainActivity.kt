package com.example.ytb_family

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Method
import java.net.InetAddress

class MainActivity : AudioServiceActivity() {
    companion object {
        private const val LIFECYCLE_CHANNEL = "com.example.ytb_family/lifecycle"
        private const val REQ_POST_NOTIFICATIONS = 1001
        private const val WAKE_LOCK_TIMEOUT_MS = 60L * 60L * 1000L
        private const val WAKE_LOCK_RENEW_INTERVAL_MS = 45L * 60L * 1000L
        private const val PERIODIC_KEEP_ACTIVE_MS = 5000L
        private val KEEP_ACTIVE_DELAYS_MS = longArrayOf(0L, 100L, 300L, 700L, 1500L, 3000L)
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scheduledRunnables = mutableListOf<Runnable>()
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var isInBackground = false
    private var isMediaPlaying = false
    private var lastWakeLockAcquireAt = 0L

    private val windowVisibilityMethod: Method? by lazy {
        try {
            View::class.java.getDeclaredMethod(
                "onWindowVisibilityChanged",
                Int::class.javaPrimitiveType
            ).apply {
                isAccessible = true
            }
        } catch (_: Exception) {
            null
        }
    }

    private val periodicKeepActiveRunnable = object : Runnable {
        override fun run() {
            if (!isInBackground || !isMediaPlaying) return
            keepWebViewsActive(injectBgJs = false)
            if (System.currentTimeMillis() - lastWakeLockAcquireAt >= WAKE_LOCK_RENEW_INTERVAL_MS) {
                renewWakeLock()
            }
            mainHandler.postDelayed(this, PERIODIC_KEEP_ACTIVE_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableHighRefreshRate()
        prewarmYoutubeDns()
    }

    private fun prewarmYoutubeDns() {
        Thread {
            for (host in listOf(
                "m.youtube.com",
                "www.youtube.com",
                "i.ytimg.com",
                "s.ytimg.com",
                "googlevideo.com"
            )) {
                try {
                    InetAddress.getByName(host)
                } catch (_: Exception) {}
            }
        }.apply {
            isDaemon = true
            start()
        }
    }

    private fun enableHighRefreshRate() {
        try {
            val currentDisplay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display ?: @Suppress("DEPRECATION") windowManager.defaultDisplay
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay
            } ?: return

            val currentMode = currentDisplay.mode ?: return
            val bestMode = currentDisplay.supportedModes
                .filter {
                    it.physicalWidth == currentMode.physicalWidth &&
                        it.physicalHeight == currentMode.physicalHeight
                }
                .maxByOrNull { it.refreshRate }
                ?: currentDisplay.supportedModes.maxByOrNull { it.refreshRate }
                ?: return
            if (bestMode.refreshRate > currentMode.refreshRate) {
                window.attributes = window.attributes.apply {
                    preferredDisplayModeId = bestMode.modeId
                }
            }
        } catch (_: Exception) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LIFECYCLE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveTaskToBack" -> result.success(moveTaskToBack(true))
                    "requestNotificationPermission" -> {
                        requestNotificationPermissionIfNeeded()
                        result.success(null)
                    }
                    "setMediaPlaying" -> {
                        isMediaPlaying = call.arguments as? Boolean ?: false
                        if (isInBackground) {
                            if (isMediaPlaying) {
                                acquireLocks()
                                startPeriodicKeepActive()
                            } else {
                                stopPeriodicKeepActive()
                                releaseLocks()
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    REQ_POST_NOTIFICATIONS
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        isInBackground = false
        cancelKeepActiveCallbacks()
        releaseLocks()
    }

    override fun onPause() {
        super.onPause()
        isInBackground = true
        if (isMediaPlaying) {
            scheduleKeepWebViewsActive()
        } else {
            cancelKeepActiveCallbacks()
        }
    }

    override fun onStop() {
        super.onStop()
        isInBackground = true
        if (isMediaPlaying) {
            acquireLocks()
            scheduleKeepWebViewsActive()
        } else {
            cancelKeepActiveCallbacks()
        }
    }

    override fun onDestroy() {
        cancelKeepActiveCallbacks()
        releaseLocks()
        super.onDestroy()
    }

    private fun cancelKeepActiveCallbacks() {
        for (r in scheduledRunnables) {
            mainHandler.removeCallbacks(r)
        }
        scheduledRunnables.clear()
        stopPeriodicKeepActive()
    }

    private fun startPeriodicKeepActive() {
        mainHandler.removeCallbacks(periodicKeepActiveRunnable)
        mainHandler.postDelayed(periodicKeepActiveRunnable, PERIODIC_KEEP_ACTIVE_MS)
    }

    private fun stopPeriodicKeepActive() {
        mainHandler.removeCallbacks(periodicKeepActiveRunnable)
    }

    private fun scheduleKeepWebViewsActive() {
        cancelKeepActiveCallbacks()
        if (!isMediaPlaying) return
        for (delay in KEEP_ACTIVE_DELAYS_MS) {
            val r = Runnable { keepWebViewsActive(injectBgJs = delay == 0L) }
            scheduledRunnables.add(r)
            if (delay == 0L) {
                keepWebViewsActive(injectBgJs = true)
            } else {
                mainHandler.postDelayed(r, delay)
            }
        }
        startPeriodicKeepActive()
    }

    private fun acquireLocks() {
        acquireWakeLock()
        acquireWifiLock()
    }

    private fun releaseLocks() {
        releaseWakeLock()
        releaseWifiLock()
    }

    private fun acquireWakeLock() {
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        if (wakeLock == null) {
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "ytb_family:AudioWakeLock"
            ).apply {
                setReferenceCounted(false)
            }
        }
        try {
            if (wakeLock?.isHeld == false) {
                wakeLock?.acquire(WAKE_LOCK_TIMEOUT_MS)
                lastWakeLockAcquireAt = System.currentTimeMillis()
            }
        } catch (_: SecurityException) {}
    }

    private fun renewWakeLock() {
        try {
            wakeLock?.acquire(WAKE_LOCK_TIMEOUT_MS)
            lastWakeLockAcquireAt = System.currentTimeMillis()
        } catch (_: SecurityException) {}
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: RuntimeException) {}
    }

    private fun acquireWifiLock() {
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        if (wifiLock == null) {
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wm.createWifiLock(mode, "ytb_family:AudioWifiLock").apply {
                setReferenceCounted(false)
            }
        }
        try {
            if (wifiLock?.isHeld == false) {
                wifiLock?.acquire()
            }
        } catch (_: SecurityException) {}
    }

    private fun releaseWifiLock() {
        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        } catch (_: RuntimeException) {}
    }

    private fun keepWebViewsActive(injectBgJs: Boolean) {
        val rootView = window?.decorView ?: return
        traverseAndResumeWebViews(rootView, injectBgJs)
    }

    private fun traverseAndResumeWebViews(view: View, injectBgJs: Boolean) {
        if (view is WebView) {
            try {
                windowVisibilityMethod?.invoke(view, View.VISIBLE)
            } catch (_: Exception) {}
            if (view.visibility != View.VISIBLE) {
                view.visibility = View.VISIBLE
            }
            view.onResume()
            view.resumeTimers()
            if (injectBgJs) {
                view.evaluateJavascript(
                    "window.__ytbSetBackground && window.__ytbSetBackground(true);",
                    null
                )
            }
            return
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                traverseAndResumeWebViews(view.getChildAt(i), injectBgJs)
            }
        }
    }
}
