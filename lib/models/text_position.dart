/// 文本坐标：0 基行 / 0 基列（列按 UTF-16 code unit 计，与 LSP 一致）
class TextCoordinate implements Comparable<TextCoordinate> {
  final int line;
  final int character;

  const TextCoordinate(this.line, this.character);

  /// 由字符串偏移换算行列
  static TextCoordinate fromOffset(String text, int offset) {
    final safe = offset.clamp(0, text.length);
    var line = 0;
    var lineStart = 0;
    for (var i = 0; i < safe; i++) {
      if (text.codeUnitAt(i) == 10) {
        line++;
        lineStart = i + 1;
      }
    }
    return TextCoordinate(line, safe - lineStart);
  }

  /// 换算为字符串偏移（越界自动收敛）
  int toOffset(String text) {
    if (line <= 0) return character.clamp(0, text.length);
    var currentLine = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) != 10) continue;
      currentLine++;
      if (currentLine == line) {
        return (i + 1 + character).clamp(0, text.length);
      }
    }
    return text.length;
  }

  /// 该行起始偏移
  int lineStartOffset(String text) => TextCoordinate(line, 0).toOffset(text);

  /// 该行结束偏移（不含换行符）
  int lineEndOffset(String text) {
    final start = lineStartOffset(text);
    final newline = text.indexOf('\n', start);
    return newline == -1 ? text.length : newline;
  }

  @override
  int compareTo(TextCoordinate other) {
    if (line != other.line) return line.compareTo(other.line);
    return character.compareTo(other.character);
  }

  @override
  String toString() => '$line:$character';
}
