import 'package:flutter/foundation.dart';

/// OAuth 连接器的授权状态。
enum ConnectorAuthStatus {
  unconfigured,
  signedOut,
  authorizing,
  connected,
  error,
}

/// 连接器的公开元数据。
@immutable
class ConnectorDefinition {
  const ConnectorDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.provider,
    this.authType = 'oauth2',
    this.requestedScopes = const [],
  });

  final String id;
  final String name;
  final String description;
  final String provider;
  final String authType;
  final List<String> requestedScopes;
}

/// 可直接展示给 UI 的授权快照，不包含 access token 或 refresh token。
@immutable
class ConnectorAuthSnapshot {
  const ConnectorAuthSnapshot({
    required this.configured,
    required this.enabled,
    required this.status,
    this.accountLabel = '',
    this.grantedScopes = const [],
    this.expiresAt,
    this.error = '',
  });

  final bool configured;
  final bool enabled;
  final ConnectorAuthStatus status;
  final String accountLabel;
  final List<String> grantedScopes;
  final DateTime? expiresAt;
  final String error;

  bool get isConnected => status == ConnectorAuthStatus.connected;

  ConnectorAuthSnapshot copyWith({bool? enabled}) {
    return ConnectorAuthSnapshot(
      configured: configured,
      enabled: enabled ?? this.enabled,
      status: status,
      accountLabel: accountLabel,
      grantedScopes: grantedScopes,
      expiresAt: expiresAt,
      error: error,
    );
  }
}
