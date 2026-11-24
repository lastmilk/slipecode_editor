import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'text_engine.dart';

/// OnlyOffice Docs 引擎（概念版仅配置骨架）。
///
/// 安全约定（务必保持）：
/// - 服务地址为非敏感信息，存 SharedPreferences；
/// - JWT 密钥是敏感凭据，只写入 flutter_secure_storage；
/// - JWT 明文不得写入日志、SharedPreferences 或任何草稿 JSON；
/// - 本类所有对外方法都不抛出异常，失败统一返回 [TextEngineResult.failure]。
///
/// 正式接入方案（后续迭代实现，当前不引入 webview_cef 依赖）：
/// - 三端统一使用 webview_cef（Windows / macOS / Linux）承载 OnlyOffice 编辑器 iframe；
/// - DocumentServer 通过 DocsAPI/WOPI 配置 config.document.url 与 token；
/// - 本地文件需通过「本机临时静态服务 + 一次性 token」或后端中转暴露为 HTTP 地址。
class OnlyOfficeEngine implements TextEngine {
  static const String engineId = 'onlyoffice';

  /// SharedPreferences 中仅保存服务地址。
  static const String serverUrlKey = 'text_engine.onlyoffice.server_url';

  /// flutter_secure_storage 中保存 JWT 密钥。
  static const String jwtKey = 'text_engine.onlyoffice.jwt';

  /// 未配置时的统一降级提示。
  static const String notConfiguredMessage =
      'OnlyOffice 引擎未配置：请先在 Text 工作台填写服务地址与 JWT 密钥';

  /// 已配置但尚未接入嵌入时的提示。
  static const String pendingIntegrationMessage =
      'OnlyOffice 引擎已配置，嵌入 WebView 将在正式版本接入';

  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  @override
  String get id => engineId;

  @override
  String get displayName => 'OnlyOffice';

  @override
  TextEngineCapability get capabilities => const TextEngineCapability.full();

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  /// 读取服务地址；读取失败时返回空串（视为未配置）。
  Future<String> serverUrl() async {
    try {
      final prefs = await _prefs();
      return (prefs.getString(serverUrlKey) ?? '').trim();
    } catch (e) {
      debugPrint('读取 OnlyOffice 服务地址失败（按未配置处理）：$e');
      return '';
    }
  }

  /// 保存服务地址与 JWT 密钥。
  ///
  /// 密钥只写入安全存储；异常仅打印错误类型信息，绝不打印密钥内容。
  Future<void> saveConfig({
    required String serverUrl,
    required String jwtSecret,
  }) async {
    final url = serverUrl.trim();
    final secret = jwtSecret.trim();
    try {
      final prefs = await _prefs();
      await prefs.setString(serverUrlKey, url);

      if (secret.isEmpty) {
        await _secure.delete(key: jwtKey);
      } else {
        await _secure.write(key: jwtKey, value: secret);
      }
    } catch (e) {
      // 不拼接密钥，避免敏感信息进入日志
      debugPrint('保存 OnlyOffice 配置失败：$e');
    }
  }

  /// 清除全部配置。
  Future<void> clearConfig() async {
    try {
      final prefs = await _prefs();
      await prefs.remove(serverUrlKey);
      await _secure.delete(key: jwtKey);
    } catch (e) {
      debugPrint('清除 OnlyOffice 配置失败：$e');
    }
  }

  /// 读取 JWT 密钥（仅内部使用，禁止对外暴露明文）。
  Future<String> _readJwtSecret() async {
    try {
      final value = await _secure.read(key: jwtKey);
      return value?.trim() ?? '';
    } catch (e) {
      debugPrint('读取 OnlyOffice JWT 密钥失败（按未配置处理）：$e');
      return '';
    }
  }

  /// 密钥掩码：仅保留末 4 位；无密钥返回空串。
  Future<String> maskedSecret() async {
    try {
      final secret = await _readJwtSecret();
      if (secret.isEmpty) return '';
      if (secret.length <= 4) return '••••';
      return '••••${secret.substring(secret.length - 4)}';
    } catch (e) {
      debugPrint('生成 OnlyOffice 密钥掩码失败：$e');
      return '';
    }
  }

  /// 是否已完整配置（服务地址与 JWT 密钥均非空）。
  @override
  Future<bool> isConfigured() async {
    final url = await serverUrl();
    if (url.isEmpty) return false;
    final secret = await _readJwtSecret();
    return secret.isNotEmpty;
  }

  /// 便捷判断：是否已配置。
  Future<bool> get hasConfig async => isConfigured();

  @override
  Future<TextEngineResult> openDocument(
    String path, {
    bool readOnly = false,
  }) {
    return _unsupported('打开文档');
  }

  @override
  Future<TextEngineResult> createDocument(TextDocumentType type) {
    return _unsupported('新建「${type.label}」');
  }

  @override
  Future<TextEngineResult> exportPdf(String path) {
    return _unsupported('导出 PDF');
  }

  /// 概念版统一降级：未配置给出配置引导，已配置说明尚未接入嵌入。
  ///
  /// 两种情况都不发起任何网络请求。
  Future<TextEngineResult> _unsupported(String action) async {
    try {
      if (!await isConfigured()) {
        return TextEngineResult.failure(notConfiguredMessage);
      }
      // TODO(onlyoffice): 正式接入位置 —— 在此处创建 webview_cef 控制器并加载
      // DocumentServer 的 DocsAPI 页面：
      // 1. 生成本地文档的一次性 HTTP 访问地址（本机临时静态服务 + token 或后端中转）；
      // 2. 构造 DocsAPI 的 config（document.url / editorConfig.mode / token），
      //    token 使用安全存储中的 JWT 密钥签名，禁止落盘或打印；
      // 3. Windows / macOS / Linux 三端统一使用 webview_cef 承载 iframe；
      // 4. 监听文档保存事件后回写本地文件。
      return TextEngineResult.failure(pendingIntegrationMessage);
    } catch (e) {
      return TextEngineResult.failure('OnlyOffice $action失败：$e');
    }
  }
}
