import '../services/git_host.dart';

/// 仓库同步页里统一展示的远程仓库。
class SyncRepo {
  const SyncRepo({
    required this.host,
    required this.fullName,
    required this.defaultBranch,
    required this.htmlUrl,
    required this.private,
  });

  final GitHost host;
  final String fullName;
  final String defaultBranch;
  final String htmlUrl;
  final bool private;

  /// 仓库名（不含 owner）
  String get name {
    final index = fullName.lastIndexOf('/');
    return index == -1 ? fullName : fullName.substring(index + 1);
  }

  /// 本地唯一标识（GitHub / Gitee 可能重名）
  String get key => '${host.id}:$fullName';

  /// HTTPS 克隆地址（认证信息由 Git 客户端按平台注入）
  String get cloneUrl => '${host.webUrl}/$fullName.git';
}
