/// GitHub Actions 工作流模板
///
/// 为 Flutter 项目生成云端构建工作流：
/// push 到 main 自动构建 release APK，也可手动 dispatch 选择构建类型。
class GitHubActionsTemplates {
  GitHubActionsTemplates._();

  /// 工作流文件在仓库中的路径
  static const String workflowPath = '.github/workflows/slipecode_build.yml';

  /// Flutter 构建工作流
  static const String flutterBuildWorkflow = r'''
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
        default: 'apk-release'
        options:
          - apk-release
          - apk-debug
          - appbundle-release

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Pub get
        run: flutter pub get

      - name: Build
        env:
          BUILD_TYPE: ${{ inputs.build_type || 'apk-release' }}
        run: |
          set -e
          case "$BUILD_TYPE" in
            apk-debug)
              flutter build apk --debug
              ;;
            appbundle-release)
              flutter build appbundle --release
              ;;
            *)
              flutter build apk --release
              ;;
          esac

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: slipecode-${{ inputs.build_type || 'apk-release' }}
          path: |
            build/app/outputs/flutter-apk/*.apk
            build/app/outputs/bundle/**/*.aab
          if-no-files-found: error
''';
}
