import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final packageRoot = File.fromUri(Platform.script).parent.parent;
  final schemaFile = File('${packageRoot.path}/api/schema.json');
  final source = schemaFile.readAsStringSync();
  final schema = jsonDecode(source) as Map<String, dynamic>;
  final outputs = {
    File('${packageRoot.path}/lib/src/api_schema.dart'): _dartSchema(source),
    File('${packageRoot.path}/api/slipe.lua'): _luaStubs(schema),
  };
  final check = args.contains('--check');
  for (final entry in outputs.entries) {
    if (check) {
      if (!entry.key.existsSync() ||
          entry.key.readAsStringSync() != entry.value) {
        stderr.writeln('Out of date: ${entry.key.path}');
        exitCode = 1;
      }
    } else {
      entry.key.writeAsStringSync(entry.value);
      stdout.writeln('Generated ${entry.key.path}');
    }
  }
}

String _dartSchema(String source) =>
    "// GENERATED FROM api/schema.json. Run tool/generate_schema.dart.\n"
    "const slipeApiSchemaJson = r'''\n$source\n''';\n";

String _luaStubs(Map<String, dynamic> schema) {
  final out = StringBuffer('''---@meta
-- GENERATED FROM schema.json. Run tool/generate_schema.dart.

---@alias SlipeEventPhase 'will'|'did'
---@alias SlipeEventAction 'continue'|'modify'|'swallow'

---@class SlipeEvent
---@field type string
---@field phase SlipeEventPhase
---@field source string
---@field eventId string
---@field payload table

---@class SlipeEventDecision
---@field action SlipeEventAction
---@field event SlipeEvent?

---@class SlipeCommandOptions
---@field title string?
---@field category string?

---@class SlipeOverrideOptions
---@field priority integer?

slipe = { service = {}, events = {}, commands = {}, config = {}, keys = {}, json = {}, schema = {}, ui = {} }
pluginhook = {}

---@param options { capability: string, reason: string }
function pluginhook.init(options) end

''');
  final classes = <String>[];
  final overloads = <String>[];
  final services = schema['services'] as Map<String, dynamic>;
  for (final service in services.entries) {
    final operations = service.value['operations'] as Map<String, dynamic>;
    for (final operation in operations.entries) {
      final base = '${_pascal(service.key)}${_pascal(operation.key)}';
      final request = '${base}Request';
      final response = '${base}Response';
      classes.add(_luaClass(request, operation.value['request']));
      classes.add(_luaClass(response, operation.value['response']));
      overloads.add(
        "---@overload fun(service: '${service.key}', operation: '${operation.key}', options: SlipeOverrideOptions?, handler: fun(request: $request, next: fun(request: $request): $response): $response)",
      );
    }
  }
  out.writeln(classes.join('\n'));
  out.writeln(overloads.join('\n'));
  out.write('''
function slipe.service.override(service, operation, options, handler) end

---@param eventType string
---@param options { phase: SlipeEventPhase?, priority: integer? }?
---@param handler fun(event: SlipeEvent): SlipeEventDecision?
function slipe.events.on(eventType, options, handler) end

---@param id string
function slipe.events.off(id) end

---@param command string
---@param options SlipeCommandOptions?
---@param handler fun(payload: table): any
function slipe.commands.register(command, options, handler) end

---@param command string
function slipe.commands.unregister(command) end

---@param message string
---@param level 'info'|'warning'|'error'?
---@return UiNotifyResponse
function slipe.ui.notify(message, level) end

---@param key string
---@param value any
function slipe.config.set(key, value) end

---@param activator string
---@param command string
function slipe.keys.bind(activator, command) end

---@param activator string
function slipe.keys.unbind(activator) end

---@param value any
---@return string
function slipe.json.encode(value) end

---@param value string
---@return any
function slipe.json.decode(value) end

---@param schema table
function slipe.schema.load(schema) end

---@param value any
---@param schema table?
---@return boolean? ok, string? error
function slipe.schema.validate(value, schema) end
''');
  return out.toString();
}

String _luaClass(String name, Map<String, dynamic> schema) {
  if (schema['type'] != 'object') {
    return '---@alias $name ${_luaType(schema)}\n';
  }
  final required = (schema['required'] as List? ?? const []).toSet();
  final properties = schema['properties'] as Map<String, dynamic>? ?? {};
  final out = StringBuffer('---@class $name\n');
  for (final property in properties.entries) {
    final optional = required.contains(property.key) ? '' : '?';
    out.writeln(
      '---@field ${property.key} ${_luaType(property.value)}$optional',
    );
  }
  return out.toString();
}

String _luaType(Map<String, dynamic> schema) {
  if (schema['enum'] is List) {
    return (schema['enum'] as List).map((item) => "'$item'").join('|');
  }
  return switch (schema['type']) {
    'string' => 'string',
    'integer' => 'integer',
    'number' => 'number',
    'boolean' => 'boolean',
    'array' => '${_luaType(schema['items'])}[]',
    'object' => 'table',
    _ => 'any',
  };
}

String _pascal(String source) => source
    .split(RegExp('[^A-Za-z0-9]'))
    .where((part) => part.isNotEmpty)
    .map((part) => part[0].toUpperCase() + part.substring(1))
    .join();
