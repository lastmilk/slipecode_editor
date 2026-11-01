package com.slipe.editor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

/// 云端构建保活服务
///
/// 构建期间显示不可清除的常驻通知（前台服务）。系统会优先保留带常驻
/// 通知的进程，因此退出构建页 / 退到后台后仍能持续同步构建流程。
class BuildKeepAliveService : Service() {

    companion object {
        private const val TAG = "BuildKeepAliveService"
        private const val CHANNEL_ID = "slipe_build_watch"
        private const val NOTIFICATION_ID = 43
        private const val ACTION_START = "start"
        private const val ACTION_UPDATE = "update"
        private const val ACTION_STOP = "stop"
        private const val EXTRA_TEXT = "text"

        fun start(context: Context, text: String) {
            try {
                val intent = Intent(context, BuildKeepAliveService::class.java).apply {
                    action = ACTION_START
                    putExtra(EXTRA_TEXT, text)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "start failed", e)
            }
        }

        fun update(context: Context, text: String) {
            try {
                val intent = Intent(context, BuildKeepAliveService::class.java).apply {
                    action = ACTION_UPDATE
                    putExtra(EXTRA_TEXT, text)
                }
                // 服务已在运行时 update 不需要 startForegroundService，直接 startService 即可
                context.startService(intent)
            } catch (e: Exception) {
                Log.e(TAG, "update failed", e)
            }
        }

        fun stop(context: Context) {
            try {
                val intent = Intent(context, BuildKeepAliveService::class.java).apply {
                    action = ACTION_STOP
                }
                context.startService(intent)
            } catch (e: Exception) {
                Log.e(TAG, "stop failed", e)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }

        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "云端构建进行中"
        return try {
            startForeground(NOTIFICATION_ID, buildNotification(text))
            START_NOT_STICKY
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
            stopSelf()
            START_NOT_STICKY
        }
    }

    private fun buildNotification(text: String): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "云端构建进度",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "云端构建期间保持进度同步"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("SLIPE 云端构建")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(buildLaunchPendingIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setProgress(0, 0, true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .build()
    }

    private fun buildLaunchPendingIntent(): PendingIntent? {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
