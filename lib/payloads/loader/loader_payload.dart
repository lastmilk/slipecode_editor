import 'package:flutter/material.dart';

import '../../services/github_actions_templates.dart';

/// ---------------------------------------------------------------------------
/// Loader Payload 体系（三层）
///
/// - [RootPayloadSpec]  Root Payload：项目的初始环境（类似镜像）。
///   定义项目跑在哪个仓库（GitHub / Gitee）、使用哪些云平台（极验 / 阿里云）、
///   初始化什么构建环境（Flutter / Node.js）。
/// - [SystemPayloadSpec]  System Payload：Root Payload 下的一个「端」，
///   以根目录下的一个文件夹承载（官网门户 / 客户控制台 / 客服界面 /
///   运营控制台 / 技术控制台 / 开放平台 / 移动应用），并声明所用组件库
///   （ElementPlus / TDesign / Flutter …）。是一套模板化的目录结构。
/// - [BlockPayloadSpec]  Block Payload：细分功能模块（用户登录 / 隐私协议 /
///   下单购买 …），以 .md 文本放置在所属 System Payload 目录下。
///
/// 用户把三层 Payload 组装起来，AI 即可按组装结果生成更贴合需求的项目。
/// ---------------------------------------------------------------------------

/// 参数控件类型
enum PayloadParamType { text, bool, select, multiSelect }

/// Payload 参数定义（驱动可视化编辑器自动渲染表单）
class PayloadParamDef {
  final String key;
  final String label;
  final String hint;
  final String defaultValue;
  final PayloadParamType type;

  /// select / multiSelect 的可选项
  final List<String> options;

  const PayloadParamDef(
    this.key,
    this.label, {
    this.hint = '',
    this.defaultValue = '',
    this.type = PayloadParamType.text,
    this.options = const [],
  });

  Map<String, dynamic> toMap() => {
        'key': key,
        'label': label,
        'hint': hint,
        'defaultValue': defaultValue,
        'type': type.name,
        'options': options,
      };

