final class SlipeLuaException implements Exception {
  const SlipeLuaException(this.message, {this.response});

  final String message;
  final Map<String, Object?>? response;

  @override
  String toString() => 'SlipeLuaException: $message';
}
