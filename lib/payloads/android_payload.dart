import 'package:flutter/material.dart';

import 'project_payload.dart';

/// 原生载荷：Android（Kotlin + Gradle）
class AndroidPayload extends ProjectPayload {
  const AndroidPayload();

  @override
  String get id => 'android';

  @override
  String get name => '原生（Android）';

  @override
  String get description => 'Kotlin 原生 Android 应用';

  @override
  IconData get icon => Icons.android;

  @override
  String get projectNameHint => 'my_android_app';

  @override
  String get defaultOrg => 'com.example';

  @override
  String get defaultLanguage => 'kotlin';

  @override
  Map<String, String> get languageByExtension => const {
        'kt': 'kotlin',
        'kts': 'kotlin',
        'gradle': 'kotlin',
        'java': 'java',
        'xml': 'xml',
        'json': 'json',
        'md': 'markdown',
        'properties': 'plaintext',
        'yml': 'yaml',
        'yaml': 'yaml',
      };

  @override
  List<PayloadBuildType> get buildTypes => const [
        PayloadBuildType('apk-debug', 'APK (Debug)', '.apk'),
        PayloadBuildType('apk-release', 'APK (Release)', '.apk'),
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
        default: 'apk-debug'
        options:
          - apk-debug
          - apk-release

jobs:
  build-android:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Java
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - name: Setup Gradle
        uses: gradle/actions/setup-gradle@v4
        with:
          gradle-version: '8.9'

      - name: Build
        run: |
          set -e
          if [ "${{ inputs.build_type || 'apk-debug' }}" = "apk-release" ]; then
            gradle assembleRelease
          else
            gradle assembleDebug
          fi

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: slipecode-${{ inputs.build_type || 'apk-debug' }}
          path: |
            app/build/outputs/apk/debug/*.apk
            app/build/outputs/apk/release/*.apk
          if-no-files-found: error
''';

  @override
  List<PayloadFile> templateFiles(String template) => const [
        PayloadFile.inline('settings.gradle.kts', _settingsGradle),
        PayloadFile.inline('build.gradle.kts', _rootGradle),
        PayloadFile.inline('gradle.properties', _gradleProperties),
        PayloadFile.inline('app/build.gradle.kts', _appGradle),
        PayloadFile.inline(
          'app/src/main/AndroidManifest.xml',
          _manifest,
        ),
        PayloadFile.inline(
          'app/src/main/java/{{ORG_PATH}}/MainActivity.kt',
          _mainActivity,
        ),
        PayloadFile.inline(
          'app/src/main/res/values/strings.xml',
          _strings,
        ),
        PayloadFile.inline('README.md', _readme),
        PayloadFile.inline('.gitignore', _gitignore),
        PayloadFile.inline('.slipecode.json', _marker),
      ];

  static const String _settingsGradle = '''
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "{{PROJECT_NAME}}"
include(":app")
''';

  static const String _rootGradle = '''
plugins {
    id("com.android.application") version "8.5.2" apply false
}
''';

  static const String _gradleProperties = '''
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
kotlin.code.style=official
''';

  static const String _appGradle = '''
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "{{ORG}}.{{PROJECT_NAME}}"
    compileSdk = 34

    defaultConfig {
        applicationId = "{{ORG}}.{{PROJECT_NAME}}"
        minSdk = 21
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}
''';

  static const String _manifest = '''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <application
        android:allowBackup="true"
        android:label="@string/app_name"
        android:supportsRtl="true">
        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>

</manifest>
''';

  static const String _mainActivity = '''package {{ORG}}.{{PROJECT_NAME}}

import android.app.Activity
import android.os.Bundle

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
    }
}
''';

  static const String _strings = '''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">{{PROJECT_NAME}}</string>
</resources>
''';

  static const String _readme = '''# {{PROJECT_NAME}}

由 SLIPE（Android 原生 Payload）创建。

```bash
gradle assembleDebug
```
''';

  static const String _gitignore = '''*.iml
.gradle/
local.properties
.idea/
build/
captures/
.externalNativeBuild/
.cxx/
''';

  static const String _marker = '''{
  "project_name": "{{PROJECT_NAME}}",
  "org": "{{ORG}}",
  "payload": "android",
  "created_by": "slipecode"
}
''';
}
