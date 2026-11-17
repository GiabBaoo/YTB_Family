package com.example.ytb_family

import android.Manifest
import android.accounts.AccountManager
import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.media.AudioManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.util.Rational
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Method
import java.net.InetAddress

class MainActivity : AudioServiceActivity() {
    companion object {
        private const val TAG = "YtbFamily"
        private const val LIFECYCLE_CHANNEL = "com.example.ytb_family/lifecycle"
        private const val ACTION_PIP_CONTROL = "com.example.ytb_family.PIP_CONTROL"
        private const val EXTRA_PIP_ACTION = "pip_action"
        private const val PIP_ACTION_PLAY_PAUSE = "play_pause"
        private const val PIP_ACTION_NEXT = "next"
        private const val REQ_POST_NOTIFICATIONS = 1001
        private const val REQ_CHOOSE_ACCOUNT = 1002
        private const val PREFS_NAME = "ytb_family_prefs"
        private const val KEY_SAMSUNG_SLEEP_SHOWN = "samsung_sleep_guide_shown"
        private const val KEY_SELECTED_CHANNEL = "selected_youtube_channel"
        private const val WAKE_LOCK_TIMEOUT_MS = 60L * 60L * 1000L
        private const val WAKE_LOCK_RENEW_INTERVAL_MS = 45L * 60L * 1000L
        private const val PERIODIC_KEEP_ACTIVE_MS = 10000L
        private val KEEP_ACTIVE_DELAYS_MS = longArrayOf(0L, 100L, 300L, 700L, 1500L, 3000L)
        private val YOUTUBE_URL_REGEX =
            Regex("""https?://(?:(?:www|m|music)\.)?(?:youtube\.com|youtu\.be)/[^\s<>"]+""")
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scheduledRunnables = mutableListOf<Runnable>()
    private var lifecycleChannel: MethodChannel? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var isInBackground = false
    private var isMediaPlaying = false
    private var isWatchPage = false
    private var pipWidth = 16
    private var pipHeight = 9
    private var lastWakeLockAcquireAt = 0L
    private var pausedByCall = false
    private var pendingDeepLink: String? = null
    private var pendingAccountResult: MethodChannel.Result? = null
    private var receiversRegistered = false

    private val audioManager: AudioManager? by lazy {
        getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    }

    private var modeChangedListener: Any? = null

    private val noisyAndPipReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                AudioManager.ACTION_AUDIO_BECOMING_NOISY -> {
                    dispatchJs("window.__ytbSystemPause && window.__ytbSystemPause('noisy', false);")
                    lifecycleChannel?.invokeMethod("onSystemPause", "noisy")
                }
                ACTION_PIP_CONTROL -> {
                    when (intent.getStringExtra(EXTRA_PIP_ACTION)) {
                        PIP_ACTION_PLAY_PAUSE -> {
                            val cmd = if (isMediaPlaying) "pause" else "play"
                            dispatchJs("window.__ytbControl && window.__ytbControl('$cmd');")
                        }
                        PIP_ACTION_NEXT -> {
                            dispatchJs("window.__ytbControl && window.__ytbControl('next');")
                        }
                    }
                }
            }
        }
    }

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
            if (!isInBackground || !isMediaPlaying || isInCallMode()) return
            keepWebViewsActive(injectBgJs = false)
            if (System.currentTimeMillis() - lastWakeLockAcquireAt >= WAKE_LOCK_RENEW_INTERVAL_MS) {
                renewWakeLock()
            }
            mainHandler.postDelayed(this, PERIODIC_KEEP_ACTIVE_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingDeepLink = extractYoutubeUrl(intent)
        enableHighRefreshRate()
        prewarmYoutubeDns()
        registerSystemReceivers()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val url = extractYoutubeUrl(intent)
        if (url != null) {
            if (lifecycleChannel != null) {
                lifecycleChannel?.invokeMethod("onDeepLink", url)
            } else {
                pendingDeepLink = url
            }
        }
    }

    private fun extractYoutubeUrl(intent: Intent?): String? {
        if (intent == null) return null
        val raw = when (intent.action) {
            Intent.ACTION_VIEW -> intent.dataString
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return null
                YOUTUBE_URL_REGEX.find(text)?.value
            }
            else -> null
        } ?: return null
        return normalizeYoutubeUrl(raw)
    }

    private fun normalizeYoutubeUrl(raw: String): String? {
        val uri = try {
            Uri.parse(raw)
        } catch (_: Exception) {
            return null
        }
        val host = uri.host?.lowercase() ?: return null
        return when {
            host == "youtu.be" -> {
                val id = uri.pathSegments.firstOrNull() ?: return null
                val t = uri.getQueryParameter("t")
                val base = "https://m.youtube.com/watch?v=$id"
                if (t != null) "$base&t=$t" else base
            }
            host == "youtube.com" || host == "www.youtube.com" ||
                host == "m.youtube.com" || host == "music.youtube.com" -> {
                uri.buildUpon().scheme("https").authority("m.youtube.com").build().toString()
            }
            else -> null
        }
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    private fun registerSystemReceivers() {
        if (receiversRegistered) return
        val filter = IntentFilter().apply {
            addAction(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            addAction(ACTION_PIP_CONTROL)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(noisyAndPipReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(noisyAndPipReceiver, filter)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val listener = AudioManager.OnModeChangedListener { mode ->
                handleAudioModeChange(mode)
            }
            modeChangedListener = listener
            audioManager?.addOnModeChangedListener(mainExecutor, listener)
        }
        receiversRegistered = true
    }

    private fun unregisterSystemReceivers() {
        if (!receiversRegistered) return
        try {
            unregisterReceiver(noisyAndPipReceiver)
        } catch (_: Exception) {}
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val listener = modeChangedListener as? AudioManager.OnModeChangedListener
            if (listener != null) {
                try {
                    audioManager?.removeOnModeChangedListener(listener)
                } catch (_: Exception) {}
            }
            modeChangedListener = null
        }
        receiversRegistered = false
    }

    private fun isInCallMode(mode: Int = audioManager?.mode ?: AudioManager.MODE_NORMAL): Boolean {
        return mode == AudioManager.MODE_RINGTONE ||
            mode == AudioManager.MODE_IN_CALL ||
            mode == AudioManager.MODE_IN_COMMUNICATION
    }

    private fun handleAudioModeChange(mode: Int) {
        if (isInCallMode(mode)) {
            if (isMediaPlaying && !pausedByCall) {
                pausedByCall = true
                dispatchJs("window.__ytbSystemPause && window.__ytbSystemPause('call', true);")
                lifecycleChannel?.invokeMethod("onSystemPause", "call")
            }
        } else if (mode == AudioManager.MODE_NORMAL && pausedByCall) {
            pausedByCall = false
            dispatchJs("window.__ytbSystemResume && window.__ytbSystemResume('call');")
        }
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
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LIFECYCLE_CHANNEL)
        lifecycleChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "moveTaskToBack" -> result.success(moveTaskToBack(true))
                "getDefaultUserAgent" -> {
                    val ua = try {
                        WebSettings.getDefaultUserAgent(this)
                            .replace("; wv)", ")")
                            .replace("; wv;", ";")
                    } catch (_: Exception) {
                        null
                    }
                    result.success(ua)
                }
                "getInitialLink" -> {
                    val link = pendingDeepLink
                    pendingDeepLink = null
                    result.success(link)
                }
                "openExternalUrl" -> {
                    val url = call.arguments as? String
                    result.success(openExternalUrl(url))
                }
                "isOtherAudioActive" -> {
                    val am = audioManager
                    val active = am != null && (isInCallMode(am.mode) || am.isMusicActive)
                    result.success(active)
                }
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermissionIfNeeded()
                    result.success(null)
                }
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(null)
                }
                "logError" -> {
                    Log.e(TAG, call.arguments?.toString() ?: "Unknown error")
                    result.success(null)
                }
                "isSamsungDevice" -> {
                    result.success(Build.MANUFACTURER.equals("samsung", ignoreCase = true))
                }
                "hasShownSamsungSleepGuide" -> {
                    val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    result.success(prefs.getBoolean(KEY_SAMSUNG_SLEEP_SHOWN, false))
                }
                "markSamsungSleepGuideShown" -> {
                    getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                        .edit()
                        .putBoolean(KEY_SAMSUNG_SLEEP_SHOWN, true)
                        .apply()
                    result.success(null)
                }
                "openBatteryBackgroundSettings" -> {
                    openBatteryBackgroundSettings()
                    result.success(null)
                }
                "chooseGoogleAccount" -> {
                    chooseGoogleAccount(result)
                }
                "configureWebViewFeatures" -> {
                    configureWebViewFeatures()
                    result.success(null)
                }
                "flushCookies" -> {
                    try {
                        CookieManager.getInstance().flush()
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "getSelectedChannel" -> {
                    val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    result.success(prefs.getString(KEY_SELECTED_CHANNEL, null))
                }
                "setSelectedChannel" -> {
                    val channelName = call.arguments as? String
                    val editor = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                    if (channelName.isNullOrBlank()) {
                        editor.remove(KEY_SELECTED_CHANNEL)
                    } else {
                        editor.putString(KEY_SELECTED_CHANNEL, channelName)
                    }
                    editor.apply()
                    result.success(null)
                }
                "setMediaPlaying" -> {
                    isMediaPlaying = call.arguments as? Boolean ?: false
                    if (isMediaPlaying) {
                        pausedByCall = false
                    }
                    updatePipParams()
                    if (isInBackground) {
                        if (isMediaPlaying && !isInCallMode()) {
                            acquireLocks()
                            startPeriodicKeepActive()
                        } else {
                            stopPeriodicKeepActive()
                            releaseLocks()
                        }
                    }
                    result.success(null)
                }
                "setWatchState" -> {
                    val args = call.arguments as? Map<*, *>
                    isWatchPage = args?.get("isWatchPage") as? Boolean ?: false
                    val w = (args?.get("width") as? Number)?.toInt() ?: 16
                    val h = (args?.get("height") as? Number)?.toInt() ?: 9
                    if (w > 0 && h > 0) {
                        pipWidth = w
                        pipHeight = h
                    }
                    updatePipParams()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun openExternalUrl(url: String?): Boolean {
        if (url.isNullOrBlank()) return false
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    @SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || isIgnoringBatteryOptimizations()) return
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {}
        }
    }

    private fun buildPipParams(): PictureInPictureParams? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val ratio = Rational(pipWidth, pipHeight).let {
            val value = it.toFloat()
            when {
                value < 0.42f -> Rational(42, 100)
                value > 2.39f -> Rational(239, 100)
                else -> it
            }
        }
        val playPauseIntent = PendingIntent.getBroadcast(
            this,
            1,
            Intent(ACTION_PIP_CONTROL).setPackage(packageName)
                .putExtra(EXTRA_PIP_ACTION, PIP_ACTION_PLAY_PAUSE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val nextIntent = PendingIntent.getBroadcast(
            this,
            2,
            Intent(ACTION_PIP_CONTROL).setPackage(packageName)
                .putExtra(EXTRA_PIP_ACTION, PIP_ACTION_NEXT),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val playPauseIcon = Icon.createWithResource(
            this,
            if (isMediaPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        )
        val nextIcon = Icon.createWithResource(this, android.R.drawable.ic_media_next)
        val actions = listOf(
            RemoteAction(
                playPauseIcon,
                if (isMediaPlaying) "Tạm dừng" else "Phát",
                if (isMediaPlaying) "Tạm dừng" else "Phát",
                playPauseIntent
            ),
            RemoteAction(nextIcon, "Tiếp theo", "Tiếp theo", nextIntent)
        )
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(ratio)
            .setActions(actions)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(isMediaPlaying && isWatchPage && !isInCallMode())
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                buildPipParams()?.let { setPictureInPictureParams(it) }
            } catch (_: Exception) {}
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            isMediaPlaying &&
            isWatchPage &&
            !isInCallMode()
        ) {
            lifecycleChannel?.invokeMethod("onPipChanged", true)
            dispatchJs("window.__ytbSetPip && window.__ytbSetPip(true);")
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                try {
                    buildPipParams()?.let { enterPictureInPictureMode(it) }
                } catch (_: Exception) {}
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        lifecycleChannel?.invokeMethod("onPipChanged", isInPictureInPictureMode)
        dispatchJs("window.__ytbSetPip && window.__ytbSetPip($isInPictureInPictureMode);")
        if (isInPictureInPictureMode) {
            keepWebViewsActive(injectBgJs = false)
        } else if (!isInBackground) {
            dispatchJs("window.__ytbSetBackground && window.__ytbSetBackground(false);")
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_POST_NOTIFICATIONS) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                lifecycleChannel?.invokeMethod("onNotificationPermissionDenied", null)
            }
        }
    }

    private fun openNotificationSettings() {
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                }
            } else {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
            }
            startActivity(intent)
        } catch (_: Exception) {
            try {
                startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                )
            } catch (_: Exception) {}
        }
    }

    private fun openBatteryBackgroundSettings() {
        val candidates = listOf(
            Intent().setClassName(
                "com.samsung.android.lool",
                "com.samsung.android.sm.battery.ui.BatteryActivity"
            ),
            Intent().setClassName(
                "com.samsung.android.sm",
                "com.samsung.android.sm.battery.ui.BatteryActivity"
            ),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            }
        )
        for (intent in candidates) {
            try {
                startActivity(intent)
                return
            } catch (_: Exception) {}
        }
    }

    private fun chooseGoogleAccount(result: MethodChannel.Result) {
        if (pendingAccountResult != null) {
            result.success(null)
            return
        }
        pendingAccountResult = result
        try {
            val intent = AccountManager.newChooseAccountIntent(
                null,
                null,
                arrayOf("com.google"),
                null,
                null,
                null,
                null
            )
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_CHOOSE_ACCOUNT)
        } catch (e: Exception) {
            Log.e(TAG, "chooseGoogleAccount failed", e)
            pendingAccountResult?.success(null)
            pendingAccountResult = null
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_CHOOSE_ACCOUNT) {
            val email = if (resultCode == Activity.RESULT_OK) {
                data?.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
            } else {
                null
            }
            pendingAccountResult?.success(email)
            pendingAccountResult = null
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun configureWebViewFeatures() {
        val rootView = window?.decorView ?: return
        configureWebViewFeaturesInTree(rootView)
    }

    private fun configureWebViewFeaturesInTree(view: View) {
        if (view is WebView) {
            try {
                if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_AUTHENTICATION)) {
                    WebSettingsCompat.setWebAuthenticationSupport(
                        view.settings,
                        WebSettingsCompat.WEB_AUTHENTICATION_SUPPORT_FOR_APP
                    )
                }
            } catch (e: Exception) {
                Log.w(TAG, "setWebAuthenticationSupport failed", e)
            }
            return
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                configureWebViewFeaturesInTree(view.getChildAt(i))
            }
        }
    }

    private fun flushCookiesSafe() {
        try {
            CookieManager.getInstance().flush()
        } catch (_: Exception) {}
    }

    override fun onResume() {
        super.onResume()
        isInBackground = false
        cancelKeepActiveCallbacks()
        releaseLocks()
        configureWebViewFeatures()
        val inPip = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode
        lifecycleChannel?.invokeMethod("onNativeResume", inPip)
        if (!inPip) {
            lifecycleChannel?.invokeMethod("onPipChanged", false)
            dispatchJs("window.__ytbSetPip && window.__ytbSetPip(false);")
        }
        dispatchJs("window.__ytbSetBackground && window.__ytbSetBackground(false);")
    }

    override fun onPause() {
        super.onPause()
        flushCookiesSafe()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && isInPictureInPictureMode) {
            return
        }
        isInBackground = true
        if (isMediaPlaying && !isInCallMode()) {
            scheduleKeepWebViewsActive()
        } else {
            cancelKeepActiveCallbacks()
        }
    }

    override fun onStop() {
        super.onStop()
        flushCookiesSafe()
        isInBackground = true
        if (isMediaPlaying && !isInCallMode()) {
            acquireLocks()
            scheduleKeepWebViewsActive()
        } else {
            cancelKeepActiveCallbacks()
        }
    }

    override fun onDestroy() {
        unregisterSystemReceivers()
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
        if (!isMediaPlaying || isInCallMode()) return
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
            // WIFI_MODE_FULL_HIGH_PERF vẫn duy trì kết nối khi app ở nền & tắt màn hình.
            @Suppress("DEPRECATION")
            wifiLock = wm.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "ytb_family:AudioWifiLock"
            ).apply {
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

    private fun dispatchJs(script: String) {
        val rootView = window?.decorView ?: return
        dispatchJsInTree(rootView, script)
    }

    private fun dispatchJsInTree(view: View, script: String) {
        if (view is WebView) {
            view.evaluateJavascript(script, null)
            return
        }
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                dispatchJsInTree(view.getChildAt(i), script)
            }
        }
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
