import 'package:flutter/material.dart';
import '../models/file_node.dart';

/// 文件树组件
///
/// 使用 ExpansionTile 递归实现，点击文件时回调；
/// 长按文件/文件夹弹出重命名、删除等操作菜单。
class FileTree extends StatelessWidget {
  final FileNode? root;
  final Function(String path) onFileTap;
  final ValueChanged<FileNode>? onLongPress;
  final bool isLoading;

  const FileTree({
    super.key,
    this.root,
    required this.onFileTap,
    this.onLongPress,
    this.isLoading = false,
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
      );
    } else {
      return _FileNode(
        node: node,
        depth: depth,
        onTap: () => onFileTap(node.path),
        onLongPress: onLongPress == null ? null : () => onLongPress!(node),
      );
    }
  }
}

class _DirectoryNode extends StatefulWidget {
  final FileNode node;
  final int depth;
  final Function(String path) onFileTap;
  final ValueChanged<FileNode>? onLongPress;

  const _DirectoryNode({
    required this.node,
    required this.depth,
    required this.onFileTap,
    this.onLongPress,
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
      );
    } else {
      return _FileNode(
        node: child,
        depth: widget.depth + 1,
        onTap: () => widget.onFileTap(child.path),
        onLongPress: widget.onLongPress == null
            ? null
            : () => widget.onLongPress!(child),
      );
    }
  }
}

class _FileNode extends StatelessWidget {
  final FileNode node;
  final int depth;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _FileNode({
    required this.node,
    required this.depth,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final padding = EdgeInsets.only(left: depth * 16.0 + 22);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconColor = _getFileIconColor(node.name);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      hoverColor: Colors.grey.withValues(alpha: 0.1),
      child: Container(
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
                  color: isDark ? Colors.white70 : Colors.black87,
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
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
