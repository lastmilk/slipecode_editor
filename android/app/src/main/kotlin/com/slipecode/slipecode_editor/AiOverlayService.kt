package com.slipecode.slipecode_editor

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
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.ImageView

/// AI 系统悬浮球服务
///
/// 用户授予「显示在其他应用上层」权限后，可在偏好设置中开启。
/// 悬浮球可拖拽，点击后回到 App 主界面（由 Flutter 侧接管打开 AI 面板）。
class AiOverlayService : Service() {

    companion object {
        private const val CHANNEL_ID = "slipecode_ai_overlay"
        private const val NOTIFICATION_ID = 42

        @Volatile
        var isShowing = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, AiOverlayService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, AiOverlayService::class.java))
        }
    }

    private var windowManager: WindowManager? = null
    private var overlayView: ImageView? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startForegroundWithNotification()
        showOverlay()
    }

    override fun onDestroy() {
        hideOverlayInternal()
        super.onDestroy()
    }

    /// Android 8+ 前台服务必须显示通知
    private fun startForegroundWithNotification() {
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
                        windowManager?.updateViewLayout(view, params)
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!moved) {
                        // 点击：回到 App
                        val launch = packageManager.getLaunchIntentForPackage(packageName)
                        launch?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        launch?.let { startActivity(it) }
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
            stopSelf()
        }
    }

    private fun hideOverlayInternal() {
        overlayView?.let { windowManager?.removeView(it) }
        overlayView = null
        isShowing = false
    }
}
