package com.slipe.editor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.ImageView

/// AI 系统悬浮球服务
///
/// 用户授予「显示在其他应用上层」权限后，可在偏好设置中开启。
/// 悬浮球可拖拽，点击后回到 App 主界面（由 Flutter 侧接管打开 AI 面板）。
///
/// 注意：Android 14+（targetSdk 34）要求 specialUse 类型的前台服务
/// 在 Manifest 中声明 FOREGROUND_SERVICE_SPECIAL_USE 权限并附带
/// PROPERTY_SPECIAL_USE_FGS_SUBTYPE 属性，否则 startForeground 抛出
/// SecurityException 导致闪退（已在 Manifest 中修复）。
/// 这里再叠加 try-catch 兜底，保证任何异常都不会拖垮整个进程。
class AiOverlayService : Service() {

    companion object {
        private const val TAG = "AiOverlayService"
        private const val CHANNEL_ID = "slipe_ai_overlay"
        private const val NOTIFICATION_ID = 42

        @Volatile
        var isShowing = false
            private set

        fun start(context: Context) {
            try {
                val intent = Intent(context, AiOverlayService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 12+ 后台启动前台服务受限等场景：记录并静默失败，不闪退
                Log.e(TAG, "start AiOverlayService failed", e)
                isShowing = false
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, AiOverlayService::class.java))
            } catch (e: Exception) {
                Log.e(TAG, "stop AiOverlayService failed", e)
            }
        }
    }

    private var windowManager: WindowManager? = null
    private var overlayView: ImageView? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val notified = startForegroundWithNotification()
        if (!notified) {
            // 通知创建失败（如权限缺失）时直接停止，避免 ANR/闪退
            stopSelf()
            return
        }
        showOverlay()
    }

    override fun onDestroy() {
        hideOverlayInternal()
        super.onDestroy()
    }

    /// Android 8+ 前台服务必须显示通知；返回是否成功
    private fun startForegroundWithNotification(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "AI 悬浮球",
                    NotificationManager.IMPORTANCE_MIN
                )
                getSystemService(NotificationManager::class.java)
                    .createNotificationChannel(channel)
            }
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                ?: return false
            val pending = PendingIntent.getActivity(
                this, 0, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val notification = Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("SLIPE AI 悬浮球运行中")
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentIntent(pending)
                .build()
            startForeground(NOTIFICATION_ID, notification)
            true
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
            false
        }
    }

    private fun showOverlay() {
        if (isShowing) return
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager

        val size = (56 * resources.displayMetrics.density).toInt()
        val params = WindowManager.LayoutParams(
            size, size,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.END
            x = (24 * resources.displayMetrics.density).toInt()
            y = (96 * resources.displayMetrics.density).toInt()
        }

        val view = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_dialog_info)
            setBackgroundResource(android.R.drawable.btn_default)
            alpha = 0.9f
        }

        // 拖拽 / 点击区分：位移超过阈值视为拖拽，否则视为点击
        var downX = 0f
        var downY = 0f
        var downRawX = 0f
        var downRawY = 0f
        var moved = false
        view.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = params.x.toFloat()
                    downY = params.y.toFloat()
                    downRawX = event.rawX
                    downRawY = event.rawY
                    moved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (!moved && (kotlin.math.abs(dx) > 20 || kotlin.math.abs(dy) > 20)) {
                        moved = true
                    }
                    if (moved) {
                        // gravity 是 BOTTOM|END，x/y 表示距右/下边缘的距离
                        params.x = (downX - dx).toInt()
                        params.y = (downY - dy).toInt()
                        try {
                            windowManager?.updateViewLayout(view, params)
                        } catch (e: Exception) {
                            Log.e(TAG, "updateViewLayout failed", e)
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) {
                        // 点击：回到 App
                        try {
                            val launch = packageManager.getLaunchIntentForPackage(packageName)
                            launch?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                            launch?.let { startActivity(it) }
                        } catch (e: Exception) {
                            Log.e(TAG, "launch app from overlay failed", e)
                        }
                    }
                    true
                }
                else -> false
            }
        }

        try {
            windowManager?.addView(view, params)
            overlayView = view
            isShowing = true
        } catch (e: Exception) {
            // 权限被收回等情况
            Log.e(TAG, "addView failed", e)
            isShowing = false
            stopSelf()
        }
    }

    private fun hideOverlayInternal() {
        try {
            overlayView?.let { windowManager?.removeView(it) }
        } catch (e: Exception) {
            Log.e(TAG, "removeView failed", e)
        }
        overlayView = null
        isShowing = false
    }
}
