import 'dart:isolate';

class TsvTable {
  const TsvTable(this.rows);

  final List<List<String>> rows;

  int get columnCount => rows.first.length;
}

class TsvTableFormatException implements Exception {
  const TsvTableFormatException(this.message, {this.recordNumber});

  final String message;
  final int? recordNumber;

  @override
  String toString() =>
      recordNumber == null ? message : '第 $recordNumber 条记录：$message';
}

class TsvTableConverter {
  const TsvTableConverter._();

  static const backgroundThreshold = 64 * 1024;
  static final _keyLikeFirstCell = RegExp(
    r'^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)+$',
  );
  static final _numericFirstCell = RegExp(r'^\d+$');

  // Keep isolate closures outside widget/controller state so they only capture
  // the input needed by the computation.
  static Future<TsvTable> parseAsync(String source) async {
    if (source.length < backgroundThreshold) return parse(source);
    return Isolate.run(() => parse(source), debugName: 'tsv-parse');
  }

  static Future<String> generateMarkdown(
    String source, {
    required bool firstRowIsHeader,
    TsvTable? parsedTable,
  }) async {
    if (source.length < backgroundThreshold) {
      return toMarkdown(
        parsedTable ?? parse(source),
        firstRowIsHeader: firstRowIsHeader,
      );
    }
    if (parsedTable != null) {
      return _generateParsedMarkdown(parsedTable, firstRowIsHeader);
    }
    return _generateLargeMarkdown(source, firstRowIsHeader);
  }

  static Future<String> _generateParsedMarkdown(
    TsvTable table,
    bool firstRowIsHeader,
  ) => Isolate.run(
    () => toMarkdown(table, firstRowIsHeader: firstRowIsHeader),
    debugName: 'tsv-markdown',
  );

  static Future<String> _generateLargeMarkdown(
    String source,
    bool firstRowIsHeader,
  ) => Isolate.run(
    () => toMarkdown(parse(source), firstRowIsHeader: firstRowIsHeader),
    debugName: 'tsv-markdown',
  );

  static TsvTable parse(String input) {
    if (input.isEmpty) {
      throw const TsvTableFormatException('请输入表格内容');
    }
    final source = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final rows = <List<String>>[];
    var row = <String>[];
    StringBuffer? cell;
    var spanStart = 0;
    var inQuotes = false;
    var afterQuote = false;
    var atFieldStart = true;
    var recordNumber = 1;
    var endedWithRecordSeparator = false;

    void finishCell(int end) {
      final tail = source.substring(spanStart, end);
      if (cell case final buffer?) {
        buffer.write(tail);
        row.add(buffer.toString());
        cell = null;
      } else {
        row.add(tail);
      }
      spanStart = end + 1;
      atFieldStart = true;
      afterQuote = false;
    }

    void finishRow(int end) {
      finishCell(end);
      rows.add(List.unmodifiable(row));
      row = <String>[];
      recordNumber++;
    }

    for (var index = 0; index < source.length; index++) {
      final character = source.codeUnitAt(index);
      endedWithRecordSeparator = false;
      if (inQuotes) {
        if (character == 34) {
          final buffer = cell ??= StringBuffer();
          buffer.write(source.substring(spanStart, index));
          if (index + 1 < source.length && source.codeUnitAt(index + 1) == 34) {
            buffer.writeCharCode(34);
            index++;
          } else {
            inQuotes = false;
            afterQuote = true;
          }
          spanStart = index + 1;
        }
        continue;
      }
      if (afterQuote) {
        if (character == 9) {
          finishCell(index);
        } else if (character == 10) {
          finishRow(index);
          endedWithRecordSeparator = true;
        } else {
          final buffer = cell ??= StringBuffer();
          buffer.writeCharCode(34);
          inQuotes = true;
          afterQuote = false;
        }
        continue;
      }
      if (character == 34) {
        if (atFieldStart) {
          inQuotes = true;
          atFieldStart = false;
          spanStart = index + 1;
        }
      } else if (character == 9) {
        finishCell(index);
      } else if (character == 10) {
        final expectedColumns = rows.isEmpty ? null : rows.first.length;
        if (expectedColumns != null &&
            index + 1 < source.length &&
            !_startsPhysicalRecord(source, index + 1, expectedColumns)) {
          atFieldStart = false;
        } else {
          finishRow(index);
          endedWithRecordSeparator = true;
        }
      } else {
        atFieldStart = false;
      }
    }

    if (inQuotes) {
      throw TsvTableFormatException('引号未闭合', recordNumber: recordNumber);
    }
    if (!endedWithRecordSeparator) {
      finishCell(source.length);
      rows.add(List.unmodifiable(row));
    }

    final expectedColumns = rows.first.length;
    for (var index = 1; index < rows.length; index++) {
      if (rows[index].length != expectedColumns) {
        throw TsvTableFormatException(
          '检测到 ${rows[index].length} 列，首条记录为 $expectedColumns 列。请修正该行后再生成。',
          recordNumber: index + 1,
        );
      }
    }
    return TsvTable(List.unmodifiable(rows));
  }

