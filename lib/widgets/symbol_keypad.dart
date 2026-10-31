import 'package:flutter/material.dart';

/// 底部符号小键盘
///
/// 一行可横向滚动的小按钮，用于快速输入代码中常见的符号。
/// 使用 [onInsert] 把符号插入到调用方当前的文本光标处。
class SymbolKeypad extends StatelessWidget {
  const SymbolKeypad({
    super.key,
    required this.onInsert,
    this.isDark = false,
    this.height = 38,
  });

  final ValueChanged<String> onInsert;
  final bool isDark;
  final double height;

  static const List<String> symbols = [
    '{', '}', '(', ')', '[', ']', '<', '>',
    '"', "'", '`', '~', '/', '\\', '|', ':',
    ';', '=', '+', '-', '*', '%', '&', '!',
    '#', r'$', '@', '?', '^', ',', '.', '_',
  ];

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF252526) : const Color(0xFFF1F3F5);
    final border = isDark ? Colors.white12 : Colors.black12;

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: bg,
        border: Border(top: BorderSide(color: border)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        itemCount: symbols.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          final symbol = symbols[index];
          return Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => onInsert(symbol),
              child: Container(
                constraints: const BoxConstraints(minWidth: 30),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF333337) : Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: border),
                ),
                child: Text(
                  symbol,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontFamily: 'monospace',
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
