import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'backend_http.dart';

/// GitHub 专用 Hosts
///
/// 服务端每天从公共源拉取 hosts 并下发，客户端缓存在本地，
/// 仅在应用内部的 HTTP 请求中使用（自定义 DNS 解析 + 保持 SNI）：
/// - 不修改系统 hosts
/// - 不申请 VPN / 代理权限
/// - 不影响系统浏览器（OAuth 走外部浏览器，保持原有网络）
class GithubHostsService {
  GithubHostsService._();

  static final GithubHostsService instance = GithubHostsService._();

  static const _contentKey = 'slipe_github_hosts_content_v1';
  static const _updatedAtKey = 'slipe_github_hosts_updated_at_v1';
  static const _fetchedAtKey = 'slipe_github_hosts_fetched_at_v1';
  static const _refreshInterval = Duration(hours: 12);

  bool _enabled = true;
  bool _loaded = false;
  String _content = '';
  int _updatedAt = 0;
  DateTime? _fetchedAt;
  final Map<String, String> _hosts = {};

  bool get enabled => _enabled;
  bool get hasHosts => _hosts.isNotEmpty;
  int get updatedAt => _updatedAt;
  DateTime? get fetchedAt => _fetchedAt;
  int get hostCount => _hosts.length;

  /// 创建一个应用内 HTTP 客户端
  ///
  /// 启用 hosts 时走自定义 DNS 解析，否则返回普通客户端。
  /// 调用方负责在使用完毕后 close。
  http.Client newClient() {
    if (!_enabled || _hosts.isEmpty) return http.Client();
    return _buildClient();
  }

  /// 启动时加载本地缓存，并在过期时后台刷新
  Future<void> ensureLoaded({required bool enabled}) async {
    _enabled = enabled;
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _content = prefs.getString(_contentKey) ?? '';
      _updatedAt = prefs.getInt(_updatedAtKey) ?? 0;
      final fetched = prefs.getInt(_fetchedAtKey) ?? 0;
      _fetchedAt = fetched > 0
          ? DateTime.fromMillisecondsSinceEpoch(fetched)
          : null;
      _parse(_content);
    } catch (e) {
      debugPrint('读取 GitHub Hosts 缓存失败：$e');
    }
    if (!_enabled) return;
    final stale =
        _fetchedAt == null || DateTime.now().difference(_fetchedAt!) > _refreshInterval;
    if (stale) unawaited(refresh());
  }

  /// 切换开关
  void setEnabled(bool value) {
    _enabled = value;
  }

  /// 从服务端拉取最新 hosts
  Future<bool> refresh() async {
    if (!AppConfig.isAccountBackendConfigured) return false;
    try {
      final res = await BackendHttp.client
          .get(Uri.parse('${AppConfig.accountBackendBase}/api/github-hosts'))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) return false;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final content = (data['content'] ?? '').toString();
      if (content.trim().isEmpty) return false;
      _content = content;
      _updatedAt = (data['updatedAt'] as num?)?.toInt() ?? 0;
      _fetchedAt = DateTime.now();
      _parse(content);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_contentKey, _content);
      await prefs.setInt(_updatedAtKey, _updatedAt);
      await prefs.setInt(
        _fetchedAtKey,
        _fetchedAt!.millisecondsSinceEpoch,
      );
      return true;
    } catch (e) {
      debugPrint('刷新 GitHub Hosts 失败：$e');
      return false;
    }
  }

  void _parse(String content) {
    _hosts.clear();
    for (final rawLine in content.split('\n')) {
      final line = rawLine.split('#').first.trim();
      if (line.isEmpty) continue;
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final ip = parts.first;
      if (!RegExp(r'^[0-9a-fA-F.:]+$').hasMatch(ip)) continue;
      for (final host in parts.skip(1)) {
        _hosts[host.toLowerCase()] = ip;
      }
    }
  }

  /// 构建自定义 DNS 客户端
  ///
  /// 先按 hosts 解析到 IP 直连，HTTPS 再用原始域名完成 TLS 握手（SNI + 证书校验），
  /// 因此不会出现证书不匹配，也不需要任何系统级网络权限。
  http.Client _buildClient() {
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    httpClient.connectionFactory = (uri, proxyHost, proxyPort) async {
      final ip = _hosts[uri.host.toLowerCase()];
      if (ip == null || proxyHost != null) {
        // 未命中 hosts（或代理场景）：按默认方式直连
        return _defaultConnect(uri);
      }
      return _mappedConnect(uri, ip);
    };
    return IOClient(httpClient);
  }

  static int _portOf(Uri uri) =>
      uri.port == 0 ? (uri.scheme == 'https' ? 443 : 80) : uri.port;

  Future<ConnectionTask<Socket>> _defaultConnect(Uri uri) async {
    final port = _portOf(uri);
    final future = uri.scheme == 'https'
        ? SecureSocket.connect(
            uri.host,
            port,
            timeout: const Duration(seconds: 15),
          )
        : Socket.connect(
            uri.host,
            port,
            timeout: const Duration(seconds: 15),
          );
    return ConnectionTask.fromSocket(future, () {});
  }

  Future<ConnectionTask<Socket>> _mappedConnect(Uri uri, String ip) async {
    final port = _portOf(uri);
    Future<Socket> connect() async {
      final raw = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 15),
      );
      if (uri.scheme != 'https') return raw;
      try {
        // 用原始域名完成 TLS 握手：SNI 与证书校验都针对域名而非 IP
        return await SecureSocket.secure(raw, host: uri.host);
      } catch (_) {
        raw.destroy();
        rethrow;
      }
    }

    final future = connect();
    return ConnectionTask.fromSocket(future, () {
      future.then((socket) => socket.destroy()).catchError((_) {});
    });
  }
}
