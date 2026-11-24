import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/open_file.dart';
import '../providers/editor_provider.dart';

/// 编辑器标签栏组件
class EditorTabs extends StatelessWidget {
  const EditorTabs({super.key, this.onRequestClose, this.onContextMenu});

  /// 关闭标签前的回调（用于未保存确认）；为空时直接关闭
  final void Function(OpenFile file)? onRequestClose;

  /// 右键菜单（桌面）；为空时不响应右键
  final void Function(OpenFile file, Offset globalPosition)? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final editor = context.watch<EditorProvider>();
    final openFiles = editor.openFiles;
    final activePath = editor.activeFile?.path;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (openFiles.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 40,
      color: isDark ? const Color(0xFF252526) : const Color(0xFFECECEC),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: openFiles.length,
        itemBuilder: (context, index) {
          final file = openFiles[index];
          final isActive = file.path == activePath;
          return _TabItem(
            file: file,
            isActive: isActive,
            isDark: isDark,
            onTap: () => editor.setActiveFile(file.path),
            onClose: () {
              if (onRequestClose != null) {
                onRequestClose!(file);
              } else {
                editor.closeFile(file.path);
              }
            },
            onContextMenu: onContextMenu == null
                ? null
                : (position) => onContextMenu!(file, position),
          );
        },
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final OpenFile file;
  final bool isActive;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final void Function(Offset position)? onContextMenu;

  const _TabItem({
    required this.file,
    required this.isActive,
    required this.isDark,
    required this.onTap,
    required this.onClose,
    this.onContextMenu,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isActive
        ? (isDark ? const Color(0xFF1E1E1E) : Colors.white)
        : (isDark ? const Color(0xFF2D2D30) : const Color(0xFFD4D4D4));

    final fgColor = isActive
        ? (isDark ? Colors.white : Colors.black87)
        : (isDark ? Colors.white70 : Colors.black54);

    return Listener(
      // 中键点击关闭标签（桌面习惯）
      onPointerDown: (event) {
        if (event.buttons == kMiddleMouseButton) onClose();
      },
      child: GestureDetector(
        onTap: onTap,
        onSecondaryTapDown: onContextMenu == null
            ? null
            : (details) => onContextMenu!(details.globalPosition),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        constraints: const BoxConstraints(minWidth: 80),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border(
            right: BorderSide(
              color: isDark ? const Color(0xFF3C3C3C) : const Color(0xFFB0B0B0),
              width: 0.5,
            ),
            bottom: BorderSide(
              color: isActive
                  ? (isDark ? Colors.blue : Colors.blueAccent)
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              file.name,
              style: TextStyle(
                color: fgColor,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
            if (file.isModified) const SizedBox(width: 4),
            if (file.isModified)
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Colors.orange,
                  shape: BoxShape.circle,
                ),
              ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onClose,
              child: Icon(
                Icons.close,
                size: 16,
                color: fgColor.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}
