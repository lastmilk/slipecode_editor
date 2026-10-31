package com.slipecode.slipecode_editor

import android.app.Activity
import com.geetest.captcha.GTCaptcha4Client
import com.geetest.captcha.GTCaptcha4Config
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 极验验证码（GT4）桥接。
 *
 * Flutter 侧调用 `verify(captchaId)`，SDK 弹出验证界面；
 * 验证通过后把 lot_number / captcha_output / pass_token / gen_time
 * 返回给 Dart，由后端完成二次校验（/api/auth/captcha/validate）。
 */
class GeeTestChannel(private val activity: Activity) {

    companion object {
        const val CHANNEL = "slipecode/geetest"
    }

    private var client: GTCaptcha4Client? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "verify" -> verify(call.argument<String>("captchaId"), result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun verify(captchaId: String?, result: MethodChannel.Result) {
        if (captchaId.isNullOrEmpty()) {
            result.error("bad_args", "captchaId is empty", null)
            return
        }
        activity.runOnUiThread {
            var finished = false
            try {
                val config = GTCaptcha4Config.Builder().build()
                val gt = GTCaptcha4Client.getClient(activity)
                client = gt
                gt.setLogEnable(false)
                gt.init(captchaId, config)
                    .addOnSuccessListener { status, response ->
                        if (finished) return@addOnSuccessListener
                        finished = true
                        if (!status) {
                            result.error("CAPTCHA_FAILED", "人机验证未通过", null)
                            return@addOnSuccessListener
                        }
                        try {
                            val json = JSONObject(response ?: "{}")
                            val map = HashMap<String, String>()
                            for (key in listOf(
                                "lot_number",
                                "captcha_output",
                                "pass_token",
                                "gen_time"
                            )) {
                                if (json.has(key)) map[key] = json.optString(key)
                            }
                            if (map["lot_number"].isNullOrEmpty()) {
                                result.error("CAPTCHA_PARSE", "验证结果缺少 lot_number", null)
                            } else {
                                result.success(map)
                            }
                        } catch (e: Exception) {
                            result.error("CAPTCHA_PARSE", e.message, null)
                        }
                    }
                    .addOnFailureListener { error ->
                        if (finished) return@addOnFailureListener
                        finished = true
                        // OnFailureListener.onFailure(String)：参数即错误描述
                        result.error("CAPTCHA_ERROR", error.ifBlank { "验证失败" }, null)
                    }
            } catch (e: Exception) {
                if (!finished) {
                    finished = true
                    result.error("CAPTCHA_INIT", e.message, null)
                }
            }
        }
    }
}
