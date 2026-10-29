package com.slipecode.slipecode_editor

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "slipecode/container"
    private val termuxChannelName = "slipecode/termux"
    private val keyEventChannelName = "slipecode/keyevent"
    private val overlayChannelName = "slipecode/overlay"

    /// Flutter 侧注册的音量键监听器；为 null 表示未监听（按键走系统默认）
    private var volumeKeyListener: ((Int) -> Boolean)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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

                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is null", null)
                        } else {
                            try {
                                val intent = android.content.Intent(android.content.Intent.ACTION_VIEW)
                                val uri = androidx.core.content.FileProvider.getUriForFile(
                                    this,
                                    "$packageName.fileprovider",
                                    File(path)
                                )
                                intent.setDataAndType(
                                    uri,
                                    "application/vnd.android.package-archive"
                                )
                                intent.addFlags(
                                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                                        android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
                                )
                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                Log.e("SLIPE", "installApk failed", e)
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // Termux API 通道：通过 Termux 的 RunCommandService 在 Termux 环境执行命令
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, termuxChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTermuxInstalled" -> {
                        result.success(isPackageInstalled("com.termux"))
                    }

                    "isTermuxApiInstalled" -> {
                        result.success(isPackageInstalled("com.termux.api"))
                    }

                    "exec" -> {
                        val command = call.argument<String>("command")
                        val workDir = call.argument<String>("workDir")
                        if (command == null) {
                            result.error("bad_args", "command is null", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val execResult = execInTermux(command, workDir)
                            result.success(
                                mapOf(
                                    "exitCode" to execResult.first,
                                    "stdout" to execResult.second,
                                    "stderr" to execResult.third
                                )
                            )
                        } catch (e: Exception) {
                            Log.e("SLIPE", "termux exec failed", e)
                            result.error("exec_failed", e.message, null)
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, overlayChannelName)
            .setMethodCallHandler { call, result ->
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

    // ---------------------------------------------------------------------------
    // Termux 集成
    // ---------------------------------------------------------------------------

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(0)
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    /**
     * 在 Termux 中执行命令并捕获输出。
     *
     * 原理：
     * 1. 把命令包装成脚本，输出重定向到外部存储的临时文件；
     * 2. 通过 Intent 启动 Termux 的 RunCommandService 执行脚本；
     * 3. 轮询等待输出文件出现并读取。
     *
     * 需要 Termux 已获取存储权限（termux-setup-storage）。
     */
    private fun execInTermux(command: String, workDir: String?): Triple<Int, String, String> {
        // 使用外部存储共享目录作为 Termux 与本应用的交换区
        val sharedDir = File(
            Environment.getExternalStorageDirectory(),
            "Android/data/com.termux/files/slipecode_tmp"
        )
        if (!sharedDir.exists()) sharedDir.mkdirs()

        val scriptFile = File(sharedDir, "cmd_${System.currentTimeMillis()}.sh")
        val stdoutFile = File(sharedDir, "out_${System.currentTimeMillis()}.txt")
        val stderrFile = File(sharedDir, "err_${System.currentTimeMillis()}.txt")
        val exitFile = File(sharedDir, "exit_${System.currentTimeMillis()}.txt")

        val cdPart = if (workDir != null) "cd '$workDir' && " else ""
        val script = """
            |#!/data/data/com.termux/files/usr/bin/bash
            |$cdPart$command > '${stdoutFile.absolutePath}' 2> '${stderrFile.absolutePath}'
            |echo ${'$'}? > '${exitFile.absolutePath}'
            |""".trimMargin()

        scriptFile.writeText(script)
        scriptFile.setExecutable(true, false)
        scriptFile.setReadable(true, false)

        // 启动 Termux RunCommandService 执行脚本
        val intent = Intent().apply {
            setClassName("com.termux", "com.termux.app.RunCommandService")
            action = "com.termux.RUN_COMMAND"
            putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf(scriptFile.absolutePath))
            putExtra("com.termux.RUN_COMMAND_WORKDIR", "/data/data/com.termux/files/home")
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", "0")
        }

        // 输出重定向：在脚本里已经处理，这里清空旧输出文件
        stdoutFile.delete()
        stderrFile.delete()
        exitFile.delete()

        try {
            startService(intent)
        } catch (e: Exception) {
            // 尝试用 activity 方式启动
            try {
                val activityIntent = Intent().apply {
                    setClassName("com.termux", "com.termux.app.RunCommandService")
                    action = "com.termux.RUN_COMMAND"
                    putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
                    putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf(scriptFile.absolutePath))
                    putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
                }
                startService(activityIntent)
            } catch (e2: Exception) {
                return Triple(-1, "", "无法启动 Termux：${e2.message}")
            }
        }

        // 轮询等待退出码文件（最多 10 分钟）
        val deadline = System.currentTimeMillis() + 10 * 60 * 1000L
        while (!exitFile.exists() && System.currentTimeMillis() < deadline) {
            Thread.sleep(500)
        }

        val stdout = if (stdoutFile.exists()) stdoutFile.readText() else ""
        val stderr = if (stderrFile.exists()) stderrFile.readText() else ""
        val exitCode = if (exitFile.exists()) {
            exitFile.readText().trim().toIntOrNull() ?: -1
        } else {
            -1
        }

        // 清理临时文件
        scriptFile.delete()
        stdoutFile.delete()
        stderrFile.delete()
        exitFile.delete()

        return Triple(exitCode, stdout, stderr)
    }
}
