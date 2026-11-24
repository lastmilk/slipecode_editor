import 'package:flutter/material.dart';

/// 全局导航 Key：供非 Widget 上下文（如 AI 审批）弹出对话框使用
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 全局应用内通知，供 Lua ui.notify 等无页面上下文的服务使用。
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 当前界面上可见的 AiChatScreen 数量。
///
/// 用于判断审批请求能否用聊天页内联卡片展示；为 0 时改为弹出全局对话框，
/// 避免后台任务等待一个用户看不见的审批卡片。
int aiChatVisibleCount = 0;
