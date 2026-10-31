package com.slipecode.slipecode_editor

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// local_auth 的生物认证需要 Activity 实现 FragmentActivity 才能弹出 BiometricPrompt
class MainActivity : FlutterFragmentActivity() {
    private val channelName = "slipecode/container"
    private val termuxChannelName = "slipecode/termux"
    private val keyEventChannelName = "slipecode/keyevent"
    private val overlayChannelName = "slipecode/overlay"

    companion object {
        /// Termux 定义的 RUN_COMMAND 权限（protectionLevel=dangerous，需运行时申请）
        private const val TERMUX_RUN_COMMAND_PERMISSION = "com.termux.permission.RUN_COMMAND"
        private const val REQUEST_RUN_COMMAND_PERMISSION = 0x1001
        private const val TERMUX_PACKAGE = "com.termux"
        private const val TERMUX_API_PACKAGE = "com.termux.api"
    }

    /// 运行时权限申请中的回调（等待用户在系统弹窗中做出选择）
    private var pendingPermissionResult: MethodChannel.Result? = null

    /// Flutter 侧注册的音量键监听器；为 null 表示未监听（按键走系统默认）
    private var volumeKeyListener: ((Int) -> Boolean)? = null

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
                                Log.e("SlipCode", "installApk failed", e)
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
                        result.success(isPackageInstalled(TERMUX_API_PACKAGE))
                    }

                    "hasRunCommandPermission" -> {
                        result.success(hasRunCommandPermission())
                    }

                    "requestRunCommandPermission" -> {
                        requestRunCommandPermission(result)
                    }

                    "openTermux" -> openTermuxApp(TERMUX_PACKAGE, result)

                    "openTermuxApi" -> openTermuxApp(TERMUX_API_PACKAGE, result)

                    "exec" -> {
                        val command = call.argument<String>("command")
                        val workDir = call.argument<String>("workDir")
                        if (command == null) {
                            result.error("bad_args", "command is null", null)
                            return@setMethodCallHandler
                        }
                        // Termux 的 RUN_COMMAND 是 dangerous 权限，必须先获得用户授权
                        if (!hasRunCommandPermission()) {
                            result.error(
                                "permission_denied",
                                "缺少 com.termux.permission.RUN_COMMAND 权限（请在应用内授权）",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        // execInTermux 内部会轮询等待命令结束，必须放到后台线程，
                        // 否则会阻塞 Flutter 的平台线程导致界面卡死
                        Thread {
                            try {
                                val execResult = execInTermux(command, workDir)
                                runOnUiThread {
                                    result.success(
                                        mapOf(
                                            "exitCode" to execResult.first,
                                            "stdout" to execResult.second,
                                            "stderr" to execResult.third
                                        )
                                    )
                                }
                            } catch (e: Exception) {
                                Log.e("SlipCode", "termux exec failed", e)
                                runOnUiThread {
                                    result.error("exec_failed", e.message, null)
                                }
                            }
                        }.start()
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

    /// 是否已获得 Termux RUN_COMMAND 运行时权限
    private fun hasRunCommandPermission(): Boolean =
        checkSelfPermission(TERMUX_RUN_COMMAND_PERMISSION) ==
            PackageManager.PERMISSION_GRANTED

    /// 申请 Termux RUN_COMMAND 运行时权限（系统弹窗，用户需手动允许）
    private fun requestRunCommandPermission(result: MethodChannel.Result) {
        if (hasRunCommandPermission()) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("busy", "已有权限申请正在进行", null)
            return
        }
        pendingPermissionResult = result
        requestPermissions(
            arrayOf(TERMUX_RUN_COMMAND_PERMISSION),
            REQUEST_RUN_COMMAND_PERMISSION
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_RUN_COMMAND_PERMISSION) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }

    /// 拉起 Termux / Termux:API 应用（未安装时跳转应用商店）
    private fun openTermuxApp(packageName: String, result: MethodChannel.Result) {
        try {
            val launch = packageManager.getLaunchIntentForPackage(packageName)
            if (launch != null) {
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(launch)
                result.success(true)
                return
            }
            // 未安装：跳转 F-Droid 下载页
            val url = if (packageName == TERMUX_API_PACKAGE)
                "https://f-droid.org/packages/com.termux.api/"
            else
                "https://f-droid.org/packages/com.termux/"
            startActivity(
                Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            result.success(true)
        } catch (e: Exception) {
            result.error("open_failed", e.message, null)
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
        // 使用外部存储共享目录作为 Termux 与本应用的交换区。
        // 注意：Android 11+ 禁止其他应用写入 com.termux 的 Android/data，
        // 因此改用共享存储根目录（Termux 执行 termux-setup-storage 后可读）。
        val sharedDir = File(
            Environment.getExternalStorageDirectory(),
            "slipecode_tmp"
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
            setClassName(TERMUX_PACKAGE, "com.termux.app.RunCommandService")
            action = "com.termux.RUN_COMMAND"
            putExtra("com.termux.RUN_COMMAND_PATH", "/data/data/com.termux/files/usr/bin/bash")
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf(scriptFile.absolutePath))
            putExtra(
                "com.termux.RUN_COMMAND_WORKDIR",
                workDir ?: "/data/data/com.termux/files/home"
            )
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", "0")
        }

        // 输出重定向：在脚本里已经处理，这里清空旧输出文件
        stdoutFile.delete()
        stderrFile.delete()
        exitFile.delete()

        try {
            startService(intent)
        } catch (e: SecurityException) {
            // 最常见原因：Termux 未开启 allow-external-apps
            return Triple(
                -1,
                "",
                "无法启动 Termux：${e.message}\n" +
                    "请在 Termux 中执行：\n" +
                    "1) pkg install termux-api\n" +
                    "2) 在 ~/.termux/termux.properties 追加 allow-external-apps=true\n" +
                    "3) termux-reload-settings\n" +
                    "4) termux-setup-storage"
            )
        } catch (e: Exception) {
            return Triple(-1, "", "无法启动 Termux：${e.message}")
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
