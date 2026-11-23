package com.yingshu.player

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.yingshu.player/external_player"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
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
