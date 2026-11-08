package com.slipe.editor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import org.json.JSONObject

/**
 * 任务实况通知服务（类灵动岛 / 实况通知）
 *
 * 用于 AI 任务执行与云端构建期间展示可更新的常驻通知：
 * - Android 16+：使用原生 ProgressStyle（Live Updates），ColorOS 等系统会渲染为实况通知；
 * - 小米 HyperOS：附加 miui.focus.param，渲染为焦点通知 / 超级岛；
 * - vivo OriginOS：附加 notification.superx.*，渲染为原子通知 / 原子岛；
 * - 其余设备：退化为标准的可更新进度通知。
 *
 * 服务本身只是前台服务载体（保持后台更新不被回收），任务通知通过
 * NotificationManager 以独立 id 发布，支持多任务并存。
 */
class LiveTaskService : Service() {

    companion object {
        private const val TAG = "LiveTaskService"
        private const val CHANNEL_ID = "slipe_live_tasks"
        private const val SUMMARY_ID = 40
        private const val CHILD_ID_BASE = 4100

        private const val ACTION_START = "start"
        private const val ACTION_UPDATE = "update"
        private const val ACTION_STOP = "stop"
        private const val ACTION_STOP_ALL = "stop_all"

        private const val EXTRA_ID = "id"
        private const val EXTRA_KIND = "kind"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_INDETERMINATE = "indeterminate"
        private const val EXTRA_DONE = "done"

        /** 服务是否已经在运行（已在运行时更新用 startService，避免后台启动前台服务限制） */
        @Volatile
        private var isRunning = false

        fun start(
            context: Context,
            id: String,
            kind: String,
            title: String,
            text: String,
            progress: Int?,
            indeterminate: Boolean,
            done: Boolean
        ) {
            dispatch(context, ACTION_START, id, kind, title, text, progress, indeterminate, done)
        }

        fun update(
            context: Context,
            id: String,
            kind: String,
            title: String,
            text: String,
            progress: Int?,
            indeterminate: Boolean,
            done: Boolean
        ) {
            dispatch(context, ACTION_UPDATE, id, kind, title, text, progress, indeterminate, done)
        }

        fun stop(context: Context, id: String) {
            try {
                val intent = Intent(context, LiveTaskService::class.java).apply {
                    action = ACTION_STOP
                    putExtra(EXTRA_ID, id)
                }
                context.startService(intent)
            } catch (e: Exception) {
                Log.e(TAG, "stop failed", e)
            }
        }

        fun stopAll(context: Context) {
            try {
                val intent = Intent(context, LiveTaskService::class.java).apply {
                    action = ACTION_STOP_ALL
                }
                context.startService(intent)
            } catch (e: Exception) {
                Log.e(TAG, "stopAll failed", e)
            }
        }

        private fun dispatch(
            context: Context,
            action: String,
            id: String,
            kind: String,
            title: String,
            text: String,
            progress: Int?,
            indeterminate: Boolean,
            done: Boolean
        ) {
            try {
                val intent = Intent(context, LiveTaskService::class.java).apply {
                    this.action = action
                    putExtra(EXTRA_ID, id)
                    putExtra(EXTRA_KIND, kind)
                    putExtra(EXTRA_TITLE, title)
                    putExtra(EXTRA_TEXT, text)
                    putExtra(EXTRA_INDETERMINATE, indeterminate)
                    putExtra(EXTRA_DONE, done)
                    if (progress != null) putExtra(EXTRA_PROGRESS, progress)
                }
                if (action == ACTION_UPDATE && isRunning) {
                    context.startService(intent)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "$action failed", e)
            }
        }

        /** 当前设备的实况通知能力（供 Flutter 展示适配状态） */
        fun capabilities(context: Context): Map<String, Any> {
            val manufacturer = (Build.MANUFACTURER ?: "").lowercase()
            val focusProtocol = try {
                Settings.System.getInt(
                    context.contentResolver,
                    "notification_focus_protocol",
                    0
                )
            } catch (_: Exception) {
                0
            }
            return mapOf(
                "sdkInt" to Build.VERSION.SDK_INT,
                "manufacturer" to manufacturer,
                "progressStyle" to (Build.VERSION.SDK_INT >= 36),
                "miuiFocus" to (manufacturer == "xiaomi" && focusProtocol >= 2),
                "vivoSuperx" to (manufacturer == "vivo" || manufacturer == "iqoo"),
                "oppoLive" to (manufacturer == "oppo" || manufacturer == "realme" || manufacturer == "oneplus")
            )
        }
    }