  static bool _startsPhysicalRecord(
    String source,
    int start,
    int expectedColumns,
  ) {
    final lineEnd = source.indexOf('\n', start);
    final end = lineEnd == -1 ? source.length : lineEnd;
    if (end == start) return true;
    final firstTab = source.indexOf('\t', start);
    final firstCellEnd = firstTab == -1 || firstTab >= end ? end : firstTab;
    final firstCell = source.substring(start, firstCellEnd);
    // Localization exports may split multiline cells without TSV quoting.
    if (_keyLikeFirstCell.hasMatch(firstCell) ||
        _numericFirstCell.hasMatch(firstCell)) {
      return true;
    }
    var columns = 1;
    var inQuotes = false;
    var atFieldStart = true;
    for (var index = start; index < end; index++) {
      final character = source.codeUnitAt(index);
      if (inQuotes) {
        if (character == 34) {
          if (index + 1 < end && source.codeUnitAt(index + 1) == 34) {
            index++;
          } else {
            inQuotes = false;
          }
        }
      } else if (character == 34 && atFieldStart) {
        inQuotes = true;
        atFieldStart = false;
      } else if (character == 9) {
        columns++;
        atFieldStart = true;
      } else {
        atFieldStart = false;
      }
    }
    return columns >= expectedColumns;
  }

  static String toMarkdown(TsvTable table, {required bool firstRowIsHeader}) {
    final columns = table.columnCount;
    final header = firstRowIsHeader
        ? table.rows.first
        : List<String>.generate(columns, (index) => '列 ${index + 1}');
    final dataRows = firstRowIsHeader ? table.rows.skip(1) : table.rows;
    final output = StringBuffer();
    _writeMarkdownRow(output, header);
    output
      ..write('\n')
      ..write('| ${List<String>.filled(columns, '---').join(' | ')} |');
    for (final row in dataRows) {
      output.write('\n');
      _writeMarkdownRow(output, row);
    }
    return output.toString();
  }

  static void _writeMarkdownRow(StringBuffer output, List<String> cells) {
    output.write('| ');
    for (var index = 0; index < cells.length; index++) {
      if (index > 0) output.write(' | ');
      _writeEscapedCell(output, cells[index]);
    }
    output.write(' |');
  }

  static void _writeEscapedCell(StringBuffer output, String value) {
    var spanStart = 0;
    for (var index = 0; index < value.length; index++) {
      final character = value.codeUnitAt(index);
      final isAsciiPunctuation =
          (character >= 33 && character <= 47) ||
          (character >= 58 && character <= 64) ||
          (character >= 91 && character <= 96) ||
          (character >= 123 && character <= 126);
      if (!isAsciiPunctuation && character != 10 && character != 13) continue;
      if (spanStart < index) output.write(value.substring(spanStart, index));
      if (isAsciiPunctuation) {
        output
          ..write('\\')
          ..writeCharCode(character);
      } else {
        output.write('<br>');
        if (character == 13 &&
            index + 1 < value.length &&
            value.codeUnitAt(index + 1) == 10) {
          index++;
        }
      }
      spanStart = index + 1;
    }
    if (spanStart < value.length) output.write(value.substring(spanStart));
  }
}
