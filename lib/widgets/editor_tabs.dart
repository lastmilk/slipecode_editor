import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/open_file.dart';
import '../providers/editor_provider.dart';

/// 编辑器标签栏组件
class EditorTabs extends StatelessWidget {
  const EditorTabs({super.key});

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
            onClose: () => editor.closeFile(file.path),
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

  const _TabItem({
    required this.file,
    required this.isActive,
    required this.isDark,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isActive
        ? (isDark ? const Color(0xFF1E1E1E) : Colors.white)
        : (isDark ? const Color(0xFF2D2D30) : const Color(0xFFD4D4D4));

    final fgColor = isActive
        ? (isDark ? Colors.white : Colors.black87)
        : (isDark ? Colors.white70 : Colors.black54);

    return GestureDetector(
      onTap: onTap,
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
    );
  }
}