  factory PayloadParamDef.fromMap(Map<String, dynamic> map) => PayloadParamDef(
        map['key']?.toString() ?? 'param',
        map['label']?.toString() ?? '',
        hint: map['hint']?.toString() ?? '',
        defaultValue: map['defaultValue']?.toString() ?? '',
        type: PayloadParamType.values.firstWhere(
          (t) => t.name == map['type'],
          orElse: () => PayloadParamType.text,
        ),
        options: ((map['options'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// Payload 可选图标（必须是 const IconData，避免 release 构建的图标 tree-shaking 失败）
const List<IconData> payloadIconPresets = [
  Icons.widgets_outlined,
  Icons.public,
  Icons.dashboard_outlined,
  Icons.support_agent,
  Icons.insights_outlined,
  Icons.engineering_outlined,
  Icons.api_outlined,
  Icons.smartphone,
  Icons.login,
  Icons.payment_outlined,
  Icons.analytics_outlined,
  Icons.settings_outlined,
  Icons.description_outlined,
  Icons.notifications_active_outlined,
  Icons.dark_mode_outlined,
  Icons.translate_outlined,
  Icons.translate,
  Icons.storefront_outlined,
  Icons.shield_outlined,
  Icons.privacy_tip_outlined,
  Icons.verified_user_outlined,
  Icons.shopping_cart_checkout,
  Icons.sms_outlined,
  Icons.dns_outlined,
  Icons.flutter_dash,
];

Map<String, dynamic> iconToMap(IconData icon) => {
      'iconCodePoint': icon.codePoint,
      if (icon.fontFamily != null) 'iconFontFamily': icon.fontFamily,
      if (icon.fontPackage != null) 'iconFontPackage': icon.fontPackage,
    };

IconData iconFromMap(Map<String, dynamic> map) {
  final codePoint = (map['iconCodePoint'] as num?)?.toInt() ?? 0xe1b1;
  final family = map['iconFontFamily'] as String?;
  for (final icon in payloadIconPresets) {
    if (icon.codePoint == codePoint &&
        (family == null || icon.fontFamily == family)) {
      return icon;
    }
  }
  return Icons.widgets_outlined;
}

/// 参数值工具（值统一存 String；bool 为 'true'/'false'；多选用英文逗号连接）
class PayloadParamValues {
  PayloadParamValues._();

  static String read(Map<String, String> params, PayloadParamDef def) =>
      params[def.key] ?? def.defaultValue;

  static bool readBool(Map<String, String> params, PayloadParamDef def) =>
      read(params, def) == 'true';

  static List<String> readMulti(
      Map<String, String> params, PayloadParamDef def) {
    final raw = read(params, def);
    if (raw.trim().isEmpty) return const [];
    return raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// 按定义表补齐默认值
  static Map<String, String> withDefaults(
      List<PayloadParamDef> defs, Map<String, String>? params) {
    final result = <String, String>{};
    for (final def in defs) {
      final v = params?[def.key];
      result[def.key] = (v == null || v.isEmpty) ? def.defaultValue : v;
    }
    return result;
  }
}

/// Root Payload 的环境变量定义
///
/// Root Payload 本质上 = 一组环境变量 + 一份 GitHub Actions workflow。
/// [secret] 为 true 时生成 `${{ secrets.KEY }}`，值不会写入仓库。
class RootEnvVar {
  final String key;
  final String value;
  final bool secret;
  final String description;

  const RootEnvVar({
    required this.key,
    this.value = '',
    this.secret = false,
    this.description = '',
  });

  Map<String, dynamic> toMap() => {
        'key': key,
        'value': value,
        'secret': secret,
        'description': description,
      };

  factory RootEnvVar.fromMap(Map<String, dynamic> map) => RootEnvVar(
        key: map['key']?.toString() ?? '',
        value: map['value']?.toString() ?? '',
        secret: map['secret'] == true,
        description: map['description']?.toString() ?? '',
      );
}

/// Root Payload：项目初始环境（镜像）
class RootPayloadSpec {
  final String id;
  final String name;
  final String description;
  final IconData icon;

  /// 构建环境标识：flutter / node / custom
  final String buildEnv;

  /// 构建环境展示名
  final String buildEnvLabel;

  /// GitHub Actions workflow 内容（实际构建环节使用）
  final String workflowContent;

  final List<PayloadParamDef> params;

  /// 环境变量组（自定义 Root 的核心内容）
  final List<RootEnvVar> envVars;

  /// 是否官方内置（内置项不可删除）
  final bool isBuiltin;

  const RootPayloadSpec({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.buildEnv,
    required this.buildEnvLabel,
    required this.workflowContent,
    required this.params,
    this.envVars = const [],
    this.isBuiltin = true,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        ...iconToMap(icon),
        'buildEnv': buildEnv,
        'buildEnvLabel': buildEnvLabel,
        'workflowContent': workflowContent,
        'params': params.map((e) => e.toMap()).toList(),
        'envVars': envVars.map((e) => e.toMap()).toList(),
        'isBuiltin': isBuiltin,
      };

  factory RootPayloadSpec.fromMap(Map<String, dynamic> map) => RootPayloadSpec(
        id: map['id']?.toString() ?? '',
        name: map['name']?.toString() ?? '',
        description: map['description']?.toString() ?? '',
        icon: iconFromMap(map),
        buildEnv: map['buildEnv']?.toString() ?? 'custom',
        buildEnvLabel: map['buildEnvLabel']?.toString() ?? 'Custom',
        workflowContent: map['workflowContent']?.toString() ?? '',
        params: ((map['params'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => PayloadParamDef.fromMap(e.cast<String, dynamic>()))
            .toList(),
        envVars: ((map['envVars'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => RootEnvVar.fromMap(e.cast<String, dynamic>()))
            .toList(),
        isBuiltin: false,
      );

  /// 生成 GitHub Actions 的 env 块（顶层 YAML）
  String buildEnvBlock() {
    if (envVars.isEmpty) return '';
    final buffer = StringBuffer('env:\n');
    for (final env in envVars) {
      if (env.key.trim().isEmpty) continue;
      final value = env.secret
          ? '\${{ secrets.${env.key.trim()} }}'
          : _yamlQuote(env.value);
      buffer.writeln('  ${env.key.trim()}: $value');
    }
    return buffer.toString();
  }

  static String _yamlQuote(String value) {
    final escaped = value
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n');
    return '"$escaped"';
  }

  /// 实际使用的 workflow（Flutter 环境复用内置模板）
  ///
  /// 支持占位符：
  /// - `{{ENV}}`：环境变量 env 块
  /// - `{{env.KEY}}`：单个环境变量（secret 用 `${{ secrets.KEY }}`）
  String resolveWorkflow([Map<String, String>? overrides]) {
    var workflow = workflowContent.isNotEmpty
        ? workflowContent
        : GitHubActionsTemplates.flutterBuildWorkflow;

    final envBlock = buildEnvBlock();
    for (final env in envVars) {
      final key = env.key.trim();
      if (key.isEmpty) continue;
      final override = overrides?[key];
      final value = (override != null && override.isNotEmpty)
          ? override
          : (env.secret ? '\${{ secrets.$key }}' : env.value);
      workflow = workflow.replaceAll('{{env.$key}}', value);
    }

    if (envBlock.isNotEmpty) {
      if (workflow.contains('{{ENV}}')) {
        workflow = workflow.replaceAll('{{ENV}}', envBlock);
      } else if (!RegExp(r'^env:\s*$', multiLine: true).hasMatch(workflow)) {
        // YAML 顶层 env 合法，放在文件最前面即可生效
        workflow = '$envBlock$workflow';
      }
    }
    return workflow;
  }
}

/// System Payload：一个「端」的模板化目录结构
class SystemPayloadSpec {
  final String id;
  final String name;
  final String description;
  final IconData icon;

  /// 默认根目录文件夹名
  final String defaultFolder;

  /// 该端声明使用的组件库选项（如 ElementPlus / TDesign / Flutter）
  final List<String> libraryOptions;
  final String defaultLibrary;

  /// 除 folder / library 之外的扩展参数
  final List<PayloadParamDef> extraParams;

  const SystemPayloadSpec({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.defaultFolder,
    required this.libraryOptions,
    required this.defaultLibrary,
    this.extraParams = const [],
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        ...iconToMap(icon),
        'defaultFolder': defaultFolder,
        'libraryOptions': libraryOptions,
        'defaultLibrary': defaultLibrary,
        'extraParams': extraParams.map((e) => e.toMap()).toList(),
      };

  factory SystemPayloadSpec.fromMap(Map<String, dynamic> map) => SystemPayloadSpec(
        id: map['id']?.toString() ?? '',
        name: map['name']?.toString() ?? '',
        description: map['description']?.toString() ?? '',
        icon: iconFromMap(map),
        defaultFolder: map['defaultFolder']?.toString() ?? 'system',
        libraryOptions: ((map['libraryOptions'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        defaultLibrary: map['defaultLibrary']?.toString() ?? '',
        extraParams: ((map['extraParams'] as List?) ?? const [])
            .map((e) => PayloadParamDef.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
      );

  /// 完整参数表（目录名 + 组件库 + 扩展参数）
  List<PayloadParamDef> get params => [
        PayloadParamDef(
          'folder',
          '目录名',
          hint: '根目录下的文件夹名',
          defaultValue: defaultFolder,
        ),
        PayloadParamDef(
          'library',
          '组件库',
          defaultValue: defaultLibrary,
          type: PayloadParamType.select,
          options: libraryOptions,
        ),
        ...extraParams,
      ];
}

/// Block Payload：细分功能模块（.md 文本）
class BlockPayloadSpec {
  final String id;
  final String name;
  final String description;
  final IconData icon;

  /// 限定适用的 System Payload id（空 = 全部适用）
  final List<String> applicableSystems;

  final List<PayloadParamDef> params;

  /// Markdown 模板。支持占位符：
  /// - `{{param_xxx}}`：参数值
  /// - `{{PARAMS_TABLE}}`：全部参数生成的表格
  final String markdownTemplate;

  const BlockPayloadSpec({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    this.applicableSystems = const [],
    this.params = const [],
    required this.markdownTemplate,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        ...iconToMap(icon),
        'applicableSystems': applicableSystems,
        'params': params.map((e) => e.toMap()).toList(),
        'markdownTemplate': markdownTemplate,
      };

  factory BlockPayloadSpec.fromMap(Map<String, dynamic> map) => BlockPayloadSpec(
        id: map['id']?.toString() ?? '',
        name: map['name']?.toString() ?? '',
        description: map['description']?.toString() ?? '',
        icon: iconFromMap(map),
        applicableSystems: ((map['applicableSystems'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        params: ((map['params'] as List?) ?? const [])
            .map((e) => PayloadParamDef.fromMap((e as Map).cast<String, dynamic>()))
            .toList(),
        markdownTemplate: map['markdownTemplate']?.toString() ?? '',
      );

  /// 是否可用于指定 System Payload
  bool appliesTo(String systemId) =>
      applicableSystems.isEmpty || applicableSystems.contains(systemId);
}

/// ---------------------------------------------------------------------------
/// 内置 Root Payload
/// ---------------------------------------------------------------------------

const _paramGitHost = PayloadParamDef(
  'git_host',
  '代码仓库',
  defaultValue: 'github',
  type: PayloadParamType.select,
  options: ['github', 'gitee', 'none'],
);
const _paramGeetest = PayloadParamDef(
  'use_geetest',
  '接入极验',
  hint: '行为验证 / 人机校验',
  defaultValue: 'true',
  type: PayloadParamType.bool,
);
const _paramAliyun = PayloadParamDef(
  'use_aliyun',
  '接入阿里云',
  hint: '短信 / OSS / 凭据部署',
  defaultValue: 'true',
  type: PayloadParamType.bool,
);

/// Node 云镜像的默认 workflow（Node 20 构建环境）
const String kLoaderNodeWorkflow = r'''
name: SLIPE Loader Build

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      build_type:
        description: '构建类型'
        required: true
        type: choice
        default: 'release'
        options:
          - release

jobs:
  build-loader:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Build systems
        run: |
          set -e
          for dir in */ ; do
            if [ -f "$dir/package.json" ]; then
              echo "==> building $dir"
              (cd "$dir" && npm install --no-audit --no-fund && npm run build --if-present)
            fi
          done

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: slipe-${{ inputs.build_type || 'release' }}
          path: |
            .
            !**/node_modules
          if-no-files-found: error
''';

class RootPayloadRegistry {
  RootPayloadRegistry._();

  /// 官方内置 Root Payload（不可删除）
  static const List<RootPayloadSpec> builtin = [
    RootPayloadSpec(
      id: 'flutter_cloud',
      name: 'Flutter 云镜像',
      description: 'GitHub 仓库 + 极验/阿里云凭据 + Flutter 构建环境，适合移动应用类项目',
      icon: Icons.flutter_dash,
      buildEnv: 'flutter',
      buildEnvLabel: 'Flutter (stable)',
      workflowContent: '', // 运行时取 GitHubActionsTemplates.flutterBuildWorkflow
      params: [
        _paramGitHost,
        _paramGeetest,
        _paramAliyun,
        PayloadParamDef(
          'flutter_channel',
          'Flutter 通道',
          defaultValue: 'stable',
          type: PayloadParamType.select,
          options: ['stable', 'beta'],
        ),
      ],
    ),
    RootPayloadSpec(
      id: 'node_cloud',
      name: 'Node.js 云镜像',
      description: 'GitHub 仓库 + 极验/阿里云凭据 + Node.js 20 构建环境，适合多端 Web 项目',
      icon: Icons.dns_outlined,
      buildEnv: 'node',
      buildEnvLabel: 'Node.js 20',
      workflowContent: kLoaderNodeWorkflow,
      params: [
        _paramGitHost,
        _paramGeetest,
        _paramAliyun,
        PayloadParamDef(
          'node_version',
          'Node 版本',
          defaultValue: '20',
        ),
      ],
    ),
  ];

  static RootPayloadSpec byId(String? id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return all.first;
  }

  static final List<RootPayloadSpec> _custom = [];

  /// 内置 + 用户自定义（顺序：内置在前，自定义在后）
  static List<RootPayloadSpec> get all => [...builtin, ..._custom];

  static List<RootPayloadSpec> get custom => List.unmodifiable(_custom);

  /// 注入用户自定义 Root（由 CustomPayloadService 调用）
  static void setCustom(List<RootPayloadSpec> specs) {
    _custom
      ..clear()
      ..addAll(specs);
  }

  static bool isBuiltin(String id) => builtin.any((s) => s.id == id);
}

/// ---------------------------------------------------------------------------
/// 内置 System Payload（对应根目录下的文件夹）
/// ---------------------------------------------------------------------------

const _webLibraries = ['ElementPlus', 'TDesign', '原生 HTML'];

class SystemPayloadRegistry {
  SystemPayloadRegistry._();

  /// 官方内置（Root 之外，System 也允许用户自建，内置作为默认模板）
  static const List<SystemPayloadSpec> builtin = [
    SystemPayloadSpec(
      id: 'portal',
      name: '官网门户',
      description: '对外的品牌官网 / 产品门户页',
      icon: Icons.public,
      defaultFolder: 'portal',
      libraryOptions: _webLibraries,
      defaultLibrary: 'ElementPlus',
      extraParams: [
        PayloadParamDef(
          'seo',
          'SEO 优化',
          defaultValue: 'true',
          type: PayloadParamType.bool,
        ),
      ],
    ),
    SystemPayloadSpec(
      id: 'console',
      name: '客户控制台',
      description: '面向最终用户的自助控制台',
      icon: Icons.dashboard_outlined,
      defaultFolder: 'console',
      libraryOptions: _webLibraries,
      defaultLibrary: 'ElementPlus',
    ),
    SystemPayloadSpec(
      id: 'support',
      name: '客服界面',
      description: '客服坐席使用的工作台界面',
      icon: Icons.support_agent,
      defaultFolder: 'support',
      libraryOptions: _webLibraries,
      defaultLibrary: 'TDesign',
    ),
    SystemPayloadSpec(
      id: 'ops',
      name: '运营控制台',
      description: '运营团队使用的后台管理端',
      icon: Icons.insights_outlined,
      defaultFolder: 'ops',
      libraryOptions: _webLibraries,
      defaultLibrary: 'ElementPlus',
    ),
    SystemPayloadSpec(
      id: 'tech',
      name: '技术控制台',
      description: '研发 / SRE 使用的技术管理端',
      icon: Icons.engineering_outlined,
      defaultFolder: 'tech',
      libraryOptions: _webLibraries,
      defaultLibrary: 'TDesign',
    ),
    SystemPayloadSpec(
      id: 'open',
      name: '开放平台',
      description: '面向开发者的开放平台 / API 门户',
      icon: Icons.api_outlined,
      defaultFolder: 'open',
      libraryOptions: _webLibraries,
      defaultLibrary: 'TDesign',
    ),
    SystemPayloadSpec(
      id: 'app',
      name: '移动应用',
      description: 'Flutter 跨平台移动应用端',
      icon: Icons.smartphone,
      defaultFolder: 'app',
      libraryOptions: ['Flutter'],
      defaultLibrary: 'Flutter',
    ),
  ];

  /// 用户自定义 System Payload（由 CustomPayloadService 注入）
  static final List<SystemPayloadSpec> _custom = [];

  static List<SystemPayloadSpec> get all => [...builtin, ..._custom];

  static void setCustom(List<SystemPayloadSpec> specs) {
    _custom
      ..clear()
      ..addAll(specs);
  }

  static SystemPayloadSpec byId(String? id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return all.first;
  }

  /// 是否为官方内置 Root 之外的唯一官方约束（System 可自定义）
  static bool isBuiltin(String id) => builtin.any((s) => s.id == id);
}

/// ---------------------------------------------------------------------------
/// 内置 Block Payload（.md 功能模块）
/// ---------------------------------------------------------------------------

String _blockTemplate(String title, String body) => '''
# $title

> 本文件由 SLIPE Loader 设计稿生成，是 AI 构建本模块的完整依据。

$body

## 模块参数

{{PARAMS_TABLE}}

## 验收标准

- 功能按上述参数完整实现，可直接运行
- 代码风格与同目录其它模块保持一致
- 关键交互具备 loading / 失败兜底
''';

class BlockPayloadRegistry {
  BlockPayloadRegistry._();

  static final List<BlockPayloadSpec> builtin = [
    BlockPayloadSpec(
      id: 'user_login',
      name: '用户登录模块',
      description: '登录 / 注册 / 会话管理',
      icon: Icons.login,
      params: const [
        PayloadParamDef(
          'methods',
          '登录方式',
          defaultValue: '账号密码,短信验证码',
          type: PayloadParamType.multiSelect,
          options: ['账号密码', '短信验证码', 'GitHub OAuth', '微信扫码'],
        ),
        PayloadParamDef(
          'session',
          '会话方案',
          defaultValue: 'JWT',
          type: PayloadParamType.select,
          options: ['JWT', 'Cookie Session'],
        ),
      ],
      markdownTemplate: _blockTemplate('用户登录模块', '''
## 功能点

- 登录 / 注册 / 登出完整闭环
- 登录方式：{{param_methods}}
- 会话方案：{{param_session}}
- 未登录访问受限页面时跳转登录页并携带回跳地址'''),
    ),
    BlockPayloadSpec(
      id: 'privacy_policy',
      name: '隐私协议模块',
      description: '隐私政策 / 用户协议展示与同意记录',
      icon: Icons.privacy_tip_outlined,
      params: const [
        PayloadParamDef('version', '协议版本', defaultValue: 'v1.0'),
        PayloadParamDef('effective_date', '生效日期', defaultValue: '2026-01-01'),
      ],
      markdownTemplate: _blockTemplate('隐私协议模块', '''
## 功能点

- 隐私政策与用户协议页面（当前版本：{{param_version}}，生效日期：{{param_effective_date}}）
- 首次使用弹窗征得同意，记录同意版本与时间
- 协议升级后重新征得同意'''),
    ),
    BlockPayloadSpec(
      id: 'order_checkout',
      name: '下单购买模块',
      description: '商品下单 / 支付 / 订单查询',
      icon: Icons.shopping_cart_checkout,
      params: const [
        PayloadParamDef(
          'payment',
          '支付方式',
          defaultValue: '支付宝,微信支付',
          type: PayloadParamType.multiSelect,
          options: ['支付宝', '微信支付', 'Stripe'],
        ),
        PayloadParamDef('currency', '结算货币', defaultValue: 'CNY'),
      ],
      markdownTemplate: _blockTemplate('下单购买模块', '''
## 功能点

- 商品确认页 → 提交订单 → 支付 → 结果回跳
- 支付方式：{{param_payment}}；结算货币：{{param_currency}}
- 订单列表与订单详情页，支持状态轮询'''),
    ),
    BlockPayloadSpec(
      id: 'captcha',
      name: '极验验证模块',
      description: '极验行为验证人机校验',
      icon: Icons.verified_user_outlined,
      params: const [
        PayloadParamDef(
          'scene',
          '应用场景',
          defaultValue: '登录,注册',
          type: PayloadParamType.multiSelect,
          options: ['登录', '注册', '下单', '敏感操作'],
        ),
      ],
      markdownTemplate: _blockTemplate('极验验证模块', '''
## 功能点

- 在 {{param_scene}} 场景接入极验行为验证
- 验证凭据由后端二次校验，前端仅采集
- 验证加载失败时降级为图形验证码并提示重试'''),
    ),
    BlockPayloadSpec(
      id: 'oss_upload',
      name: 'OSS 上传模块',
      description: '阿里云 OSS 文件直传',
      icon: Icons.cloud_upload_outlined,
      params: const [
        PayloadParamDef('bucket', 'Bucket', defaultValue: 'my-bucket'),
        PayloadParamDef('region', '地域', defaultValue: 'oss-cn-hangzhou'),
      ],
      markdownTemplate: _blockTemplate('OSS 上传模块', '''
## 功能点

- 通过 STS 临时凭据直传阿里云 OSS（Bucket：{{param_bucket}}，地域：{{param_region}}）
- 支持进度显示、失败重试与大小 / 类型校验
- 凭据统一从服务端获取，前端不硬编码密钥'''),
    ),
    BlockPayloadSpec(
      id: 'sms_verify',
      name: '短信验证码模块',
      description: '阿里云短信验证码下发与校验',
      icon: Icons.sms_outlined,
      params: const [
        PayloadParamDef('sign_name', '短信签名', defaultValue: 'SLIPE'),
        PayloadParamDef('template_code', '模板 CODE', defaultValue: 'SMS_000000'),
      ],
      markdownTemplate: _blockTemplate('短信验证码模块', '''
## 功能点

- 阿里云短信下发验证码（签名：{{param_sign_name}}，模板：{{param_template_code}}）
- 60 秒倒计时重发、频控与错误提示
- 与登录 / 注册流程联动'''),
    ),
    BlockPayloadSpec(
      id: 'i18n',
      name: '多语言模块',
      description: '多语言切换与文案管理',
      icon: Icons.translate,
      params: const [
        PayloadParamDef('languages', '语言列表', defaultValue: 'zh-CN,en'),
      ],
      markdownTemplate: _blockTemplate('多语言模块', '''
## 功能点

- 支持语言：{{param_languages}}
- 语言切换入口与本地记忆
- 文案统一走语言包，禁止硬编码'''),
    ),
    BlockPayloadSpec(
      id: 'dark_theme',
      name: '深色主题模块',
      description: '明暗主题切换',
      icon: Icons.dark_mode_outlined,
      markdownTemplate: _blockTemplate('深色主题模块', '''
## 功能点

- 明 / 暗 / 跟随系统三种模式
- 主题选择本地持久化
- 全页面无刺眼白闪'''),
    ),
    BlockPayloadSpec(
      id: 'notify',
      name: '消息通知模块',
      description: '站内信 / 邮件 / 短信通知',
      icon: Icons.notifications_active_outlined,
      params: const [
        PayloadParamDef(
          'channels',
          '通知渠道',
          defaultValue: '站内信',
          type: PayloadParamType.multiSelect,
          options: ['站内信', '邮件', '短信'],
        ),
      ],
      markdownTemplate: _blockTemplate('消息通知模块', '''
## 功能点

- 通知渠道：{{param_channels}}
- 通知中心列表（已读 / 未读）
- 关键业务事件触发通知'''),
    ),
    BlockPayloadSpec(
      id: 'api_docs',
      name: 'API 文档模块',
      description: '开放接口文档与调试台',
      icon: Icons.description_outlined,
      applicableSystems: const ['open', 'tech'],
      markdownTemplate: _blockTemplate('API 文档模块', '''
## 功能点

- 接口文档按分组展示，支持搜索
- 在线调试台（携带鉴权信息发起真实请求）
- 错误码总表与示例代码'''),
    ),
  ];

  /// 用户自定义 Block Payload（由 CustomPayloadService 注入）
  static final List<BlockPayloadSpec> _custom = [];

  static List<BlockPayloadSpec> get all => [...builtin, ..._custom];

  static void setCustom(List<BlockPayloadSpec> specs) {
    _custom
      ..clear()
      ..addAll(specs);
  }

  static BlockPayloadSpec byId(String? id) {
    for (final spec in all) {
      if (spec.id == id) return spec;
    }
    return all.first;
  }

  /// 某 System Payload 可用的 Block 列表
  static List<BlockPayloadSpec> forSystem(String systemId) =>
      all.where((b) => b.appliesTo(systemId)).toList();

  static bool isBuiltin(String id) => builtin.any((b) => b.id == id);
}
