import 'package:flutter/material.dart';

import 'project_payload.dart';

/// 后端载荷：Node.js
class NodeBackendPayload extends ProjectPayload {
  const NodeBackendPayload();

  @override
  String get id => 'node';

  @override
  String get name => '后端（Node.js）';

  @override
  String get description => '零依赖 Node.js HTTP 服务';

  @override
  IconData get icon => Icons.dns_outlined;

  @override
  String get projectNameHint => 'my_backend';

  @override
  String get defaultOrg => 'com.example';

  @override
  String get defaultLanguage => 'javascript';

  @override
  Map<String, String> get languageByExtension => const {
        'js': 'javascript',
        'mjs': 'javascript',
        'cjs': 'javascript',
        'ts': 'typescript',
        'json': 'json',
        'md': 'markdown',
        'yml': 'yaml',
        'yaml': 'yaml',
        'env': 'plaintext',
      };

  @override
  List<PayloadBuildType> get buildTypes => const [
        PayloadBuildType('release', '构建产物', '.zip'),
      ];

  @override
  String get workflowContent => r'''
name: SlipCode Build

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      build_type:
        description: '构建类型'
        required: true
        type: choice
        default: 'release'
        options:
          - release

jobs:
  build-node:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install
        run: npm install --no-audit --no-fund

      - name: Build / Check
        run: |
          set -e
          npm run build --if-present
          node --check src/server.js

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: slipecode-${{ inputs.build_type || 'release' }}
          path: |
            .
            !node_modules
          if-no-files-found: error
''';

  @override
  List<PayloadFile> templateFiles(String template) => const [
        PayloadFile.inline('package.json', _packageJson),
        PayloadFile.inline('src/server.js', _serverJs),
        PayloadFile.inline('README.md', _readme),
        PayloadFile.inline('.gitignore', _gitignore),
        PayloadFile.inline('.slipecode.json', _marker),
      ];

  static const String _packageJson = '''{
  "name": "{{PROJECT_NAME}}",
  "version": "1.0.0",
  "private": true,
  "type": "commonjs",
  "main": "src/server.js",
  "scripts": {
    "start": "node src/server.js",
    "dev": "node src/server.js"
  }
}
''';

  static const String _serverJs = '''const http = require('http');

const PORT = Number(process.env.PORT || 8080);

const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (req.url === '/health') {
    res.end(JSON.stringify({ status: 'ok', project: '{{PROJECT_NAME}}' }));
    return;
  }
  res.end(JSON.stringify({ message: 'Hello from {{PROJECT_NAME}}' }));
});

server.listen(PORT, () => {
  console.log('Server listening on http://localhost:' + PORT);
});
''';

  static const String _readme = '''# {{PROJECT_NAME}}

由 SLIPE（Node.js 后端 Payload）创建。

```bash
npm start
```

默认端口 8080，健康检查 `GET /health`。
''';

  static const String _gitignore = '''node_modules/
.env
dist/
npm-debug.log*
''';

  static const String _marker = '''{
  "project_name": "{{PROJECT_NAME}}",
  "payload": "node",
  "created_by": "slipecode"
}
''';
}
