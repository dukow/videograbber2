package com.dukoow.videograbber

import android.content.Intent
import android.os.Environment
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {

    private val methodChannelName = "video_grabber/downloader"
    private val progressChannelName = "video_grabber/progress"

    private var progressSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var initialized = false
    private var sharedUrl: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            sharedUrl = intent.getStringExtra(Intent.EXTRA_TEXT)
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, progressChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    progressSink = sink
                }
                override fun onCancel(args: Any?) {
                    progressSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "getSharedUrl" -> {
                        result.success(sharedUrl)
                        sharedUrl = null
                    }

                    "getInfo" -> {
                        val url = call.argument<String>("url") ?: run {
                            result.error("NO_URL", "URL is required", null); return@setMethodCallHandler
                        }
                        thread {
                            try {
                                ensureInit()
                                val request = YoutubeDLRequest(url)
                                request.addOption("--no-playlist")
                                val info = YoutubeDL.getInstance().getInfo(request)
                                val map = hashMapOf<String, Any?>(
                                    "title" to info.title,
                                    "thumbnail" to info.thumbnail,
                                    "duration" to info.duration,
                                    "uploader" to info.uploader
                                )
                                mainHandler.post { result.success(map) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("INFO_ERROR", e.message ?: "Failed to get info", null)
                                }
                            }
                        }
                    }

                    "download" -> {
                        val url = call.argument<String>("url") ?: run {
                            result.error("NO_URL", "URL is required", null); return@setMethodCallHandler
                        }
                        val quality = call.argument<String>("quality") ?: "720"
                        thread {
                            try {
                                ensureInit()
                                val outDir = File(
                                    Environment.getExternalStoragePublicDirectory(
                                        Environment.DIRECTORY_DOWNLOADS
                                    ),
                                    "VideoGrabber"
                                )
                                if (!outDir.exists()) outDir.mkdirs()

                                val request = YoutubeDLRequest(url)
                                request.addOption("--no-playlist")
                                request.addOption("--no-mtime")

                                if (quality == "mp3") {
                                    // Extract audio as MP3
                                    request.addOption("-x")
                                    request.addOption("--audio-format", "mp3")
                                    request.addOption("--audio-quality", "0")
                                    request.addOption(
                                        "-o",
                                        "${outDir.absolutePath}/%(title).80s.%(ext)s"
                                    )
                                } else {
                                    request.addOption(
                                        "-f",
                                        "bestvideo[height<=$quality]+bestaudio/best[height<=$quality]"
                                    )
                                    request.addOption("--merge-output-format", "mp4")
                                    request.addOption(
                                        "-o",
                                        "${outDir.absolutePath}/%(title).80s_${quality}p.%(ext)s"
                                    )
                                }

                                YoutubeDL.getInstance().execute(request, url) { progress, etaSeconds, _ ->
                                    mainHandler.post {
                                        progressSink?.success(
                                            mapOf(
                                                "progress" to progress,
                                                "eta" to etaSeconds
                                            )
                                        )
                                    }
                                }

                                mainHandler.post { result.success(outDir.absolutePath) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("DL_ERROR", e.message ?: "Download failed", null)
                                }
                            }
                        }
                    }

                    "updateEngine" -> {
                        thread {
                            try {
                                ensureInit()
                                YoutubeDL.getInstance().updateYoutubeDL(
                                    application,
                                    YoutubeDL.UpdateChannel.STABLE
                                )
                                mainHandler.post { result.success(true) }
                            } catch (e: Exception) {
                                mainHandler.post {
                                    result.error("UPDATE_ERROR", e.message, null)
                                }
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    @Synchronized
    private fun ensureInit() {
        if (!initialized) {
            YoutubeDL.getInstance().init(application)
            FFmpeg.getInstance().init(application)
            initialized = true
        }
    }
}
