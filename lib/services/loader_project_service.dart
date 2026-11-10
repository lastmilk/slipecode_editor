import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/design_draft.dart';
import '../payloads/loader/loader_payload.dart';
import 'github_actions_templates.dart';

/// Loader 项目引擎
///
/// 把「Root + System + Block」三层 Payload 的组装结果（设计稿）
/// 落成磁盘上的项目骨架：
///
/// ```
/// <project>/
/// ├─ .slipe.json                 # payload = loader 标记
/// ├─ loader.json                 # 机器可读的完整组装清单（Vibe 载体）
/// ├─ PAYLOAD.md                  # 人 / AI 可读的完整 Vibe 文档
/// ├─ README.md / .gitignore
/// ├─ .github/workflows/...       # Root Payload 的构建环境
/// └─ <system>/                   # 每个 System Payload 一个文件夹
///    ├─ SYSTEM.md                # 该端的说明与参数
///    └─ blocks/<block>.md        # 每个 Block Payload 一个 .md 文本
/// ```
///
/// Loader 项目的构建分两大环节：
/// 1. AI 介入：设计稿已包含完整 Vibe，Agent 按上述文档无感生成全部代码；
/// 2. 实际构建：推送后由 Root Payload 定义的云端构建环境出包。
class LoaderProjectService {
  /// 清单文件名
  static const manifestName = 'loader.json';

  /// 判断目录是否为 Loader 项目
  static Future<bool> isLoaderProject(String projectDir) async {
    try {
      final marker = File(p.join(projectDir, '.slipe.json'));
      if (!await marker.exists()) return false;
      final data = jsonDecode(await marker.readAsString());
      return data is Map && data['payload'] == 'loader';
    } catch (_) {
      return false;
    }
  }

