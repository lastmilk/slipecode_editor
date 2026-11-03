package com.slipe.editor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.text.InputType
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import org.json.JSONArray

/// AI 系统悬浮球服务
///
/// 用户授予「显示在其他应用上层」权限后，可在偏好设置中开启。
/// 悬浮球可拖拽；点击后弹出轻量 AI 对话面板（原生悬浮窗，不跳转 App），
/// 在面板中选择项目、输入需求后，AI 会直接在所选项目中执行。
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

        /// 点击悬浮球时携带的标记：Flutter 侧收到后直接打开 AI 快速对话框
        const val EXTRA_OPEN_AI_CHAT = "open_ai_chat"

        /// 悬浮球面板中输入的 AI 需求
        const val EXTRA_AI_PROMPT = "ai_prompt"

        /// 悬浮球面板中选择的项目路径
        const val EXTRA_AI_PROJECT = "ai_project"

        @Volatile
        var isShowing = false
            private set

        /// 构造「回到 App 并打开 AI 对话框」的启动 Intent
        fun buildLaunchIntent(context: Context): Intent? =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                    )
                    putExtra(EXTRA_OPEN_AI_CHAT, true)
                }

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
    private var panelView: View? = null

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
            val launchIntent = buildLaunchIntent(this) ?: return false
            val pending = PendingIntent.getActivity(
                this, 1, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val notification = Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("SLIPE AI 悬浮球运行中")
                .setContentText("点击打开 AI 对话")
                .setSmallIcon(R.drawable.ic_overlay_sparkle)
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

        val density = resources.displayMetrics.density
        val view = ImageView(this).apply {
            setImageResource(R.drawable.ic_overlay_sparkle)
            setBackgroundResource(R.drawable.overlay_ball_bg)
            // 让白色图标居中且留出圆形内边距，避免贴边
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(
                (14 * density).toInt(),
                (14 * density).toInt(),
                (14 * density).toInt(),
                (14 * density).toInt()
            )
            contentDescription = "SLIPE AI"
            elevation = 8f * density
            alpha = 0.95f
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
                        // 点击：弹出轻量 AI 对话面板（不跳转 App 主界面）
                        toggleChatPanel()
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
        hideChatPanel()
        try {
            overlayView?.let { windowManager?.removeView(it) }
        } catch (e: Exception) {
            Log.e(TAG, "removeView failed", e)
        }
        overlayView = null
        isShowing = false
    }

    private fun toggleChatPanel() {
        if (panelView != null) {
            hideChatPanel()
        } else {
            showChatPanel()
        }
    }

    /// 轻量 AI 对话面板：项目选择 + 需求输入 + 执行
    private fun showChatPanel() {
        val wm = windowManager ?: return
        hideChatPanel()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            setBackgroundResource(R.drawable.overlay_panel_bg)
            // 点击面板外部时关闭
            setOnTouchListener { _, event ->
                if (event.action == MotionEvent.ACTION_OUTSIDE) {
                    hideChatPanel()
                    true
                } else {
                    false
                }
            }
        }

        // 标题栏
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(
            TextView(this).apply {
                text = "SLIPE AI"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        )
        header.addView(
            TextView(this).apply {
                text = "✕"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                setPadding(dp(8), dp(4), dp(8), dp(4))
                setOnClickListener { hideChatPanel() }
            }
        )
        root.addView(header)

        root.addView(
            TextView(this).apply {
                text = "选择项目后输入需求，AI 会自动在该项目中执行"
                setTextColor(0xB3FFFFFF.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setPadding(0, dp(4), 0, dp(10))
            }
        )

        // 项目选择
        val projects = loadProjects()
        val names = projects.map { it.first }
        val projectSpinner = Spinner(this).apply {
            setBackgroundResource(R.drawable.overlay_input_bg)
        }
        val adapter = object : ArrayAdapter<String>(
            this,
            android.R.layout.simple_spinner_item,
            names
        ) {
            override fun getView(position: Int, convertView: View?, parent: android.view.ViewGroup): View {
                val view = super.getView(position, convertView, parent) as TextView
                view.setTextColor(Color.WHITE)
                view.textSize = 14f
                view.setPadding(dp(10), dp(8), dp(10), dp(8))
                return view
            }

            override fun getDropDownView(position: Int, convertView: View?, parent: android.view.ViewGroup): View {
                val view = super.getDropDownView(position, convertView, parent) as TextView
                view.setTextColor(Color.WHITE)
                view.setBackgroundColor(0xFF1B1F2A.toInt())
                view.setPadding(dp(10), dp(10), dp(10), dp(10))
                return view
            }
        }
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        projectSpinner.adapter = adapter
        projectSpinner.visibility = if (names.isEmpty()) View.GONE else View.VISIBLE
        root.addView(projectSpinner)

        if (names.isEmpty()) {
            root.addView(
                TextView(this).apply {
                    text = "暂无项目，请先在 App 中创建或导入项目"
                    setTextColor(0xFFFFB74D.toInt())
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                    setPadding(0, dp(4), 0, dp(8))
                }
            )
        }

        // 需求输入
        val input = EditText(this).apply {
            hint = "输入需求，例如：为首页添加搜索框"
            setHintTextColor(0x99FFFFFF.toInt())
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            minLines = 2
            maxLines = 4
            setBackgroundResource(R.drawable.overlay_input_bg)
            setPadding(dp(12), dp(10), dp(12), dp(10))
        }
        val inputParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = dp(10) }
        root.addView(input, inputParams)

        // 执行按钮
        val execute = Button(this).apply {
            text = "开始执行"
            isAllCaps = false
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(12).toFloat()
                setColor(0xFF4D6BFF.toInt())
            }
            isEnabled = names.isNotEmpty()
            setOnClickListener {
                val prompt = input.text.toString().trim()
                if (prompt.isEmpty()) {
                    Toast.makeText(this@AiOverlayService, "请输入需求", Toast.LENGTH_SHORT).show()
                    return@setOnClickListener
                }
                val index = projectSpinner.selectedItemPosition
                val projectPath = projects.getOrNull(index)?.second
                submitToApp(prompt, projectPath)
            }
        }
        val buttonParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = dp(12) }
        root.addView(execute, buttonParams)

        val params = WindowManager.LayoutParams(
            dp(310),
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
            // 可获取焦点，键盘才能输入；同时开启外部点击监听
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.END
            x = dp(16)
            y = dp(96)
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE or
                WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE
        }

        try {
            wm.addView(root, params)
            panelView = root
            input.requestFocus()
            root.postDelayed({
                try {
                    val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                    imm.showSoftInput(input, InputMethodManager.SHOW_IMPLICIT)
                } catch (e: Exception) {
                    Log.e(TAG, "show keyboard failed", e)
                }
            }, 200)
        } catch (e: Exception) {
            Log.e(TAG, "add chat panel failed", e)
        }
    }

    private fun hideChatPanel() {
        try {
            panelView?.let { windowManager?.removeView(it) }
        } catch (e: Exception) {
            Log.e(TAG, "remove chat panel failed", e)
        }
        panelView = null
        try {
            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
            imm.hideSoftInputFromWindow(overlayView?.windowToken, 0)
        } catch (_: Exception) {
        }
    }

    /// 提交后在 App 内直接打开 AI 快速对话框并自动执行
    private fun submitToApp(prompt: String, projectPath: String?) {
        try {
            val intent = buildLaunchIntent(this) ?: return
            intent.putExtra(EXTRA_OPEN_AI_CHAT, true)
            intent.putExtra(EXTRA_AI_PROMPT, prompt)
            if (projectPath != null) intent.putExtra(EXTRA_AI_PROJECT, projectPath)
            hideChatPanel()
            startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "submit ai prompt failed", e)
            Toast.makeText(this, "打开 SLIPE 失败，请手动进入 App", Toast.LENGTH_SHORT).show()
        }
    }

    /// 读取 Flutter 写入的项目列表
    private fun loadProjects(): List<Pair<String, String>> {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val raw = prefs.getString("flutter.slipe_overlay_projects", null)
                ?: return emptyList()
            val array = JSONArray(raw)
            val result = mutableListOf<Pair<String, String>>()
            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                val name = item.optString("name")
                val path = item.optString("path")
                if (path.isNotBlank()) result.add(name to path)
            }
            result
        } catch (e: Exception) {
            Log.e(TAG, "load overlay projects failed", e)
            emptyList()
        }
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()
}
