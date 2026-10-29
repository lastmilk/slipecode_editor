/// GitHub Actions 工作流模板
///
/// 为 Flutter 项目生成云端构建工作流：
/// - push 到 main 自动构建 release APK；
/// - 手动 dispatch 可选择 Android 或 iOS；
/// - iOS 使用 macOS Runner + `--no-codesign`（后续可接入开发者证书签名）。
class GitHubActionsTemplates {
  GitHubActionsTemplates._();

  /// 工作流文件在仓库中的路径
  static const String workflowPath = '.github/workflows/slipecode_build.yml';

  /// Flutter 构建工作流
  static const String flutterBuildWorkflow = r'''
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
        default: 'apk-release'
        options:
          - apk-release
          - apk-debug
          - appbundle-release
          - ios-release

jobs:
  build-android:
    # push 触发只跑 Android；iOS 需要 macOS Runner，不随 push 自动执行
    if: ${{ github.event_name == 'push' || inputs.build_type != 'ios-release' }}
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      # 本地创建的项目不含平台工程，构建前用 flutter create 补齐。
      # org / 项目名从模板自带的 .slipecode.json 读取；缺失时退回默认值。
      - name: Generate platform files
        run: |
          set -e
          if [ -f .slipecode.json ]; then
            ORG=$(jq -r '.org // "com.example"' .slipecode.json)
            NAME=$(jq -r '.project_name // empty' .slipecode.json)
            flutter create --org "$ORG" --platforms=android ${NAME:+--project-name "$NAME"} .
          else
            flutter create --platforms=android .
          fi

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

  build-ios:
    # iOS 仅手动触发，使用 macOS Runner；先不签名
    if: ${{ github.event_name == 'workflow_dispatch' && inputs.build_type == 'ios-release' }}
    runs-on: macos-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Flutter
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Generate iOS platform files
        run: |
          set -e
          if [ -f .slipecode.json ]; then
            ORG=$(jq -r '.org // "com.example"' .slipecode.json)
            NAME=$(jq -r '.project_name // empty' .slipecode.json)
            flutter create --org "$ORG" --platforms=ios ${NAME:+--project-name "$NAME"} .
          else
            flutter create --platforms=ios .
          fi

      - name: Pub get
        run: flutter pub get

      # Developer 证书暂未配置，先构建无签名产物
      - name: Build iOS (no codesign)
        run: flutter build ios --release --no-codesign

      - name: Package Runner.app
        run: |
          set -e
          mkdir -p build/ios-artifact
          ditto -c -k --sequesterRsrc --keepParent \
            build/ios/iphoneos/Runner.app \
            build/ios-artifact/slipecode-ios-unsigned.zip

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: slipecode-ios-release
          path: build/ios-artifact/slipecode-ios-unsigned.zip
          if-no-files-found: error
''';
}
