package com.slipe.editor

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// local_auth 的生物认证需要 Activity 实现 FragmentActivity 才能弹出 BiometricPrompt
class MainActivity : FlutterFragmentActivity() {
    private val channelName = "slipe/container"
    private val keyEventChannelName = "slipe/keyevent"
    private val overlayChannelName = "slipe/overlay"
    private val liveTaskChannelName = "slipe/live_task"

    /// 点击系统悬浮球后待处理的「打开 AI 对话」请求（冷启动时由 Dart 主动消费）
    private var pendingOpenAiChat = false
    private var pendingAiPrompt: String? = null
    private var pendingAiProject: String? = null
    private var overlayChannel: MethodChannel? = null

    /// Flutter 侧注册的音量键监听器；为 null 表示未监听（按键走系统默认）
    private var volumeKeyListener: ((Int) -> Boolean)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // 先记录冷启动携带的 AI 请求，避免 Flutter 引擎初始化后先消费造成丢参
        captureAiRequest(intent)
        super.onCreate(savedInstanceState)
    }

    /// 悬浮球面板「开始执行」后以 SINGLE_TOP 拉起已运行的 App，在这里把请求转给 Flutter
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureAiRequest(intent)
        if (pendingOpenAiChat) {
            overlayChannel?.invokeMethod(
                "openAiChat",
                mapOf("prompt" to pendingAiPrompt, "project" to pendingAiProject)
            )
            // 已实时转交 Flutter，清空标记，避免 Dart 端再次消费造成重复打开
            pendingOpenAiChat = false
            pendingAiPrompt = null
            pendingAiProject = null
        }
    }

    private fun captureAiRequest(intent: Intent?) {
        if (intent == null) return
        if (!intent.getBooleanExtra(AiOverlayService.EXTRA_OPEN_AI_CHAT, false)) return
        pendingOpenAiChat = true
        pendingAiPrompt = intent.getStringExtra(AiOverlayService.EXTRA_AI_PROMPT)
        pendingAiProject = intent.getStringExtra(AiOverlayService.EXTRA_AI_PROJECT)
    }

    /// 用系统文件管理器 / 安装器打开本地文件。
    /// 文件位于应用私有目录（app_flutter），通过 root-path 的 FileProvider 授权读取。
    private fun openFileWithSystem(path: String, mime: String): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        val uri = androidx.core.content.FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        }
        startActivity(intent)
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 极验验证码（登录/注册人机校验）
        GeeTestChannel(this).register(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // proot 二进制放在 jniLibs/arm64-v8a/libproot.so 时，会落在这个可执行目录
                    "getNativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)

                    "makeExecutable" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is null", null)
                        } else {
                            try {
                                val file = File(path)
                                var ok = file.setExecutable(true, false)
                                if (ok) {
                                    ok = file.setReadable(true, false)
                                }
                                result.success(ok)
                            } catch (e: Exception) {
                                result.error("chmod_failed", e.message, null)
                            }
                        }
                    }

                    "getDeviceArch" -> {
                        result.success(System.getProperty("os.arch"))
                    }

                    // 用系统文件管理器 / 安装器打开本地文件（不再尝试静默安装）。
                    // 产物位于应用私有目录，必须通过 FileProvider 授权。
                    "openFile" -> {
                        val path = call.argument<String>("path")
                        val mime = call.argument<String>("mime")
                            ?: "application/vnd.android.package-archive"
                        if (path == null) {
                            result.error("bad_args", "path is null", null)
                        } else {
                            try {
                                result.success(openFileWithSystem(path, mime))
                            } catch (e: Exception) {
                                Log.e("SLIPE", "openFile failed", e)
                                result.error("open_failed", e.message, null)
                            }
                        }
                    }

                    // 兼容旧调用：等价于 openFile + APK MIME
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is null", null)
                        } else {
                            try {
                                result.success(
                                    openFileWithSystem(
                                        path,
                                        "application/vnd.android.package-archive"
                                    )
                                )
                            } catch (e: Exception) {
                                Log.e("SLIPE", "installApk failed", e)
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // 音量键拦截通道：Flutter 侧注册监听器后，音量上/下键先回调 Flutter，
        // 由 Flutter 决定是否消费（true=已处理，false=交还给系统调节音量）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, keyEventChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setVolumeKeyListener" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        volumeKeyListener = if (enabled) {
                            // 注册后：音量键一律消费（不调节音量），异步通知 Dart 处理。
                            // 不做同步等待，避免阻塞 UI 线程。
                            { keyCode ->
                                MethodChannel(
                                    flutterEngine.dartExecutor.binaryMessenger,
                                    keyEventChannelName
                                ).invokeMethod("onVolumeKey", keyCode, null)
                                true
                            }
                        } else null
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // 系统悬浮窗通道：AI 悬浮球可在 App 退到后台后仍然显示
        overlayChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, overlayChannelName)
        overlayChannel!!.setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkPermission" -> {
                        result.success(
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                                android.provider.Settings.canDrawOverlays(this)
                            else true
                        )
                    }
                    "requestPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            try {
                                val intent = Intent(
                                    android.provider.Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                    android.net.Uri.parse("package:$packageName")
                                )
                                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("request_failed", e.message, null)
                            }
                        } else {
                            result.success(true)
                        }
                    }
                    "showOverlay" -> {
                        try {
                            AiOverlayService.start(this)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e("SLIPE", "showOverlay failed", e)
                            result.error("show_failed", e.message, null)
                        }
                    }
                    "hideOverlay" -> {
                        try {
                            AiOverlayService.stop(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("hide_failed", e.message, null)
                        }
                    }
                    "isOverlayShowing" -> {
                        result.success(AiOverlayService.isShowing)
                    }
                    "consumeOpenAiChat" -> {
                        // 冷启动：悬浮球提交的需求在 Flutter 就绪后消费一次
                        result.success(
                            mapOf(
                                "open" to pendingOpenAiChat,
                                "prompt" to pendingAiPrompt,
                                "project" to pendingAiProject
                            )
                        )
                        pendingOpenAiChat = false
                        pendingAiPrompt = null
                        pendingAiProject = null
                    }
                    else -> result.notImplemented()
                }
            }

        // 任务实况通知（AI 执行 / 云端构建）：类灵动岛的常驻可更新通知
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, liveTaskChannelName)
            .setMethodCallHandler { call, result ->
                val id = call.argument<String>("id") ?: ""
                val kind = call.argument<String>("kind") ?: "task"
                val title = call.argument<String>("title") ?: "SLIPE"
                val text = call.argument<String>("text") ?: ""
                val progress = call.argument<Int>("progress")
                val indeterminate = call.argument<Boolean>("indeterminate") ?: true
                val done = call.argument<Boolean>("done") ?: false
                when (call.method) {
                    "start" -> {
                        try {
                            LiveTaskService.start(
                                this, id, kind, title, text, progress, indeterminate, done
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("live_task_failed", e.message, null)
                        }
                    }
                    "update" -> {
                        try {
                            LiveTaskService.update(
                                this, id, kind, title, text, progress, indeterminate, done
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("live_task_failed", e.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            LiveTaskService.stop(this, id)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("live_task_failed", e.message, null)
                        }
                    }
                    "stopAll" -> {
                        try {
                            LiveTaskService.stopAll(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("live_task_failed", e.message, null)
                        }
                    }
                    "capabilities" -> result.success(LiveTaskService.capabilities(this))
                    else -> result.notImplemented()
                }
            }
    }

    /// 音量键分发：仅在 Flutter 侧注册了监听且确认消费时才拦截，
    /// 否则保持系统默认行为（调节音量）
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        val listener = volumeKeyListener
        if (listener != null && event.action == android.view.KeyEvent.ACTION_DOWN) {
            val keyCode = event.keyCode
            if (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP ||
                keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN
            ) {
                // 回调 Flutter 询问是否消费；消费则不再走系统音量调节
                if (listener(keyCode)) return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /// 极验 SDK 要求：页面销毁时释放资源
    override fun onDestroy() {
        GeeTestChannel.releaseIfNeeded()
        super.onDestroy()
    }

    /// 极验 SDK 要求：横竖屏切换时通知验证窗口
    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        GeeTestChannel.notifyConfigurationChanged(newConfig)
    }
}
