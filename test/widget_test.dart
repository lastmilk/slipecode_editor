// SLIPE 偏好设置模型测试
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipecode_editor/models/app_settings.dart';
import 'package:slipecode_editor/services/git_host.dart';

void main() {
  test('默认设置符合预期', () {
    const settings = AppSettings.defaults;
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.editorFontSize, 14);
    expect(settings.autoSave, isTrue);
    expect(settings.showSaying, isTrue);
    expect(settings.defaultGitHost, GitHost.github);
    expect(settings.createRepoOnCreate, isTrue);
  });

  test('JSON 往返保持字段一致', () {
    const settings = AppSettings(
      themeMode: ThemeMode.dark,
      editorFontSize: 18,
      autoSave: false,
      showSaying: false,
      defaultGitHost: GitHost.gitee,
      createRepoOnCreate: false,
    );
    final restored = AppSettings.fromJson(settings.toJson());
    expect(restored.themeMode, ThemeMode.dark);
    expect(restored.editorFontSize, 18);
    expect(restored.autoSave, isFalse);
    expect(restored.showSaying, isFalse);
    expect(restored.defaultGitHost, GitHost.gitee);
    expect(restored.createRepoOnCreate, isFalse);
  });

  test('Gitee Go 不支持 iOS 构建', () {
    expect(GitHost.gitee.supportsIosBuild, isFalse);
    expect(GitHost.github.supportsIosBuild, isTrue);
  });
}
