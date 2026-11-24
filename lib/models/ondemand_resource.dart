import 'package:flutter/foundation.dart';

/// 按需下载的资源内核（概念版先在本地提供下载源）。
@immutable
class OnDemandResource {
  const OnDemandResource({
    required this.id,
    required this.name,
    required this.summary,
    required this.purpose,
    required this.repoUrl,
    required this.approxSize,
    required this.license,
    required this.sceneIds,
    this.required = false,
  });

  /// 资源标识，同时作为安装目录名与下载文件名。
  final String id;

  /// 展示名，如 `OnlyOffice 文档内核`。
  final String name;

  /// 一句话说明。
  final String summary;

  /// 在哪些场景中使用。
  final String purpose;

  /// 上游仓库地址（用于镜像克隆兜底）。
  final String repoUrl;

  /// 体积描述（如 `约 1.2 GB`）。
  final String approxSize;

  /// 开源许可。
  final String license;

  /// 依赖该资源的场景 id。
  final List<String> sceneIds;

  /// 是否为核心资源（缺失时提示更醒目）。
  final bool required;

  /// 加速镜像地址（通过 gh-proxy 转发 GitHub）。
  String get mirrorUrl {
    final match = RegExp(r'^https?://github\.com/(.+)$').firstMatch(repoUrl);
    final path = match?.group(1) ?? '';
    return 'https://gh-proxy.org/https://github.com/$path';
  }
}

/// 资源清单：按需下载的全部内核及其元信息。
class OnDemandResources {
  OnDemandResources._();

  static const OnDemandResource onlyOffice = OnDemandResource(
    id: 'onlyoffice',
    name: 'OnlyOffice 文档内核',
    summary: 'Word / PPT / Excel / PDF 的保真编辑与导出能力。',
    purpose: 'Text 场景',
    repoUrl: 'https://github.com/ONLYOFFICE/DocumentServer',
    approxSize: '约 1.2 GB',
    license: 'AGPL-3.0',
    sceneIds: ['text'],
    required: true,
  );

  static const OnDemandResource dify = OnDemandResource(
    id: 'dify',
    name: 'Dify 工作流内核',
    summary: '可视化编排 AI 工作流，并作为定时任务的执行引擎。',
    purpose: 'Auto 场景',
    repoUrl: 'https://github.com/langgenius/dify',
    approxSize: '约 800 MB',
    license: 'Apache-2.0（附加条款）',
    sceneIds: ['auto'],
    required: true,
  );

  static const OnDemandResource hyperFrames = OnDemandResource(
    id: 'hyperframes',
    name: 'HyperFrames 视频导出内核',
    summary: 'HeyGen 开源的 HTML 转视频渲染器，按帧合成 MP4。',
    purpose: 'VibeVideo 场景',
    repoUrl: 'https://github.com/heygen-com/hyperframes',
    approxSize: '约 150 MB',
    license: 'Apache-2.0',
    sceneIds: ['vibe_video'],
  );

  static const OnDemandResource blender = OnDemandResource(
    id: 'blender',
    name: 'Blender 3D 素材内核',
    summary: '3D 素材与画面生成；本产品使用适配修改版。',
    purpose: 'VibeVideo 场景',
    repoUrl: 'https://github.com/blender/blender',
    approxSize: '约 400 MB',
    license: 'GPL-2.0-or-later',
    sceneIds: ['vibe_video'],
  );

  static const List<OnDemandResource> all = [
    onlyOffice,
    dify,
    hyperFrames,
    blender,
  ];

  static OnDemandResource? byId(String id) {
    for (final resource in all) {
      if (resource.id == id) return resource;
    }
    return null;
  }

  /// 某个场景依赖的资源。
  static List<OnDemandResource> forScene(String sceneId) {
    return all.where((r) => r.sceneIds.contains(sceneId)).toList();
  }
}
