import 'mock_text_engine.dart';
import 'onlyoffice_engine.dart';

/// 文本编辑引擎抽象层。
///
/// 概念版默认使用 [MockTextEngine]（本地预览），正式版锁定 OnlyOffice Docs 嵌入。
/// 调用方只依赖本文件的接口与注册表，不直接感知具体实现，
/// 后续切换引擎时无需改动 Text 工作台。
///
/// 技术选型结论：纯 Flutter 富文本库无法提供 DOCX/XLSX/PPTX 的版式保真，
/// 正式编辑内核采用 OnlyOffice DocumentServer（WOPI/DocsAPI + WebView 承载）。

/// Text 工作台支持的文档产物类型。
enum TextDocumentType {
  word,
  ppt,
  excel,
  pdf;

  /// 中文展示名。
  String get label => switch (this) {
        TextDocumentType.word => 'Word 文档',
        TextDocumentType.ppt => 'PPT 演示',
        TextDocumentType.excel => 'Excel 表格',
        TextDocumentType.pdf => 'PDF 文档',
      };

  /// 对应文件扩展名（不含点）。
  String get extension => switch (this) {
        TextDocumentType.word => 'docx',
        TextDocumentType.ppt => 'pptx',
        TextDocumentType.excel => 'xlsx',
        TextDocumentType.pdf => 'pdf',
      };
}

/// 引擎能力声明，供工作台决定按钮是否可用。
class TextEngineCapability {
  final bool canOpen;
  final bool canCreate;
  final bool canExportPdf;

  const TextEngineCapability({
    required this.canOpen,
    required this.canCreate,
    required this.canExportPdf,
  });

  /// 打开 / 新建 / 导出全部可用。
  const TextEngineCapability.full()
      : canOpen = true,
        canCreate = true,
        canExportPdf = true;
}

/// 引擎操作结果。
///
/// 所有引擎方法都以本类型返回，不使用异常传递业务失败，
/// 避免工作台因未捕获异常而崩溃。
class TextEngineResult {
  final bool ok;
  final String message;
  final String? documentPath;

  const TextEngineResult._({
    required this.ok,
    required this.message,
    this.documentPath,
  });

  factory TextEngineResult.success(String message, {String? documentPath}) {
    return TextEngineResult._(
      ok: true,
      message: message,
      documentPath: documentPath,
    );
  }

  factory TextEngineResult.failure(String message) {
    return TextEngineResult._(ok: false, message: message);
  }
}

/// 可替换的文本编辑引擎接口。
abstract class TextEngine {
  /// 引擎唯一标识：mock / onlyoffice。
  String get id;

  /// 展示名。
  String get displayName;

  /// 能力声明。
  TextEngineCapability get capabilities;

  /// 引擎是否已完成必要配置（Mock 恒为 true）。
  Future<bool> isConfigured();

  /// 打开本地文档。
  Future<TextEngineResult> openDocument(String path, {bool readOnly = false});

  /// 新建指定类型的文档。
  Future<TextEngineResult> createDocument(TextDocumentType type);

  /// 将指定文档导出为 PDF。
  Future<TextEngineResult> exportPdf(String path);
}

/// 引擎解析结果，附带降级提示信息。
class TextEngineSelection {
  final TextEngine engine;

  /// 非空表示发生了降级（如 OnlyOffice 未配置回退到本地预览）。
  final String? fallbackMessage;

  const TextEngineSelection({required this.engine, this.fallbackMessage});

  /// 是否处于降级状态。
  bool get isFallback => fallbackMessage != null;
}

/// 引擎注册表（单例）。
///
/// 负责持有已注册引擎、记录当前选择，并在引擎不可用时安全回退到本地预览。
/// 概念版不引入 Provider，工作台直接通过 [instance] 访问。
class TextEngineRegistry {
  TextEngineRegistry._();

  static final TextEngineRegistry instance = TextEngineRegistry._();

  /// 本地预览引擎 id。
  static const String mockId = 'mock';

  /// OnlyOffice 引擎 id。
  static const String onlyOfficeId = 'onlyoffice';

  final MockTextEngine mock = MockTextEngine();
  final OnlyOfficeEngine onlyOffice = OnlyOfficeEngine();

  String _activeId = mockId;

  /// 当前选中的引擎 id。
  String get activeId => _activeId;

  /// 当前选中的引擎（默认本地预览）。
  TextEngine get active => byId(_activeId);

  /// 按 id 获取引擎，未知 id 回退到 Mock。
  TextEngine byId(String id) {
    return switch (id) {
      onlyOfficeId => onlyOffice,
      mockId => mock,
      _ => mock,
    };
  }

  /// 切换当前引擎，未知 id 视为调用方错误并抛出参数异常。
  void setActive(String engineId) {
    if (engineId != mockId && engineId != onlyOfficeId) {
      throw ArgumentError.value(engineId, 'engineId', '未知的文本编辑引擎');
    }
    _activeId = engineId;
  }

  /// 解析当前引擎：OnlyOffice 未配置时回退到本地预览并携带提示信息。
  Future<TextEngineSelection> resolveSelection() async {
    final engine = active;
    if (engine.id == mockId) {
      return TextEngineSelection(engine: engine);
    }
    try {
      if (await engine.isConfigured()) {
        return TextEngineSelection(engine: engine);
      }
    } catch (_) {
      // 配置读取失败同样按未配置处理，继续安全降级
    }
    return TextEngineSelection(
      engine: mock,
      fallbackMessage: 'OnlyOffice 引擎未配置，已回退到本地预览。'
          '请先在 Text 工作台填写服务地址与 JWT 密钥。',
    );
  }

  /// 解析当前可用引擎（只返回引擎实例，不携带降级提示）。
  Future<TextEngine> resolveActive() async {
    final selection = await resolveSelection();
    return selection.engine;
  }
}
