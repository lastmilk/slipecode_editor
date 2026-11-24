import 'package:flutter/material.dart';

import 'project_payload.dart';

/// C++ 载荷：可选编译器（gcc / clang），可选是否生成 Makefile
class CppPayload extends ProjectPayload {
  const CppPayload();

  /// 默认模板（template 取值：make / cmake）
  static const defaultTemplate = 'make';

  @override
  String get id => 'cpp';

  @override
  String get name => 'C++';

  @override
  String get description => 'C++ 项目，可选编译器与 Makefile / CMake 构建';

  @override
  IconData get icon => Icons.memory_outlined;

  @override
  String get projectNameHint => 'my_app';

  @override
  String get defaultOrg => 'com.example';

  @override
  String get defaultLanguage => 'cpp';

  @override
  Map<String, String> get languageByExtension => const {
        'cpp': 'cpp',
        'cc': 'cpp',
        'cxx': 'cpp',
        'hpp': 'cpp',
        'hh': 'cpp',
        'h': 'cpp',
        'c': 'cpp',
        'md': 'markdown',
        'txt': 'plaintext',
        'json': 'json',
        'yml': 'yaml',
        'yaml': 'yaml',
      };

  @override
  List<PayloadBuildType> get buildTypes => const [
        PayloadBuildType('release', '可执行文件', ''),
      ];

  @override
  List<PayloadFile> templateFiles(String template) {
    final useMake = template != 'cmake';
    return [
      const PayloadFile.inline('src/main.cpp', _mainCpp),
      if (useMake)
        const PayloadFile.inline('Makefile', _makefile)
      else
        const PayloadFile.inline('CMakeLists.txt', _cmakeLists),
      PayloadFile.inline(
        '.slipe.json',
        '{\n  "payload": "cpp",\n  "template": "${useMake ? 'make' : 'cmake'}",\n'
        '  "compiler": "{{CPP_COMPILER}}"\n}\n',
      ),
      const PayloadFile.inline('.gitignore', _gitignore),
      const PayloadFile.inline('README.md', _readme),
    ];
  }

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
  build-cpp:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install toolchain
        run: sudo apt-get update && sudo apt-get install -y cmake g++ clang make

      - name: Build
        run: |
          if [ -f Makefile ]; then
            make
          else
            cmake -B build -DCMAKE_BUILD_TYPE=Release
            cmake --build build
          fi

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: {{PROJECT_NAME}}
          path: |
            build/{{PROJECT_NAME}}
            {{PROJECT_NAME}}
''';

  static const _mainCpp = '''#include <iostream>

int main() {
    std::cout << "Hello from {{PROJECT_NAME}}!" << std::endl;
    return 0;
}
''';

  static const _makefile = r'''CXX ?= {{CPP_COMPILER}}
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra

TARGET := {{PROJECT_NAME}}
SRCS := $(wildcard src/*.cpp)

all: $(TARGET)

$(TARGET): $(SRCS)
\t$(CXX) $(CXXFLAGS) -o $@ $(SRCS)

run: $(TARGET)
\t./$(TARGET)

clean:
\trm -f $(TARGET)

.PHONY: all run clean
''';

  static const _cmakeLists = r'''cmake_minimum_required(VERSION 3.16)
project({{PROJECT_NAME}} CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

file(GLOB SOURCES "src/*.cpp")
add_executable({{PROJECT_NAME}} ${SOURCES})
''';

  static const _gitignore = '''build/
*.o
*.obj
*.exe
{{PROJECT_NAME}}
.cache/
compile_commands.json
''';

  static const _readme = '''# {{PROJECT_NAME}}

C++ 项目，由 SLIPE 创建。

- 编译器：{{CPP_COMPILER}}
- 构建：`make`（CMake 项目使用 `cmake -B build && cmake --build build`）
- 运行：`make run`
''';
}
