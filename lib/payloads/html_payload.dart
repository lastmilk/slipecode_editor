import 'package:flutter/material.dart';

import 'project_payload.dart';

/// 前端载荷：HTML
class HtmlFrontendPayload extends ProjectPayload {
  const HtmlFrontendPayload();

  @override
  String get id => 'html';

  @override
  String get name => '前端（HTML）';

  @override
  String get description => '原生 HTML / CSS / JS 静态站点';

  @override
  IconData get icon => Icons.web;

  @override
  String get projectNameHint => 'my_website';

  @override
  String get defaultOrg => 'com.example';

  @override
  String get defaultLanguage => 'xml';

  @override
  Map<String, String> get languageByExtension => const {
        'html': 'xml',
        'htm': 'xml',
        'css': 'css',
        'js': 'javascript',
        'ts': 'typescript',
        'json': 'json',
        'md': 'markdown',
        'svg': 'xml',
      };

  @override
  List<PayloadBuildType> get buildTypes => const [
        PayloadBuildType('release', '静态站点包', '.zip'),
      ];

  @override
  String get workflowContent => r'''
name: SLIPE Build

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
  build-web:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: slipe-${{ inputs.build_type || 'release' }}
          path: |
            .
            !.git
            !.github
          if-no-files-found: error
''';

  @override
  List<PayloadFile> templateFiles(String template) => const [
        PayloadFile.inline('index.html', _indexHtml),
        PayloadFile.inline('css/style.css', _styleCss),
        PayloadFile.inline('js/app.js', _appJs),
        PayloadFile.inline('README.md', _readme),
        PayloadFile.inline('.gitignore', _gitignore),
        PayloadFile.inline('.slipe.json', _marker),
      ];

  static const String _indexHtml = '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>{{PROJECT_NAME}}</title>
  <link rel="stylesheet" href="css/style.css" />
</head>
<body>
  <main class="app">
    <h1>{{PROJECT_NAME}}</h1>
    <p>由 SLIPE 创建的静态页面。</p>
    <button id="action">点我</button>
    <p id="output"></p>
  </main>
  <script src="js/app.js"></script>
</body>
</html>
''';

  static const String _styleCss = ''':root {
  --bg: #0f1115;
  --fg: #e6e8ee;
  --accent: #ff7a18;
}

* {
  box-sizing: border-box;
}

body {
  margin: 0;
  min-height: 100vh;
  display: grid;
  place-items: center;
  background: var(--bg);
  color: var(--fg);
  font-family: system-ui, -apple-system, sans-serif;
}

.app {
  text-align: center;
}

button {
  padding: 10px 20px;
  border: none;
  border-radius: 8px;
  background: var(--accent);
  color: #111;
  font-size: 15px;
}
''';

  static const String _appJs = '''const btn = document.getElementById('action');
const output = document.getElementById('output');

btn.addEventListener('click', () => {
  output.textContent = 'Hello, {{PROJECT_NAME}}!';
});
''';

  static const String _readme = '''# {{PROJECT_NAME}}

由 SLIPE（HTML 前端 Payload）创建。

直接用浏览器打开 `index.html`，或部署到任意静态托管。
''';

  static const String _gitignore = '''.DS_Store
dist/
''';

  static const String _marker = '''{
  "project_name": "{{PROJECT_NAME}}",
  "payload": "html",
  "created_by": "slipe"
}
''';
}
