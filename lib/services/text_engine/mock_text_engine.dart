import 'text_engine.dart';

/// 概念版本地预览引擎。
///
/// 仅用于打通 Text 工作台交互链路：不读写真实 Office 文件、不发起网络请求，
/// 所有操作直接返回成功提示。正式保真编辑由 OnlyOffice 引擎提供。
class MockTextEngine implements TextEngine {
  static const String engineId = 'mock';

  /// 概念版统一提示文案。
  static const String conceptNote =
      '概念版：本地预览已就绪，正式保真编辑将由 OnlyOffice 提供';

  @override
  String get id => engineId;

  @override
  String get displayName => '本地预览';

  @override
  TextEngineCapability get capabilities => const TextEngineCapability.full();

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<TextEngineResult> openDocument(
    String path, {
    bool readOnly = false,
  }) async {
    try {
      final trimmed = path.trim();
      if (trimmed.isEmpty) {
        return TextEngineResult.failure('未提供文档路径，无法打开本地预览。');
      }
      final mode = readOnly ? '只读预览' : '本地预览';
      return TextEngineResult.success(
        '$mode已打开：$trimmed\n$conceptNote',
        documentPath: trimmed,
      );
    } catch (e) {
      return TextEngineResult.failure('本地预览打开失败：$e');
    }
  }

  @override
  Future<TextEngineResult> createDocument(TextDocumentType type) async {
    try {
      return TextEngineResult.success(
        '已创建「${type.label}」预览（.${type.extension}）。\n$conceptNote',
      );
    } catch (e) {
      return TextEngineResult.failure('创建「${type.label}」预览失败：$e');
    }
  }

  @override
  Future<TextEngineResult> exportPdf(String path) async {
    try {
      final trimmed = path.trim();
      if (trimmed.isEmpty) {
        return TextEngineResult.failure('未提供导出目标路径，无法导出 PDF。');
      }
      return TextEngineResult.success(
        '已生成 PDF 导出预览：$trimmed\n$conceptNote',
        documentPath: trimmed,
      );
    } catch (e) {
      return TextEngineResult.failure('导出 PDF 失败：$e');
    }
  }
}
