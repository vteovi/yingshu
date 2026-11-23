package com.yingshu.player

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val externalChannelName = "com.yingshu.player/external_player"
    private val pipChannelName = "com.yingshu.player/pip"
    private var pipChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, externalChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val url = call.argument<String>("url")
                        val title = call.argument<String>("title") ?: "用其他播放器打开"
                        if (url.isNullOrBlank()) {
                            result.error("bad_args", "url is empty", null)
                        } else {
                            try {
                                openExternal(url, title)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("failed", e.message ?: "no player found", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName)
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(pipSupported())
                "enter" -> {
                    val aspect = call.argument<Double>("aspectRatio") ?: (16.0 / 9.0)
                    result.success(enterPip(aspect))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pipSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    /** 进入系统画中画。ratio 为视频宽高比，小于 1 即竖屏小窗。 */
    private fun enterPip(aspect: Double): Boolean {
        if (!pipSupported()) return false
        // Android 允许的范围约 1/2.39 ~ 2.39，先夹一下再转 Rational
        val clamped = aspect.coerceIn(1.0 / 2.39, 2.39)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val params = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational((clamped * 1000).toInt(), 1000))
                    .build()
                enterPictureInPictureMode(params)
                true
            } else {
                @Suppress("DEPRECATION")
                enterPictureInPictureMode()
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }

    /** 交给系统选播放器：VLC / MX Player / 系统播放器都会出现在候选里。 */
    private fun openExternal(url: String, title: String) {
        val uri = Uri.parse(url)
        val viewIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "video/*")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            putExtra("title", title)
        }
        val chooser = Intent.createChooser(viewIntent, "选择播放器")
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(chooser)
    }
}
