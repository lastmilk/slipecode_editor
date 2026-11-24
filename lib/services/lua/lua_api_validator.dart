import 'dart:convert';

import 'package:slipe_lua/slipe_lua.dart';

/// Dart 侧与 Lua 共用 schema.json，拒绝越界请求和无效 handler 返回值。
class LuaApiValidator {
  static final Map<String, Object?> schema =
      jsonDecode(slipeApiSchemaJson) as Map<String, Object?>;

  static void validateServiceRequest(
    String service,
    String operation,
    Object? value,
  ) => validate(
    _operation(service, operation)['request'],
    value,
    '$service.$operation request',
  );

  static void validateServiceResponse(
    String service,
    String operation,
    Object? value,
  ) => validate(
    _operation(service, operation)['response'],
    value,
    '$service.$operation response',
  );

  static Map<String, Object?> _operation(String service, String operation) {
    final services = schema['services'] as Map;
    final serviceSchema = services[service] as Map?;
    final operations = serviceSchema?['operations'] as Map?;
    final result = operations?[operation];
    if (result is! Map) throw ArgumentError('未知 Lua 服务 $service.$operation');
    return result.map((key, value) => MapEntry(key.toString(), value));
  }

  static void validate(Object? rawSchema, Object? value, String path) {
    if (rawSchema is! Map) throw FormatException('$path：Schema 无效');
    final expected = rawSchema['type'];
    final validType = switch (expected) {
      null || 'any' => true,
      'object' => value is Map,
      'array' => value is List,
      'string' => value is String,
      'boolean' => value is bool,
      'integer' => value is num && value == value.roundToDouble(),
      'number' => value is num && value.isFinite,
      'null' => value == null,
      _ => false,
    };
    if (!validType) throw FormatException('$path：应为 $expected');
    final enumValues = rawSchema['enum'];
    if (enumValues is List && !enumValues.contains(value)) {
      throw FormatException('$path：值不在 enum 中');
    }
    if (value is String) {
      final min = rawSchema['minLength'] as num?;
      final max = rawSchema['maxLength'] as num?;
      if (min != null && value.length < min ||
          max != null && value.length > max) {
        throw FormatException('$path：字符串长度越界');
      }
    }
    if (value is num) {
      final min = rawSchema['minimum'] as num?;
      final max = rawSchema['maximum'] as num?;
      if (min != null && value < min || max != null && value > max) {
        throw FormatException('$path：数值越界');
      }
    }
    if (value is List) {
      final min = rawSchema['minItems'] as num?;
      final max = rawSchema['maxItems'] as num?;
      if (min != null && value.length < min ||
          max != null && value.length > max) {
        throw FormatException('$path：数组长度越界');
      }
      final items = rawSchema['items'];
      if (items != null) {
        for (var index = 0; index < value.length; index++) {
          validate(items, value[index], '$path[$index]');
        }
      }
    }
    if (value is Map) {
      final properties = rawSchema['properties'] as Map? ?? const {};
      for (final key in rawSchema['required'] as List? ?? const []) {
        if (!value.containsKey(key)) throw FormatException('$path.$key：缺少字段');
      }
      for (final entry in value.entries) {
        final property = properties[entry.key];
        if (property == null) {
          if (rawSchema['additionalProperties'] == false) {
            throw FormatException('$path.${entry.key}：未知字段');
          }
        } else {
          validate(property, entry.value, '$path.${entry.key}');
        }
      }
    }
  }
}
