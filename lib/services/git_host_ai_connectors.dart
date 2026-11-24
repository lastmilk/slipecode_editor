import 'dart:convert';

import '../agent/tool_contract.dart';
import '../config/app_config.dart';
import '../models/ai_connector.dart';
import '../providers/gitee_provider.dart';
import '../providers/github_provider.dart';
import 'ai_connector_service.dart';
import 'tool_policy.dart';

List<String> _splitScopes(String? scopes) {
  return (scopes ?? '')
      .split(RegExp(r'[,\s]+'))
      .map((scope) => scope.trim())
      .where((scope) => scope.isNotEmpty)
      .toList(growable: false);
}

String _requiredString(Map<String, dynamic> args, String name) {
  final value = args[name];
  if (value is! String || value.trim().isEmpty) {
    throw ArgumentError('参数 $name 不能为空');
  }
  return value.trim();
}

String _repositoryName(Map<String, dynamic> args) {
  final fullName = _requiredString(args, 'full_name');
  if (!RegExp(r'^[^/\s]+/[^/\s]+$').hasMatch(fullName)) {
    throw ArgumentError('full_name 必须使用 owner/repository 格式');
  }
  return fullName;
}

Map<String, dynamic> _repositoryJson({
  required String fullName,
  required String defaultBranch,
  required String htmlUrl,
  required bool private,
}) {
  return {
    'full_name': fullName,
    'default_branch': defaultBranch,
    'private': private,
    'html_url': htmlUrl,
  };
}

abstract class _ReadOnlyGitHostConnector implements AiConnector {
  Future<List<Map<String, dynamic>>> _listRepositories();

  Future<Map<String, dynamic>> _getRepository(String fullName);

  Future<String> _readTextFile(String fullName, String path, String branch);

  @override
  List<McpTool> tools() {
    final provider = definition.provider;
    return [
      McpTool(
        name: '${ConnectorService.toolPrefix}${provider}__list_repositories',
        description: '只读列出当前授权账号可访问的 ${definition.name} 仓库，最多 100 条，按更新时间排序。',
        parameters: const {
          'type': 'object',
          'properties': <String, dynamic>{},
          'additionalProperties': false,
        },
        execute: (_) async => jsonEncode(await _listRepositories()),
      ),
      McpTool(
        name: '${ConnectorService.toolPrefix}${provider}__get_repository',
        description: '只读获取指定 ${definition.name} 仓库的默认分支、可见性和 URL。',
        parameters: const {
          'type': 'object',
          'properties': {
            'full_name': {
              'type': 'string',
              'description': '仓库全名，格式为 owner/repository',
            },
          },
          'required': ['full_name'],
          'additionalProperties': false,
        },
        execute: (args) async =>
            jsonEncode(await _getRepository(_repositoryName(args))),
      ),
      McpTool(
        name: '${ConnectorService.toolPrefix}${provider}__read_text_file',
        description:
            '只读获取指定 ${definition.name} 仓库分支中的 UTF-8 文本文件；拒绝目录、非 UTF-8 内容和超过 256KB 的文件。',
        parameters: const {
          'type': 'object',
          'properties': {
            'full_name': {
              'type': 'string',
              'description': '仓库全名，格式为 owner/repository',
            },
            'path': {'type': 'string', 'description': '仓库内的文件路径'},
            'branch': {'type': 'string', 'description': '要读取的分支名称'},
          },
          'required': ['full_name', 'path', 'branch'],
          'additionalProperties': false,
        },
        execute: (args) async {
          final content = await _readTextFile(
            _repositoryName(args),
            _requiredString(args, 'path'),
            _requiredString(args, 'branch'),
          );
          return ToolPolicy.truncate(content);
        },
      ),
    ];
  }
}

class GitHubAiConnector extends _ReadOnlyGitHostConnector {
  GitHubAiConnector(this._provider);

  final GitHubProvider _provider;

  @override
  ConnectorDefinition get definition => ConnectorDefinition(
    id: 'github',
    name: 'GitHub',
    description: '只读访问授权账号可访问的 GitHub 仓库与文本文件。',
    provider: 'github',
    requestedScopes: _splitScopes(AppConfig.oauthScopes),
  );

  @override
  ConnectorAuthSnapshot get snapshot {
    final status = switch (_provider.status) {
      GitHubAuthStatus.signedIn when _provider.isSignedIn =>
        ConnectorAuthStatus.connected,
      GitHubAuthStatus.signingIn => ConnectorAuthStatus.authorizing,
      _ when !_provider.isConfigured => ConnectorAuthStatus.unconfigured,
      _ when (_provider.error ?? '').isNotEmpty => ConnectorAuthStatus.error,
      _ => ConnectorAuthStatus.signedOut,
    };
    return ConnectorAuthSnapshot(
      configured: _provider.isConfigured,
      enabled: true,
      status: status,
      accountLabel: _provider.user?.login ?? '',
      grantedScopes: _splitScopes(_provider.grantedScope),
      error: ConnectorService.safeError(_provider.error ?? ''),
    );
  }

