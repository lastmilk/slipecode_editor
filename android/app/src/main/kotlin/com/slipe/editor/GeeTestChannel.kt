package com.slipe.editor

import android.app.Activity
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import com.geetest.captcha.GTCaptcha4Client
import com.geetest.captcha.GTCaptcha4Config
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 极验验证码（GT4）桥接。
 *
 * 官方流程（https://docs.geetest.com/gt4/apirefer/api/android）：
 * 1. `getClient(activity)` 取得工具类实例（非单例，需自行保存）；
 * 2. `init(captchaId, config)` 加载验证码（仅加载，不展示）；
 * 3. `addOnSuccessListener` / `addOnFailureListener` 注册回调；
 * 4. `verifyWithCaptcha()` 展示验证窗口 ← 之前缺失，导致一直不弹窗；
 * 5. 页面销毁时调用 `destroy()`；横竖屏切换调用 `configurationChanged()`。
 *
 * Flutter 侧调用 `verify(captchaId)`，验证通过后返回
 * lot_number / captcha_output / pass_token / gen_time，
 * 由后端完成二次校验（/api/auth/captcha/validate）。
 */
class GeeTestChannel(private val activity: Activity) {

    companion object {
        const val CHANNEL = "slipe/geetest"

        /** 等待用户完成验证的最长时间，超时按失败回调，避免 Flutter 侧永久挂起 */
        private const val VERIFY_TIMEOUT_MS = 60_000L

        private val KEY_FIELDS =
            listOf("lot_number", "captcha_output", "pass_token", "gen_time")

        /** Activity 生命周期转发用的当前实例（同一时间只会有一个） */
        @Volatile
        private var instance: GeeTestChannel? = null

        /** 在 Activity.onDestroy 中调用，释放验证码资源 */
        @JvmStatic
        fun releaseIfNeeded() {
            instance?.release()
            instance = null
        }

        /** 在 Activity.onConfigurationChanged 中调用 */
        @JvmStatic
        fun notifyConfigurationChanged(newConfig: Configuration) {
            val channel = instance ?: return
            channel.activity.runOnUiThread {
                runCatching { channel.client?.configurationChanged(newConfig) }
            }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var client: GTCaptcha4Client? = null

    /** 未完成的 Dart 回调；同一时间只允许一个验证流程 */
    private var pendingResult: MethodChannel.Result? = null
    private var timeoutToken: Runnable? = null

    fun register(engine: FlutterEngine) {
        instance = this
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "verify" -> verify(call.argument<String>("captchaId"), result)
                    "cancel" -> cancel(result)
                    "isSupported" -> result.success(isWebViewSupported())
                    else -> result.notImplemented()
                }
            }
    }

    /** 释放 SDK 资源（Activity 销毁时） */
    fun release() {
        mainHandler.post {
            finishPending("CAPTCHA_CANCELLED", "页面已关闭")
            runCatching { client?.destroy() }
            client = null
        }
    }

    // ------------------------------------------------------------------
    // 验证流程
    // ------------------------------------------------------------------

    private fun verify(captchaId: String?, result: MethodChannel.Result) {
        if (captchaId.isNullOrBlank()) {
            result.error("CAPTCHA_CONFIG", "captchaId 为空，请检查 GEETEST_CAPTCHA_ID", null)
            return
        }
        mainHandler.post {
            if (pendingResult != null) {
                result.error("CAPTCHA_BUSY", "上一次人机验证尚未结束", null)
                return@post
            }
            val support = GTCaptcha4Client.isSupportWebView(activity)
            if (support.first != true) {
                result.error(
                    "CAPTCHA_UNSUPPORTED",
                    support.second ?: "当前设备 WebView 不可用",
                    null
                )
                return@post
            }

            pendingResult = result
            try {
                val config = GTCaptcha4Config.Builder()
                    .setDebug(false)
                    // 与 App 语言保持一致：zh 为简体中文
                    .setLanguage("zh")
                    .setTimeOut(10_000)
                    // 禁止点击灰色遮罩关闭，避免关闭后不触发任何回调
                    .setCanceledOnTouchOutside(false)
                    .build()

                val gt = GTCaptcha4Client.getClient(activity)
                client = gt
                gt.setLogEnable(false)
                gt.init(captchaId, config)
                    .addOnSuccessListener { status, response ->
                        if (status) {
                            handleSuccess(response)
                        } else {
                            finishPending("CAPTCHA_FAILED", "人机验证未通过，请重试")
                        }
                    }
                    .addOnFailureListener { error ->
                        finishPending("CAPTCHA_ERROR", error.ifBlank { "验证加载失败" })
                    }

                // init 只负责加载，必须调用 verifyWithCaptcha() 才会弹出验证窗口
                gt.verifyWithCaptcha()
                startTimeout()
            } catch (e: Exception) {
                finishPending("CAPTCHA_INIT", e.message ?: "验证码初始化失败")
            }
        }
    }

    private fun cancel(result: MethodChannel.Result) {
        mainHandler.post {
            runCatching { client?.cancel() }
            finishPending("CAPTCHA_CANCELLED", "已取消人机验证")
            result.success(true)
        }
    }

    private fun handleSuccess(response: String?) {
        try {
            val json = JSONObject(response ?: "{}")
            val payload = HashMap<String, String>()
            for (key in KEY_FIELDS) {
                val value = json.optString(key, "")
                if (value.isEmpty()) {
                    finishPending("CAPTCHA_PARSE", "验证结果缺少 $key")
                    return
                }
                payload[key] = value
            }
            succeed(payload)
        } catch (e: Exception) {
            finishPending("CAPTCHA_PARSE", e.message ?: "验证结果解析失败")
        }
    }

    private fun succeed(payload: Map<String, String>) {
        val result = takePending() ?: return
        result.success(payload)
    }

    private fun finishPending(code: String, message: String) {
        val result = takePending() ?: return
        result.error(code, message, null)
    }

    private fun takePending(): MethodChannel.Result? {
        cancelTimeout()
        val result = pendingResult ?: return null
        pendingResult = null
        return result
    }

    private fun startTimeout() {
        cancelTimeout()
        val token = Runnable {
            if (pendingResult != null) {
                runCatching { client?.cancel() }
                finishPending("CAPTCHA_TIMEOUT", "人机验证超时，请重试")
            }
        }
        timeoutToken = token
        mainHandler.postDelayed(token, VERIFY_TIMEOUT_MS)
    }

    private fun cancelTimeout() {
        timeoutToken?.let { mainHandler.removeCallbacks(it) }
        timeoutToken = null
    }

    private fun isWebViewSupported(): Boolean =
        runCatching { GTCaptcha4Client.isSupportWebView(activity).first }.getOrDefault(false)
}
