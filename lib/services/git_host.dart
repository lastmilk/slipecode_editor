/// 支持的 Git 托管平台
///
/// 两个平台的仓库创建、文件推送方式不同：
/// - GitHub：Git Data API，一次提交推送全部文件；构建走 GitHub Actions。
/// - Gitee：Contents API 逐文件提交；构建走 Gitee Go。
enum GitHost {
  github(
    id: 'github',
    label: 'GitHub',
    owner: 'GitHub',
    supportsIosBuild: true,
    ciName: 'GitHub Actions',
    webUrl: 'https://github.com',
  ),
  gitee(
    id: 'gitee',
    label: 'Gitee',
    owner: 'Gitee',
    // Gitee Go 没有 macOS Runner，iOS 构建必须到 GitHub 上完成
    supportsIosBuild: false,
    ciName: 'Gitee Go',
    webUrl: 'https://gitee.com',
  );

  /// 持久化用的稳定标识
  final String id;
  final String label;

  /// 账号平台名（用于文案）
  final String owner;

  /// 是否支持 iOS 云端构建
  final bool supportsIosBuild;

  /// CI 名称
  final String ciName;

  /// 网页地址
  final String webUrl;

  const GitHost({
    required this.id,
    required this.label,
    required this.owner,
    required this.supportsIosBuild,
    required this.ciName,
    required this.webUrl,
  });

  static GitHost fromId(String? id, {GitHost fallback = GitHost.github}) {
    for (final host in values) {
      if (host.id == id) return host;
    }
    return fallback;
  }

  /// 仓库页面地址
  String repoUrl(String fullName) => '$webUrl/$fullName';

  /// Gitee Go / GitHub Actions 运行页面
  String ciUrl(String fullName) => switch (this) {
        GitHost.github => 'https://github.com/$fullName/actions',
        GitHost.gitee => 'https://gitee.com/$fullName/gitee_go',
      };
}

/// 清洗仓库名：GitHub / Gitee 都只接受字母、数字、`_`、`-`、`.`，
/// 且不允许以 `.` 开头。中文项目名等会被转换为合法名称。
String sanitizeRepoName(String raw) {
  var name = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  // 折叠连续分隔符，去掉开头的 . / - / _
  name = name.replaceAll(RegExp(r'-{2,}'), '-');
  name = name.replaceFirst(RegExp(r'^[.\-_]+'), '');
  name = name.replaceAll(RegExp(r'[.\-_]+$'), '');
  if (name.isEmpty) name = 'slipe-project';
  // Gitee 限制 100 字符以内，留一点余量
  if (name.length > 80) name = name.substring(0, 80);
  return name;
}