  @override
  Future<void> authorize() async {
    if (!await _provider.signIn()) {
      throw StateError(_provider.error ?? 'GitHub 授权未完成');
    }
  }

  @override
  Future<void> disconnect() => _provider.signOut();

  @override
  Future<void> refresh() => _provider.init();

  @override
  Future<List<Map<String, dynamic>>> _listRepositories() async {
    final api = _provider.api;
    if (api == null) throw StateError('GitHub 尚未授权');
    try {
      final repos = await api.listRepositories();
      return [
        for (final repo in repos)
          _repositoryJson(
            fullName: repo.fullName,
            defaultBranch: repo.defaultBranch,
            htmlUrl: repo.htmlUrl,
            private: repo.private,
          ),
      ];
    } finally {
      api.dispose();
    }
  }

  @override
  Future<Map<String, dynamic>> _getRepository(String fullName) async {
    final api = _provider.api;
    if (api == null) throw StateError('GitHub 尚未授权');
    try {
      final repo = await api.getRepo(fullName);
      if (repo == null) throw StateError('仓库不存在或当前账号不可访问');
      return _repositoryJson(
        fullName: repo.fullName,
        defaultBranch: repo.defaultBranch,
        htmlUrl: repo.htmlUrl,
        private: repo.private,
      );
    } finally {
      api.dispose();
    }
  }

  @override
  Future<String> _readTextFile(
    String fullName,
    String path,
    String branch,
  ) async {
    final api = _provider.api;
    if (api == null) throw StateError('GitHub 尚未授权');
    try {
      return await api.readTextFile(fullName, path, branch);
    } finally {
      api.dispose();
    }
  }
}

class GiteeAiConnector extends _ReadOnlyGitHostConnector {
  GiteeAiConnector(this._provider);

  final GiteeProvider _provider;

  @override
  ConnectorDefinition get definition => ConnectorDefinition(
    id: 'gitee',
    name: 'Gitee',
    description: '只读访问授权账号可访问的 Gitee 仓库与文本文件。',
    provider: 'gitee',
    requestedScopes: _splitScopes(AppConfig.giteeScopes),
  );

  @override
  ConnectorAuthSnapshot get snapshot {
    final status = switch (_provider.status) {
      GiteeAuthStatus.signedIn when _provider.isSignedIn =>
        ConnectorAuthStatus.connected,
      GiteeAuthStatus.signingIn => ConnectorAuthStatus.authorizing,
      _ when !_provider.isConfigured => ConnectorAuthStatus.unconfigured,
      _ when (_provider.error ?? '').isNotEmpty => ConnectorAuthStatus.error,
      _ => ConnectorAuthStatus.signedOut,
    };
    return ConnectorAuthSnapshot(
      configured: _provider.isConfigured,
      enabled: true,
      status: status,
      accountLabel: _provider.user?.login ?? '',
      grantedScopes: _splitScopes(_provider.grantedScope),
      expiresAt: _provider.expiresAt,
      error: ConnectorService.safeError(_provider.error ?? ''),
    );
  }

  @override
  Future<void> authorize() async {
    if (!await _provider.signIn()) {
      throw StateError(_provider.error ?? 'Gitee 授权未完成');
    }
  }

  @override
  Future<void> disconnect() => _provider.signOut();

  @override
  Future<void> refresh() => _provider.init();

  @override
  Future<List<Map<String, dynamic>>> _listRepositories() async {
    final api = _provider.api;
    if (api == null) throw StateError('Gitee 尚未授权');
    try {
      final repos = await api.listRepositories();
      return [
        for (final repo in repos)
          _repositoryJson(
            fullName: repo.fullName,
            defaultBranch: repo.defaultBranch,
            htmlUrl: repo.htmlUrl,
            private: repo.private,
          ),
      ];
    } finally {
      api.dispose();
    }
  }

  @override
  Future<Map<String, dynamic>> _getRepository(String fullName) async {
    final api = _provider.api;
    if (api == null) throw StateError('Gitee 尚未授权');
    try {
      final repo = await api.getRepo(fullName);
      if (repo == null) throw StateError('仓库不存在或当前账号不可访问');
      return _repositoryJson(
        fullName: repo.fullName,
        defaultBranch: repo.defaultBranch,
        htmlUrl: repo.htmlUrl,
        private: repo.private,
      );
    } finally {
      api.dispose();
    }
  }

  @override
  Future<String> _readTextFile(
    String fullName,
    String path,
    String branch,
  ) async {
    final api = _provider.api;
    if (api == null) throw StateError('Gitee 尚未授权');
    try {
      return await api.readTextFile(fullName, path, branch);
    } finally {
      api.dispose();
    }
  }
}
