/// 进程角色
///
/// SLIPE 桌面端拆成两个独立进程（各自拥有独立地址空间、崩溃域）：
/// - [hub]：项目中心（默认启动的角色）
/// - [editor]：单个项目的编辑器窗口，由 Hub 通过子进程拉起
///
/// 窗口互斥：Hub 打开项目后隐藏或退出自身，Editor 同一时刻只保留一个
/// 可见窗口；Editor 返回 Hub 时先恢复/拉起 Hub 再关闭自己。
enum SlipeRole { hub, editor }

/// 启动参数
///
/// Hub 拉起 Editor 时传入：
/// ```
/// slipe_editor --role=editor --project=/path/to/project
/// ```
class LaunchArgs {
  LaunchArgs._();

  static SlipeRole role = SlipeRole.hub;

  /// Editor 角色要打开的项目路径
  static String projectPath = '';

  static bool get isEditor => role == SlipeRole.editor;

  static bool get isHub => role == SlipeRole.hub;

  /// 解析命令行参数（无法识别时保持默认 Hub 角色）
  static void parse(List<String> args) {
    for (final arg in args) {
      if (arg == '--role=editor' || arg == '--editor') {
        role = SlipeRole.editor;
      } else if (arg == '--role=hub' || arg == '--hub') {
        role = SlipeRole.hub;
      } else if (arg.startsWith('--project=')) {
        projectPath = arg.substring('--project='.length);
      }
    }
  }

  /// 当前进程用于拉起子进程的参数
  static List<String> editorArgs(String path) => [
    '--role=editor',
    '--project=$path',
  ];

  /// Editor 返回 Hub 时用于拉起 Hub 进程的参数
  static List<String> hubArgs() => ['--role=hub'];
}
