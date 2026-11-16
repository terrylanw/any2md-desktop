import 'dart:async';
import 'dart:io';

import 'package:any2md_desktop/features/workspace/tsv_table_converter.dart';

// Run with: dart run tool/tsv_conversion_benchmark.dart
// CLI JIT measurements isolate conversion costs; they are not Flutter frame
// timings. Keep fixture creation and warm-up outside the measured samples.
Future<void> main() async {
  final source = List.generate(
    5000,
    (row) => List.generate(
      20,
      (column) => 'row${row}col$column text with punctuation *[]()',
    ).join('\t'),
  ).join('\n');
  final table = TsvTableConverter.parse(source);
  final expected = TsvTableConverter.toMarkdown(table, firstRowIsHeader: true);
  for (var pass = 0; pass < 3; pass++) {
    TsvTableConverter.parse(source);
    TsvTableConverter.toMarkdown(table, firstRowIsHeader: true);
    await TsvTableConverter.generateMarkdown(
      source,
      firstRowIsHeader: true,
      parsedTable: table,
    );
  }
  stdout.writeln(
    'input_chars=${source.length} rows=${table.rows.length} '
    'columns=${table.columnCount} output_chars=${expected.length}',
  );
  await _measure('parse_sync', () => TsvTableConverter.parse(source));
  await _measure(
    'generate_sync',
    () => TsvTableConverter.toMarkdown(table, firstRowIsHeader: true),
  );
  await _measure(
    'parse_background',
    () => TsvTableConverter.parseAsync(source),
  );
  await _measure('generate_background_cached_table', () async {
    final output = await TsvTableConverter.generateMarkdown(
      source,
      firstRowIsHeader: true,
      parsedTable: table,
    );
    if (output != expected) throw StateError('Markdown output mismatch');
    return output;
  });
}

Future<void> _measure(String label, FutureOr<Object> Function() work) async {
  final samples = <int>[];
  var largestEventGap = 0;
  for (var sample = 0; sample < 7; sample++) {
    final clock = Stopwatch()..start();
    var previousTick = clock.elapsedMicroseconds;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final tick = clock.elapsedMicroseconds;
      final gap = tick - previousTick;
      if (gap > largestEventGap) largestEventGap = gap;
      previousTick = tick;
    });
    try {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final watch = Stopwatch()..start();
      await work();
      samples.add(watch.elapsedMicroseconds);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    } finally {
      timer.cancel();
    }
  }
  samples.sort();
  stdout.writeln(
    '$label median_us=${samples[samples.length ~/ 2]} '
    'max_event_gap_us=$largestEventGap',
  );
}
