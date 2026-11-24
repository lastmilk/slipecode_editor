import 'package:flutter/material.dart';
import '../models/file_node.dart';

/// 文件树组件
///
/// 使用 ExpansionTile 递归实现，点击文件时回调；
/// 长按文件/文件夹弹出重命名、删除等操作菜单。
/// [openPaths] 中的文件（已打开标签页）会显示弱高亮，
/// [activePath] 使用更强的高亮与最左侧强调条（对齐 VS Code）。
class FileTree extends StatelessWidget {
  final FileNode? root;
  final Function(String path) onFileTap;
  final ValueChanged<FileNode>? onLongPress;

  /// 桌面右键菜单回调（位置为全局坐标）
  final void Function(FileNode node, Offset position)? onSecondaryTap;
  final bool isLoading;

  /// 已打开（含未保存）的文件路径
  final Set<String> openPaths;

  /// 当前激活文件路径
  final String? activePath;

  const FileTree({
    super.key,
    this.root,
    required this.onFileTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.isLoading = false,
    this.openPaths = const {},
    this.activePath,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (root == null || root!.children.isEmpty) {
      return const Center(
        child: Text('暂无文件'),
      );
    }

    // 显示项目根目录下的内容
    return ListView.builder(
      itemCount: root!.children.length,
      itemBuilder: (context, index) {
        return _buildNode(context, root!.children[index], depth: 0);
      },
    );
  }

  Widget _buildNode(BuildContext context, FileNode node, {required int depth}) {
    if (node.isDirectory) {
      return _DirectoryNode(
        node: node,
        depth: depth,
        onFileTap: onFileTap,
        onLongPress: onLongPress,
        onSecondaryTap: onSecondaryTap,
        openPaths: openPaths,
        activePath: activePath,
      );
    } else {
      return _FileNode(
        node: node,
        depth: depth,
        onTap: () => onFileTap(node.path),
        onLongPress: onLongPress == null ? null : () => onLongPress!(node),
        onSecondaryTap: onSecondaryTap,
        opened: openPaths.contains(node.path),
        active: activePath == node.path,
      );
    }
  }
}

class _DirectoryNode extends StatefulWidget {
  final FileNode node;
  final int depth;
  final Function(String path) onFileTap;
  final ValueChanged<FileNode>? onLongPress;
  final void Function(FileNode node, Offset position)? onSecondaryTap;
  final Set<String> openPaths;
  final String? activePath;

  const _DirectoryNode({
    required this.node,
    required this.depth,
    required this.onFileTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.openPaths = const {},
    this.activePath,
  });

  @override
  State<_DirectoryNode> createState() => _DirectoryNodeState();
}

class _DirectoryNodeState extends State<_DirectoryNode> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final padding = EdgeInsets.only(left: widget.depth * 16.0);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              _expanded = !_expanded;
            });
          },
          onLongPress: widget.onLongPress == null
              ? null
              : () => widget.onLongPress!(widget.node),
          onSecondaryTapDown: widget.onSecondaryTap == null
              ? null
              : (details) => widget.onSecondaryTap!(
                    widget.node,
                    details.globalPosition,
                  ),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Padding(
                  padding: padding,
                  child: Icon(
                    _expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                    size: 20,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  _expanded ? Icons.folder_open : Icons.folder,
                  size: 18,
                  color: Colors.amber[700],
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.node.name,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded && widget.node.children.isNotEmpty)
          for (final child in widget.node.children)
            _buildChild(child),
      ],
    );
  }

  Widget _buildChild(FileNode child) {
    if (child.isDirectory) {
      return _DirectoryNode(
        node: child,
        depth: widget.depth + 1,
        onFileTap: widget.onFileTap,
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onSecondaryTap,
        openPaths: widget.openPaths,
        activePath: widget.activePath,
      );
    } else {
      return _FileNode(
        node: child,
        depth: widget.depth + 1,
        onTap: () => widget.onFileTap(child.path),
        onLongPress: widget.onLongPress == null
            ? null
            : () => widget.onLongPress!(child),
        onSecondaryTap: widget.onSecondaryTap,
        opened: widget.openPaths.contains(child.path),
        active: widget.activePath == child.path,
      );
    }
  }
}

class _FileNode extends StatelessWidget {
  final FileNode node;
  final int depth;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final void Function(FileNode node, Offset position)? onSecondaryTap;

  /// 已打开标签页
  final bool opened;

  /// 当前激活文件
  final bool active;

  const _FileNode({
    required this.node,
    required this.depth,
    required this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.opened = false,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final padding = EdgeInsets.only(left: depth * 16.0 + 22);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final iconColor = _getFileIconColor(node.name);

    // 高亮：激活 > 已打开 > 透明（VS Code 风格）
    final background = active
        ? theme.colorScheme.primary.withValues(alpha: 0.18)
        : (opened
              ? (isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.045))
              : Colors.transparent);
    final textColor = active
        ? (isDark ? Colors.white : Colors.black)
        : (opened
              ? (isDark ? Colors.white70 : Colors.black87)
              : (isDark ? Colors.white70 : Colors.black87));
    final fontWeight = active ? FontWeight.w600 : FontWeight.w400;

    return Material(
      color: background,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTapDown: onSecondaryTap == null
            ? null
            : (details) => onSecondaryTap!(node, details.globalPosition),
        hoverColor: theme.colorScheme.primary.withValues(alpha: 0.08),
        child: Stack(
          children: [
            if (active)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  color: theme.colorScheme.primary,
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Padding(
                    padding: padding,
                    child: Icon(
                      _getFileIcon(node.name),
                      size: 16,
                      color: iconColor,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      node.name,
                      style: TextStyle(
                        fontSize: 13,
                        color: textColor,
                        fontWeight: fontWeight,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getFileIcon(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    switch (ext) {
      case 'dart':
        return Icons.code;
      case 'yaml':
      case 'yml':
      case 'json':
        return Icons.settings;
      case 'md':
        return Icons.description;
      case 'xml':
      case 'html':
      case 'kt':
      case 'java':
      case 'tsx':
      case 'ts':
        return Icons.code;
      case 'css':
        return Icons.brush;
      case 'js':
        return Icons.javascript;
      case 'png':
      case 'jpg':
      case 'gif':
      case 'webp':
        return Icons.image;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _getFileIconColor(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    switch (ext) {
      case 'dart':
        return const Color(0xFF0175C2);
      case 'yaml':
      case 'yml':
        return Colors.redAccent;
      case 'json':
        return Colors.amber;
      case 'md':
        return Colors.blueGrey;
      case 'png':
      case 'jpg':
      case 'gif':
      case 'webp':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }
}
