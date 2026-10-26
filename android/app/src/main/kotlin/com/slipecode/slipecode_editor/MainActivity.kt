package com.slipecode.slipecode_editor

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "slipecode/container"

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
                                Log.e("SlipCode", "installApk failed", e)
                                result.error("install_failed", e.message, null)
                            }
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
