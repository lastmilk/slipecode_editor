import 'dart:async';
import 'dart:convert';

/// JSON-RPC 错误
class JsonRpcException implements Exception {
  final int code;
  final String message;
  final dynamic data;

  const JsonRpcException(this.code, this.message, [this.data]);

  @override
  String toString() => 'JsonRpcException($code): $message';
}

/// LSP 底层 JSON-RPC（stdio 帧协议）
///
/// 负责 `Content-Length` 帧的编解码、请求 id / pending 表、
/// 通知分流、服务端反向请求应答与请求超时。
class JsonRpcConnection {
  JsonRpcConnection(
    Stream<List<int>> input,
    this._send, {
    this.onNotification,
    this.onServerRequest,
    this.onLog,
    this.defaultTimeout = const Duration(seconds: 15),
  }) {
    _subscription = input.listen(
      _onData,
      onError: _failAll,
      onDone: () => _failAll(
        const JsonRpcException(-32000, '语言服务连接已关闭'),
      ),
      cancelOnError: false,
    );
  }

  final void Function(List<int> data) _send;
  final void Function(String method, dynamic params)? onNotification;
  final FutureOr<dynamic> Function(String method, dynamic params)?
      onServerRequest;
  final void Function(String line)? onLog;
  final Duration defaultTimeout;

  late final StreamSubscription<List<int>> _subscription;
  final List<int> _buffer = [];
  final Map<int, Completer<dynamic>> _pending = {};
  int _nextId = 1;
  bool _disposed = false;

  bool get hasPending => _pending.isNotEmpty;

  /// 发送请求并等待结果
  Future<dynamic> request(
    String method, [
    dynamic params,
    Duration? timeout,
  ]) {
    if (_disposed) {
      return Future.error(
        const JsonRpcException(-32000, '语言服务连接已关闭'),
      );
    }
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    final timer = Timer(timeout ?? defaultTimeout, () {
      if (_pending.remove(id) == null) return;
      completer.completeError(JsonRpcException(-32001, '请求超时：$method'));
    });
    _write({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    });
    return completer.future.whenComplete(timer.cancel);
  }

  /// 发送通知（无响应）
  void notify(String method, [dynamic params]) {
    if (_disposed) return;
    _write({
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    });
  }

  /// 取消尚未完成的请求
  void cancelRequest(int id) {
    if (!_pending.containsKey(id)) return;
    notify(r'$/cancelRequest', {'id': id});
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_subscription.cancel());
    _failAll(const JsonRpcException(-32000, '语言服务已关闭'));
  }

  // ---------------------------------------------------------------------------
  // 帧解析
  // ---------------------------------------------------------------------------

  void _onData(List<int> chunk) {
    _buffer.addAll(chunk);
    while (true) {
      final headerEnd = _indexOfHeaderEnd();
      if (headerEnd < 0) return;
      final header = utf8.decode(
        _buffer.sublist(0, headerEnd),
        allowMalformed: true,
      );
      var contentLength = 0;
      for (final line in header.split('\r\n')) {
        final colon = line.indexOf(':');
        if (colon <= 0) continue;
        final key = line.substring(0, colon).trim().toLowerCase();
        if (key == 'content-length') {
          contentLength = int.tryParse(line.substring(colon + 1).trim()) ?? 0;
        }
      }
      final bodyStart = headerEnd + 4;
      if (_buffer.length < bodyStart + contentLength) return;
      final body = utf8.decode(
        _buffer.sublist(bodyStart, bodyStart + contentLength),
        allowMalformed: true,
      );
      _buffer.removeRange(0, bodyStart + contentLength);
      if (contentLength > 0) _handleMessage(body);
    }
  }

  int _indexOfHeaderEnd() {
    for (var i = 0; i + 3 < _buffer.length; i++) {
      if (_buffer[i] == 13 &&
          _buffer[i + 1] == 10 &&
          _buffer[i + 2] == 13 &&
          _buffer[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  void _handleMessage(String body) {
    onLog?.call('← $body');
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (e) {
      onLog?.call('解析消息失败：$e');
      return;
    }
    if (decoded is! Map) return;
    final message = decoded.cast<String, dynamic>();
    final id = message['id'];
    final method = message['method'];

    // 服务端响应
    if (method == null && id is num) {
      final completer = _pending.remove(id.toInt());
      if (completer == null) return;
      final error = message['error'];
      if (error is Map) {
        completer.completeError(
          JsonRpcException(
            (error['code'] as num?)?.toInt() ?? -32603,
            (error['message'] as String?) ?? '未知错误',
            error['data'],
          ),
        );
      } else {
        completer.complete(message['result']);
      }
      return;
    }

    // 服务端请求
    if (method is String && id != null) {
      unawaited(_handleServerRequest(id, method, message['params']));
      return;
    }

    // 服务端通知
    if (method is String) {
      onNotification?.call(method, message['params']);
    }
  }

  Future<void> _handleServerRequest(
    dynamic id,
    String method,
    dynamic params,
  ) async {
    dynamic result;
    try {
      result = await onServerRequest?.call(method, params);
    } catch (e) {
      _write({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32603, 'message': '$e'},
      });
      return;
    }
    _write({
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    });
  }

  void _write(Map<String, dynamic> message) {
    final body = jsonEncode(message);
    onLog?.call('→ $body');
    final bytes = utf8.encode(body);
    final frame = utf8.encode('Content-Length: ${bytes.length}\r\n\r\n');
    _send([...frame, ...bytes]);
  }

  void _failAll(Object error) {
    final pending = Map<int, Completer<dynamic>>.from(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }
}