    private data class TaskState(
        val id: String,
        val kind: String,
        val title: String,
        val text: String,
        val progress: Int?,
        val indeterminate: Boolean,
        val done: Boolean
    )

    private val tasks = LinkedHashMap<String, TaskState>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                val id = intent.getStringExtra(EXTRA_ID) ?: ""
                tasks.remove(id)
                getSystemService(NotificationManager::class.java)?.cancel(childId(id))
                if (tasks.isEmpty()) {
                    stopForegroundCompat()
                    stopSelf()
                }
                return START_NOT_STICKY
            }
            ACTION_STOP_ALL -> {
                val manager = getSystemService(NotificationManager::class.java)
                for (id in tasks.keys) {
                    manager?.cancel(childId(id))
                }
                tasks.clear()
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START, ACTION_UPDATE -> {
                val id = intent.getStringExtra(EXTRA_ID) ?: return START_NOT_STICKY
                val state = TaskState(
                    id = id,
                    kind = intent.getStringExtra(EXTRA_KIND) ?: "task",
                    title = intent.getStringExtra(EXTRA_TITLE) ?: "SLIPE",
                    text = intent.getStringExtra(EXTRA_TEXT) ?: "",
                    progress = if (intent.hasExtra(EXTRA_PROGRESS)) {
                        intent.getIntExtra(EXTRA_PROGRESS, 0)
                    } else null,
                    indeterminate = intent.getBooleanExtra(EXTRA_INDETERMINATE, true),
                    done = intent.getBooleanExtra(EXTRA_DONE, false)
                )
                tasks[id] = state
                return try {
                    isRunning = true
                    startForeground(SUMMARY_ID, summaryNotification())
                    getSystemService(NotificationManager::class.java)
                        ?.notify(childId(id), buildTaskNotification(state))
                    START_NOT_STICKY
                } catch (e: Exception) {
                    Log.e(TAG, "show task notification failed", e)
                    stopSelf()
                    START_NOT_STICKY
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        tasks.clear()
        isRunning = false
        super.onDestroy()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun childId(id: String): Int = CHILD_ID_BASE + (id.hashCode() and 0xFFF)

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "任务实况",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "AI 执行与云端构建的实时进度"
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun builder(): Notification.Builder {
        ensureChannel()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
    }

    private fun summaryNotification(): Notification {
        val text = if (tasks.isEmpty) "任务进行中" else tasks.values.last().text
        return builder()
            .setContentTitle("SLIPE 任务进行中")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(launchIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setGroup("slipe_live_tasks")
            .setGroupSummary(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .build()
    }

    private fun buildTaskNotification(state: TaskState): Notification {
        val nBuilder = builder()
            .setContentTitle(state.title)
            .setContentText(state.text)
            .setSmallIcon(
                if (state.kind == "build") {
                    android.R.drawable.stat_sys_download
                } else {
                    android.R.drawable.stat_notify_sync
                }
            )
            .setContentIntent(launchIntent())
            .setOngoing(!state.done)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setGroup("slipe_live_tasks")
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setSubText(if (state.kind == "build") "云端构建" else "AI 执行中")

        applyProgressStyle(nBuilder, state)
        if (Build.VERSION.SDK_INT >= 36) {
            try {
                nBuilder.setShortCriticalText(state.text.take(30))
            } catch (_: Throwable) {
                // 低版本 SystemUI 不支持时忽略
            }
        }
        applyVendorExtras(nBuilder, state)
        return nBuilder.build()
    }

    /** Android 16 原生 Live Updates（ProgressStyle），反射调用以避免低版本编译/运行问题 */
    private fun applyProgressStyle(builder: Notification.Builder, state: TaskState) {
        val progress = state.progress
        if (Build.VERSION.SDK_INT >= 36) {
            try {
                val styleClass = Class.forName("android.app.Notification\$ProgressStyle")
                val style = styleClass.getDeclaredConstructor().newInstance()
                if (progress != null) {
                    styleClass
                        .getMethod("setProgress", Int::class.javaPrimitiveType)
                        .invoke(style, progress.coerceIn(0, 100))
                }
                builder.setStyle(style as Notification.Style)
                return
            } catch (e: Throwable) {
                Log.w(TAG, "ProgressStyle unavailable, fallback", e)
            }
        }
        if (progress != null) {
            builder.setProgress(100, progress.coerceIn(0, 100), false)
        } else {
            builder.setProgress(0, 0, true)
        }
    }

    /** 各厂商实况/灵动岛扩展字段 */
    private fun applyVendorExtras(builder: Notification.Builder, state: TaskState) {
        try {
            val manufacturer = (Build.MANUFACTURER ?: "").lowercase()
            when {
                manufacturer == "xiaomi" -> applyMiuiFocus(builder, state)
                manufacturer == "vivo" || manufacturer == "iqoo" -> applyVivoSuperx(builder, state)
                // OPPO / 其余设备：使用系统原生实况通知（ColorOS 已支持 ProgressStyle）
            }
        } catch (e: Exception) {
            Log.w(TAG, "apply vendor extras failed", e)
        }
    }

    /** 小米 HyperOS 焦点通知 / 超级岛 */
    private fun applyMiuiFocus(builder: Notification.Builder, state: TaskState) {
        val protocol = try {
            Settings.System.getInt(contentResolver, "notification_focus_protocol", 0)
        } catch (_: Exception) {
            0
        }
        if (protocol < 2) return

        val progress = state.progress
        val param = JSONObject()
        val v2 = JSONObject()
        v2.put("protocol", 1)
        v2.put("business", if (state.kind == "build") "slipe_build" else "slipe_ai")
        v2.put("enableFloat", false)
        v2.put("updatable", !state.done)
        v2.put("ticker", state.text)
        v2.put("aodTitle", state.text)
        v2.put("orderId", "slipe_${state.kind}")
        v2.put("filterWhenNoPermission", false)

        // 摘要态（大岛 / 小岛）
        val island = JSONObject().apply {
            put("islandProperty", 1)
            put("islandTimeout", 3600)
            put(
                "bigIslandArea",
                JSONObject().apply {
                    put(
                        "imageTextInfoLeft",
                        JSONObject().apply {
                            put("type", 1)
                            put(
                                "textInfo",
                                JSONObject().apply {
                                    put("frontTitle", state.title)
                                    put("title", if (progress != null) "$progress%" else state.title)
                                    put("content", state.text)
                                    put("useHighLight", false)
                                }
                            )
                        }
                    )
                }
            )
            put(
                "smallIslandArea",
                JSONObject().apply {
                    put(
                        "textInfo",
                        JSONObject().apply {
                            put("frontTitle", state.title)
                            put("title", state.text)
                        }
                    )
                }
            )
        }
        v2.put("param_island", island)
        v2.put(
            "baseInfo",
            JSONObject().apply {
                put("title", state.title)
                put("content", state.text)
                put("colorTitle", "#2D6CF6")
                put("type", 2)
            }
        )
        if (progress != null) {
            v2.put(
                "hintInfo",
                JSONObject().apply {
                    put("type", 2)
                    put("title", "$progress%")
                }
            )
        }
        param.put("param_v2", v2)
        builder.addExtras(Bundle().apply { putString("miui.focus.param", param.toString()) })
    }

    /** vivo 原子通知（基础模板 + 进度辅助区） */
    private fun applyVivoSuperx(builder: Notification.Builder, state: TaskState) {
        val progress = state.progress
        val extras = Bundle()
        extras.putInt("notification.superx.operation", 0)
        extras.putBoolean("notification.superx.showNotify", true)
        extras.putInt("notification.superx.template", 4) // 基础模板
        extras.putString("notification.superx.scene", "AI_TASK")
        extras.putBoolean("notification.superx.sound", false)
        extras.putBoolean("notification.superx.dismissWhenKill", false)
        extras.putParcelable("notification.superx.clickResp", launchIntent())

        extras.putBundle(
            "notification.superx.baseInfos",
            Bundle().apply {
                putCharSequence("title", state.title)
                putCharSequence("content", state.text)
                if (progress != null) {
                    putInt("subInfo", 5) // 展示进度
                    putInt("subProgress", progress.coerceIn(0, 100))
                    putInt("progressState", if (state.done) 1 else 0)
                    putInt("subProgressColor", 0xFF2D6CF6.toInt())
                } else {
                    putInt("subInfo", 6) // 展示加载中
                    putInt("loadingColor", 0xFF2D6CF6.toInt())
                }
            }
        )
        extras.putBundle("notification.superx.infos", Bundle())
        extras.putBundle(
            "notification.superx.shortInfos",
            Bundle().apply {
                putCharSequence("title", state.title)
                putCharSequence("content", state.text)
            }
        )
        extras.putBundle(
            "notification.superx.capsule",
            Bundle().apply {
                putInt("state", if (state.done) 0 else 1)
                putCharSequence("content", if (progress != null) "$progress%" else state.text)
            }
        )
        builder.addExtras(extras)
    }

    private fun launchIntent(): PendingIntent {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
