/// Gitee Go 流水线模板
///
/// Gitee Go 的流水线文件放在仓库根目录的 `.workflow/` 下，
/// push 到默认分支后自动执行。Gitee Go 目前没有 macOS Runner，
/// 因此这里只构建 Android；iOS 构建必须使用 GitHub Actions 的 macOS Runner。
class GiteeGoTemplates {
  GiteeGoTemplates._();

  /// 流水线文件在仓库中的路径
  static const String workflowPath = '.workflow/slipe_build.yml';

  /// Gitee Go 构建流水线（Android APK）
  static const String flutterBuildPipeline = r'''
version: '1.0'
name: slipe-build
displayName: SLIPE Build (Android)
triggers:
  push:
    branches:
      precise:
        - master
stages:
  - stage:
    name: build
    displayName: 构建 Android
    strategy: naturally
    trigger: auto
    steps:
      - step: build@gcc
        name: build_apk
        displayName: Flutter 构建 APK
        gccVersion: 9.4
        commands: |
          set -e
          export DEBIAN_FRONTEND=noninteractive
          export PUB_HOSTED_URL=https://pub.flutter-io.cn
          export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
          if command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=; fi
          $SUDO apt-get update -y
          $SUDO apt-get install -y openjdk-17-jdk-headless git curl unzip jq
          export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
          export PATH="$JAVA_HOME/bin:$PATH"

          if [ ! -x "$HOME/flutter/bin/flutter" ]; then
            git clone --depth 1 --branch stable https://gitee.com/mirrors/Flutter.git "$HOME/flutter" \
              || git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "$HOME/flutter"
          fi
          export PATH="$HOME/flutter/bin:$PATH"

          export ANDROID_HOME="$HOME/android-sdk"
          if [ ! -d "$ANDROID_HOME/cmdline-tools/latest" ]; then
            mkdir -p "$ANDROID_HOME/cmdline-tools"
            curl -L -o /tmp/cmdline-tools.zip \
              https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
            unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools
            mv /tmp/cmdline-tools/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
          fi
          export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
          yes | sdkmanager --licenses >/dev/null || true
          sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" >/dev/null

          flutter config --android-sdk "$ANDROID_HOME" --no-analytics >/dev/null || true
          ORG=$(jq -r '.org // "com.example"' .slipe.json 2>/dev/null || echo com.example)
          NAME=$(jq -r '.project_name // empty' .slipe.json 2>/dev/null || true)
          flutter create --org "$ORG" --platforms=android ${NAME:+--project-name "$NAME"} .
          flutter pub get
          flutter build apk --release

          echo "APK 构建完成；Gitee Go 无 macOS Runner，iOS 构建请使用 GitHub Actions。"
        artifacts:
          - name: BUILD_ARTIFACT
            path:
              - ./build/app/outputs/flutter-apk
''';
}
