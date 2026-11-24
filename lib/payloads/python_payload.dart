import 'package:flutter/material.dart';

import 'project_payload.dart';

/// Python 载荷：脚本 / 包项目，本地构建使用工具链中安装的 Python
class PythonPayload extends ProjectPayload {
  const PythonPayload();

  @override
  String get id => 'python';

  @override
  String get name => 'Python';

  @override
  String get description => 'Python 脚本项目，支持指定解释器版本';

  @override
  IconData get icon => Icons.terminal_outlined;

  @override
  String get projectNameHint => 'my_script';

  @override
  String get defaultOrg => 'com.example';

  @override
  String get defaultLanguage => 'python';

  @override
  Map<String, String> get languageByExtension => const {
        'py': 'python',
        'pyi': 'python',
        'toml': 'ini',
        'cfg': 'ini',
        'ini': 'ini',
        'txt': 'plaintext',
        'json': 'json',
        'md': 'markdown',
        'yml': 'yaml',
        'yaml': 'yaml',
      };

  @override
  List<PayloadBuildType> get buildTypes => const [
        PayloadBuildType('release', '源码包', '.zip'),
      ];

  @override
  List<PayloadFile> templateFiles(String template) => [
        const PayloadFile.inline('main.py', _mainPy),
        const PayloadFile.inline('requirements.txt', ''),
        const PayloadFile.inline('README.md', _readme),
        const PayloadFile.inline('.gitignore', _gitignore),
        const PayloadFile.inline('.slipe.json', _marker),
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
  build-python:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: '{{PYTHON_VERSION}}'

      - name: Install dependencies
        run: |
          python -m pip install --upgrade pip
          if [ -f requirements.txt ]; then pip install -r requirements.txt; fi

      - name: Compile check
        run: python -m compileall -q .

      - name: Package
        run: |
          mkdir -p dist
          zip -r dist/{{PROJECT_NAME}}.zip . -x "dist/*" -x ".git/*"
        shell: bash

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: {{PROJECT_NAME}}
          path: dist/*
''';

  static const _mainPy = '''"""{{PROJECT_NAME}} 入口"""


def main() -> None:
    print("Hello from {{PROJECT_NAME}}!")


if __name__ == "__main__":
    main()
''';

  static const _readme = '''# {{PROJECT_NAME}}

Python 项目，由 SLIPE 创建。

- 解释器版本：{{PYTHON_VERSION}}
- 依赖：`pip install -r requirements.txt`
- 运行：`python main.py`
''';

  static const _gitignore = '''__pycache__/
*.py[cod]
.venv/
venv/
dist/
build/
*.egg-info/
.env
''';

  static const _marker = '''{
  "payload": "python",
  "python": "{{PYTHON_VERSION}}"
}
''';
}
