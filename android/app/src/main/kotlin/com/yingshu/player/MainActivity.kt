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
    private val filesChannelName = "com.yingshu.player/files"
    private var pipChannel: MethodChannel? = null
    private var filesChannel: MethodChannel? = null

    /** 系统「保存到文件」流程的挂起内容：等用户选完目录再写盘。 */
    private var pendingText: String? = null
    private var pendingResult: MethodChannel.Result? = null
    private val exportRequestCode = 5001

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

        // 导出文件：走系统的「另存为」界面（SAF），用户自己挑目录。
        filesChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, filesChannelName)
        filesChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "exportText" -> {
                    val content = call.argument<String>("content")
                    val fileName = call.argument<String>("fileName") ?: "export.json"
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    if (content == null) {
                        result.error("bad_args", "content is empty", null)
                    } else {
                        startExport(fileName, mime, content, result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startExport(
        fileName: String,
        mime: String,
        content: String,
        result: MethodChannel.Result
    ) {
        val previous = pendingResult
        pendingResult?.success(null)
        pendingResult = result
        pendingText = content
        if (previous != null) return
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mime
                putExtra(Intent.EXTRA_TITLE, fileName)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
            startActivityForResult(intent, exportRequestCode)
        } catch (e: Exception) {
            pendingResult = null
            pendingText = null
            result.error("failed", e.message ?: "cannot open system file picker", null)
        }
    }

    @Deprecated("用于兼容旧版 Activity 结果回调")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != exportRequestCode) return
        val callback = pendingResult
        val text = pendingText
        pendingResult = null
        pendingText = null
        if (callback == null) return
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null || text == null) {
            callback.success(null) // 用户取消
            return
        }
        try {
            contentResolver.openOutputStream(uri, "wt")?.use { out ->
                out.write(text.toByteArray(Charsets.UTF_8))
                out.flush()
            }
            callback.success(uri.toString())
        } catch (e: Exception) {
            callback.error("failed", e.message ?: "write failed", null)
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
