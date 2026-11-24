import 'package:flutter/material.dart';

import 'project_payload.dart';

/// Java 载荷：可选 Gradle 或 Maven 作为构建工具
class JavaPayload extends ProjectPayload {
  const JavaPayload();

  /// 默认构建工具（template 取值：gradle / maven）
  static const defaultTemplate = 'gradle';

  @override
  String get id => 'java';

  @override
  String get name => 'Java';

  @override
  String get description => 'Java 应用，支持 Gradle / Maven 两种构建方式';

  @override
  IconData get icon => Icons.coffee_outlined;

  @override
  String get projectNameHint => 'my_app';

  @override
  String get defaultOrg => 'com.example';

  @override
  String get defaultLanguage => 'java';

  @override
  Map<String, String> get languageByExtension => const {
        'java': 'java',
        'gradle': 'groovy',
        'kts': 'kotlin',
        'xml': 'xml',
        'properties': 'ini',
        'json': 'json',
        'md': 'markdown',
        'yml': 'yaml',
        'yaml': 'yaml',
      };

  @override
  List<PayloadBuildType> get buildTypes => const [
        PayloadBuildType('release', '可执行 jar', '.jar'),
      ];

  @override
  List<PayloadFile> templateFiles(String template) {
    final useMaven = template == 'maven';
    return [
      const PayloadFile.inline('src/main/java/{{ORG_PATH}}/App.java', _appJava),
      if (useMaven)
        const PayloadFile.inline('pom.xml', _pomXml)
      else ...[
        const PayloadFile.inline('settings.gradle', _settingsGradle),
        const PayloadFile.inline('build.gradle', _buildGradle),
      ],
      PayloadFile.inline(
        '.slipe.json',
        '{\n  "payload": "java",\n  "template": "${useMaven ? 'maven' : 'gradle'}"\n}\n',
      ),
      const PayloadFile.inline('.gitignore', _gitignore),
      PayloadFile.inline('README.md', _readme(useMaven)),
    ];
  }

  /// 通用 workflow：依据仓库特征自动选择 Gradle / Maven
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
  build-java:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Java
        uses: actions/setup-java@v4
        with:
          distribution: 'temurin'
          java-version: '17'

      - name: Build
        run: |
          if [ -f pom.xml ]; then
            mvn -B -q package
          else
            gradle --no-daemon build
          fi

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: {{PROJECT_NAME}}
          path: |
            build/libs/*.jar
            target/*.jar
''';

  static const _appJava = '''package {{ORG}};

public class App {
    public static void main(String[] args) {
        System.out.println("Hello from {{PROJECT_NAME}}!");
    }
}
''';

  static const _settingsGradle = "rootProject.name = '{{PROJECT_NAME}}'\n";

  static const _buildGradle = '''plugins {
    id 'application'
}

group = '{{ORG}}'
version = '1.0.0'

repositories {
    mavenCentral()
}

dependencies {
    testImplementation 'org.junit.jupiter:junit-jupiter:5.10.2'
}

application {
    mainClass = '{{ORG}}.App'
}

tasks.named('test') {
    useJUnitPlatform()
}
''';

  static const _pomXml = '''<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>{{ORG}}</groupId>
  <artifactId>{{PROJECT_NAME}}</artifactId>
  <version>1.0.0</version>

  <properties>
    <maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
</project>
''';

  static const _gitignore = '''build/
target/
.gradle/
out/
*.class
.idea/
*.iml
''';

  static String _readme(bool useMaven) => '''# {{PROJECT_NAME}}

Java 项目，由 SLIPE 创建。

- 构建工具：${useMaven ? 'Maven' : 'Gradle'}
- 构建：`${useMaven ? 'mvn package' : 'gradle build'}`
- 运行：`${useMaven ? 'mvn exec:java' : 'gradle run'}`
''';
}