  /// 读取 loader.json 清单（非 Loader 项目返回 null）
  static Future<Map<String, dynamic>?> readManifest(String projectDir) async {
    try {
      final file = File(p.join(projectDir, manifestName));
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  /// 从组装结果创建 Loader 项目
  ///
  /// [draft] 非空表示「采用设计稿」（会记录 draftId / draftName）；
  /// [root] / [systems] 取自该设计稿。
  Stream<String> createLoaderProject({
    required String projectName,
    required String targetPath,
    String org = 'com.example',
    DesignDraft? draft,
    RootPayloadInstance? root,
    List<SystemPayloadInstance>? systems,
  }) async* {
    final rootInstance = draft?.root ?? root;
    final systemList = draft?.systems ?? systems ?? const [];
    if (rootInstance == null) {
      throw ArgumentError('缺少 Root Payload，无法创建 Loader 项目');
    }

    final rootSpec = RootPayloadRegistry.byId(rootInstance.specId);
    final rootParams =
        PayloadParamValues.withDefaults(rootSpec.params, rootInstance.params);

    yield '> 使用「${rootSpec.name}」Root Payload 创建 Loader 项目\n';
    yield '  项目: $projectName\n  位置: $targetPath\n';
    if (draft != null) yield '  设计稿: ${draft.name}\n';

    // 目标目录检查
    final dir = Directory(targetPath);
    if (await dir.exists()) {
      if (!await dir.list(followLinks: false).isEmpty) {
        throw Exception('目标目录已存在且不为空: $targetPath');
      }
    } else {
      await dir.create(recursive: true);
      yield '创建目录: $targetPath\n';
    }

    // 规范化 System：补默认值 + 目录去重
    final normalized = <_NormalizedSystem>[];
    final usedFolders = <String>{};
    for (final sys in systemList) {
      final spec = SystemPayloadRegistry.byId(sys.specId);
      final params =
          PayloadParamValues.withDefaults(spec.params, sys.params);
      var folder = _sanitizeFolder(params['folder'] ?? spec.defaultFolder);
      if (folder.isEmpty) folder = spec.defaultFolder;
      var unique = folder;
      var n = 2;
      while (usedFolders.contains(unique)) {
        unique = '${folder}_$n';
        n++;
      }
      usedFolders.add(unique);
      params['folder'] = unique;

      final blocks = <_NormalizedBlock>[];
      for (final b in sys.blocks) {
        final bSpec = BlockPayloadRegistry.byId(b.specId);
        final bParams =
            PayloadParamValues.withDefaults(bSpec.params, b.params);
        blocks.add(_NormalizedBlock(bSpec, bParams));
      }
      normalized.add(_NormalizedSystem(sys.nodeId, spec, params, blocks));
    }

    // 1) .slipe.json
    await _write(targetPath, '.slipe.json', '''
{
  "project_name": "$projectName",
  "org": "$org",
  "template": "loader",
  "payload": "loader",
  "created_by": "slipe"
}
''');
    yield '  + .slipe.json\n';

    // nodeId → (blockInstanceId → blockSpecId)，用于解析边的 Block 粒度
    final blockSpecByNode = <String, Map<String, String>>{
      for (final s in (draft?.systems ?? const <SystemPayloadInstance>[]))
        s.nodeId: {
          for (final b in s.blocks) b.instanceId: b.specId,
        },
    };

    // 2) loader.json（机器可读清单）
    final manifest = <String, dynamic>{
      'version': 1,
      'kind': 'slipe-loader',
      'name': projectName,
      'org': org,
      if (draft != null) 'draftId': draft.id,
      if (draft != null) 'draftName': draft.name,
      'root': {
        'id': rootSpec.id,
        'params': rootParams,
        if (rootSpec.envVars.isNotEmpty)
          'envVars': rootSpec.envVars.map((e) => e.toMap()).toList(),
      },
      'systems': [
        for (final s in normalized)
          {
            'nodeId': s.nodeId,
            'id': s.spec.id,
            'folder': s.folder,
            'params': s.params,
            'blocks': [
              for (final b in s.blocks)
                {'id': b.spec.id, 'params': b.params},
            ],
          },
      ],
      'edges': [
        for (final e in (draft?.edges ?? const <DesignEdge>[]))
          {
            'id': e.id,
            'from': e.fromNodeId,
            'fromBlock': blockSpecByNode[e.fromNodeId]?[e.fromBlockId],
            'to': e.toNodeId,
            'toBlock': e.toBlockId == null
                ? null
                : blockSpecByNode[e.toNodeId]?[e.toBlockId!],
            'label': e.label,
            'kind': e.kind.name,
          },
      ],
      'created_by': 'slipe',
    };
    await _write(targetPath, manifestName,
        const JsonEncoder.withIndent('  ').convert(manifest));
    yield '  + $manifestName\n';

    // 3) PAYLOAD.md（完整 Vibe 文档）
    await _write(
      targetPath,
      'PAYLOAD.md',
      _composePayloadDoc(projectName, rootSpec, rootParams, normalized, draft),
    );
    yield '  + PAYLOAD.md\n';

    // 4) README / .gitignore
    await _write(targetPath, 'README.md', '''
# $projectName

由 SLIPE Loader 创建的多端项目。组装说明见 [PAYLOAD.md](PAYLOAD.md)，
机器可读清单见 [loader.json]($manifestName)。

## 构建

1. **AI 介入**：打开 SLIPE 编辑器 → Loader 构建 → 开始 AI 介入，
   Agent 会按设计稿生成全部端的代码。
2. **实际构建**：推送到远程仓库后，由 Root Payload
   「${rootSpec.name}」定义的 ${rootSpec.buildEnvLabel} 云端环境完成出包。
''');
    await _write(targetPath, '.gitignore', '''
node_modules/
build/
dist/
.dart_tool/
.packages
*.log
.DS_Store
''');
    yield '  + README.md\n  + .gitignore\n';

    // 5) Root Payload 构建环境（workflow + 环境变量示例）
    final workflowPath = GitHubActionsTemplates.workflowPath;
    await _write(targetPath, workflowPath, rootSpec.resolveWorkflow());
    yield '  + $workflowPath\n';

    if (rootSpec.envVars.isNotEmpty) {
      final envExample = StringBuffer()
        ..writeln('# 由 Root Payload「${rootSpec.name}」生成')
        ..writeln('# Secret 变量请在 GitHub 仓库 Settings → Secrets 中配置')
        ..writeln();
      for (final env in rootSpec.envVars) {
        if (env.description.isNotEmpty) {
          envExample.writeln('# ${env.description}');
        }
        envExample.writeln(
          '${env.key}=${env.secret ? '' : env.value}',
        );
      }
      await _write(targetPath, '.env.example', envExample.toString());
      yield '  + .env.example\n';
    }

    // 6) 每个 System Payload：目录 + SYSTEM.md + blocks/*.md
    for (final s in normalized) {
      await _write(
        targetPath,
        p.join(s.folder, 'SYSTEM.md'),
        _composeSystemDoc(s),
      );
      yield '  + ${s.folder}/SYSTEM.md\n';
      for (final b in s.blocks) {
        await _write(
          targetPath,
          p.join(s.folder, 'blocks', '${b.spec.id}.md'),
          _renderBlockMarkdown(b.spec, b.params),
        );
        yield '  + ${s.folder}/blocks/${b.spec.id}.md\n';
      }
    }

    final blockCount =
        normalized.fold<int>(0, (sum, s) => sum + s.blocks.length);
    yield '\n✓ Loader 骨架生成完成：'
        '${normalized.length} 个 System Payload，$blockCount 个 Block Payload。\n';
    yield '下一步：打开项目 → Loader 构建，先「AI 介入」再「实际构建」。\n';
  }

  /// 组装「AI 介入」环节的 Vibe 提示词
  ///
  /// 设计稿本身已包含完整 Vibe，这里把它转成给 Agent 的一次性总指令，
  /// 让 AI 无感地完成整个项目。
  static Future<String> composeVibePrompt(String projectDir) async {
    final manifest = await readManifest(projectDir);
    if (manifest == null) {
      throw StateError('当前项目不是 Loader 项目（缺少 $manifestName）');
    }
    final root = (manifest['root'] as Map).cast<String, dynamic>();
    final rootSpec = RootPayloadRegistry.byId(root['id'] as String?);
    final systems = ((manifest['systems'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();

    final buffer = StringBuffer()
      ..writeln('你是本项目的总构建 Agent，现在执行 Loader 项目的「AI 介入」环节。')
      ..writeln('设计稿已包含完整 Vibe，请无感地完成整个项目：')
      ..writeln()
      ..writeln('1. 先完整阅读 PAYLOAD.md 与 loader.json，'
          '再逐个阅读各端目录下的 SYSTEM.md 与 blocks/*.md；')
      ..writeln('2. 按 Root Payload「${rootSpec.name}」'
          '（构建环境：${rootSpec.buildEnvLabel}）初始化每个端为可独立运行的子项目'
          '（补齐 package.json / pubspec.yaml 等必需文件）；')
      ..writeln('3. 严格按每个 Block 的 .md 文本与其参数实现功能模块，'
          '组件库选择以各 SYSTEM.md 为准；')
      ..writeln(rootSpec.envVars.isEmpty
          ? '4. 各端之间可共享的约定（主题色、接口基地址、凭据获取方式）保持一致；'
          : '4. 环境变量与 Secrets 以 .github/workflows 与 .env.example 为准，'
              '代码中通过环境变量读取，不要硬编码密钥；')
      ..writeln('5. 各端之间可共享的约定（主题色、接口基地址、凭据获取方式）保持一致；')
      ..writeln('6. 全部完成后，输出每个端生成的文件清单与后续「实际构建」的注意事项。')
      ..writeln()
      ..writeln('项目名：${manifest['name']}。当前项目根目录即工作目录。')
      ..writeln()
      ..writeln('端的清单（共 ${systems.length} 个）：');
    for (final s in systems) {
      final sysSpec = SystemPayloadRegistry.byId(s['id'] as String?);
      final blocks = ((s['blocks'] as List?) ?? const [])
          .map((b) => BlockPayloadRegistry.byId(
                  (b as Map)['id'] as String?)
              .name)
          .join('、');
      buffer.writeln('- ${sysSpec.name} → ${s['folder']}/'
          '${blocks.isEmpty ? '' : '（Block：$blocks）'}');
    }

    final edgeList = ((manifest['edges'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    if (edgeList.isNotEmpty) {
      final nameByNode = <String, String>{
        for (final s in systems)
          if (s['nodeId'] != null)
            s['nodeId'].toString():
                SystemPayloadRegistry.byId(s['id'] as String?).name,
      };
      buffer
        ..writeln()
        ..writeln('端之间的页面跳转与依赖关系（有向图，生成代码时必须落实）：');
      for (final e in edgeList) {
        final from = nameByNode[e['from']?.toString()] ?? '未知端';
        final to = nameByNode[e['to']?.toString()] ?? '未知端';
        final fromBlockId = e['fromBlock']?.toString();
        final toBlockId = e['toBlock']?.toString();
        final fromName = fromBlockId == null
            ? from
            : '$from.${BlockPayloadRegistry.byId(fromBlockId).name}';
        final toName = toBlockId == null
            ? to
            : '$to.${BlockPayloadRegistry.byId(toBlockId).name}';
        final kind = e['kind'] == 'depend' ? '依赖' : '跳转';
        final label = e['label']?.toString() ?? '';
        buffer.writeln(
            '- $fromName —$kind→ $toName${label.isEmpty ? '' : '（$label）'}');
      }
    }
    return buffer.toString();
  }

  // ---------------------------------------------------------------------------
  // 文档生成
  // ---------------------------------------------------------------------------

  String _composePayloadDoc(
    String projectName,
    RootPayloadSpec rootSpec,
    Map<String, String> rootParams,
    List<_NormalizedSystem> systems,
    DesignDraft? draft,
  ) {
    final buffer = StringBuffer()
      ..writeln('# $projectName · Loader 组装文档')
      ..writeln()
      ..writeln('> 本文件由 SLIPE 根据${draft != null ? '设计稿「${draft.name}」' : '组装结果'}'
          '自动生成，是项目的完整 Vibe 载体。')
      ..writeln('> AI 介入环节将按本文件与各 SYSTEM.md / blocks/*.md 完成全部代码。')
      ..writeln()
      ..writeln('## Root Payload：${rootSpec.name}（`${rootSpec.id}`）')
      ..writeln()
      ..writeln(rootSpec.description)
      ..writeln()
      ..writeln('- 代码仓库：${rootParams['git_host'] ?? 'github'}')
      ..writeln('- 构建环境：${rootSpec.buildEnvLabel}')
      ..writeln()
      ..writeln(_paramsTable(rootSpec.params, rootParams))
      ..writeln();
    if (rootSpec.envVars.isNotEmpty) {
      buffer
        ..writeln('### 环境变量')
        ..writeln()
        ..writeln('| Key | 类型 | 说明 |')
        ..writeln('| --- | --- | --- |');
      for (final env in rootSpec.envVars) {
        buffer.writeln(
          '| `${env.key}` | ${env.secret ? 'Secret' : '明文'} | ${env.description} |',
        );
      }
      buffer.writeln();
    }
    buffer
      ..writeln('## System Payload（共 ${systems.length} 个）')
      ..writeln();
    var i = 1;
    for (final s in systems) {
      buffer
        ..writeln('### $i. ${s.spec.name} → `${s.folder}/`')
        ..writeln()
        ..writeln('- 组件库：${s.params['library']}')
        ..writeln('- 说明：${s.spec.description}')
        ..writeln()
        ..writeln(_paramsTable(s.spec.params, s.params))
        ..writeln();
      if (s.blocks.isEmpty) {
        buffer.writeln('（未编排 Block Payload）');
      } else {
        buffer.writeln('Block Payload：');
        for (final b in s.blocks) {
          buffer.writeln(
              '- [${b.spec.name}](${s.folder}/blocks/${b.spec.id}.md)');
        }
      }
      buffer.writeln();
      i++;
    }
    // 有向图：页面跳转与依赖关系
    final edges = draft?.edges ?? const <DesignEdge>[];
    buffer
      ..writeln('## 页面跳转与依赖关系（有向图）')
      ..writeln();
    if (edges.isEmpty) {
      buffer.writeln('（未编排端之间的跳转 / 依赖关系）');
    } else {
      final nameByNode = <String, String>{
        for (final s in systems) s.nodeId: s.spec.name,
      };
      // nodeId → (blockInstanceId → blockSpecName)
      final blockNameByNode = <String, Map<String, String>>{
        for (final s in (draft?.systems ?? const <SystemPayloadInstance>[]))
          s.nodeId: {
            for (final b in s.blocks)
              b.instanceId: BlockPayloadRegistry.byId(b.specId).name,
          },
      };
      for (final e in edges) {
        final from = nameByNode[e.fromNodeId] ?? '未知端';
        final to = nameByNode[e.toNodeId] ?? '未知端';
        final fromBlockName =
            blockNameByNode[e.fromNodeId]?[e.fromBlockId];
        final toBlockName =
            e.toBlockId == null ? null : blockNameByNode[e.toNodeId]?[e.toBlockId!];
        final fromLabel =
            fromBlockName == null ? from : '$from.$fromBlockName';
        final toLabel = toBlockName == null ? to : '$to.$toBlockName';
        final arrow = e.kind == DesignEdgeKind.depend ? '依赖' : '跳转';
        buffer.writeln('- **$fromLabel** —$arrow→ **$toLabel**'
            '${e.label.isEmpty ? '' : '（${e.label}）'}');
      }
    }
    buffer
      ..writeln()
      ..writeln('## 构建环节')
      ..writeln()
      ..writeln('1. **AI 介入**：Agent 读取本文件与全部 .md 文本，'
          '无感生成各端完整代码。')
      ..writeln('2. **实际构建**：推送到 ${rootParams['git_host']} 仓库后，'
          '由 ${rootSpec.buildEnvLabel} 云端环境出包。')
      ..writeln();
    return buffer.toString();
  }

  String _composeSystemDoc(_NormalizedSystem s) {
    final buffer = StringBuffer()
      ..writeln('# ${s.spec.name}（System Payload: `${s.spec.id}`）')
      ..writeln()
      ..writeln('${s.spec.description}')
      ..writeln()
      ..writeln('- 目录：`${s.folder}/`')
      ..writeln('- 组件库：${s.params['library']}')
      ..writeln()
      ..writeln('## 参数')
      ..writeln()
      ..writeln(_paramsTable(s.spec.params, s.params))
      ..writeln()
      ..writeln('## 目录约定')
      ..writeln()
      ..writeln('本文件夹是「${s.spec.name}」端的独立子项目，'
          'AI 介入时将在此生成完整可运行代码；'
          '功能模块以 `blocks/` 下的 .md 文本为准。')
      ..writeln()
      ..writeln('## Block Payload（共 ${s.blocks.length} 个）')
      ..writeln();
    if (s.blocks.isEmpty) {
      buffer.writeln('（未编排 Block Payload）');
    } else {
      for (final b in s.blocks) {
        buffer.writeln('- [${b.spec.name}](blocks/${b.spec.id}.md)'
            ' — ${b.spec.description}');
      }
    }
    buffer.writeln();
    return buffer.toString();
  }

  /// 渲染 Block 的 .md 文本（替换参数占位符 + 参数表）
  String _renderBlockMarkdown(
      BlockPayloadSpec spec, Map<String, String> params) {
    var text = spec.markdownTemplate;
    for (final def in spec.params) {
      text = text.replaceAll(
          '{{param_${def.key}}}', params[def.key] ?? def.defaultValue);
    }
    text = text.replaceAll('{{PARAMS_TABLE}}',
        _paramsTable(spec.params, params).trimRight());
    return '$text\n';
  }

  String _paramsTable(
      List<PayloadParamDef> defs, Map<String, String> params) {
    if (defs.isEmpty) return '（无参数）';
    final buffer = StringBuffer()
      ..writeln('| 参数 | 值 |')
      ..writeln('| --- | --- |');
    for (final def in defs) {
      final value = params[def.key] ?? def.defaultValue;
      buffer.writeln('| ${def.label} | $value |');
    }
    return buffer.toString();
  }

  String _sanitizeFolder(String raw) {
    final cleaned =
        raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
    return cleaned.replaceAll(RegExp(r'_+'), '_');
  }

  Future<void> _write(String root, String relative, String content) async {
    final file = File(p.join(root, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
  }
}

class _NormalizedSystem {
  final SystemPayloadSpec spec;
  final Map<String, String> params;
  final List<_NormalizedBlock> blocks;

  final String nodeId;

  const _NormalizedSystem(this.nodeId, this.spec, this.params, this.blocks);

  String get folder => params['folder'] ?? spec.defaultFolder;
}

class _NormalizedBlock {
  final BlockPayloadSpec spec;
  final Map<String, String> params;

  const _NormalizedBlock(this.spec, this.params);
}
