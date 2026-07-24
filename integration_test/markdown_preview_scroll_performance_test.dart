import 'package:any2md_desktop/app.dart';
import 'package:any2md_desktop/domain/conversion_task.dart';
import 'package:any2md_desktop/domain/workspace_state.dart';
import 'package:any2md_desktop/features/workspace/markdown_preview_parser.dart';
import 'package:any2md_desktop/features/workspace/workspace_controller.dart';
import 'package:any2md_desktop/features/workspace/workspace_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _BenchmarkWorkspaceController extends WorkspaceController {
  _BenchmarkWorkspaceController(this.initialState);

  final WorkspaceState initialState;

  @override
  WorkspaceState build() => initialState;

  @override
  Future<void> initialize() async {}
}

class _CountingMarkdownPreviewParser extends MarkdownPreviewParser {
  int parseCalls = 0;

  @override
  Future<ParsedMarkdownDocument> parse({
    required String taskId,
    required int revision,
    required String source,
  }) {
    parseCalls++;
    return super.parse(taskId: taskId, revision: revision, source: source);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('large preview meets the post-load scroll frame budget', (
    tester,
  ) async {
    final markdown = _largeMarkdownFixture();
    final parser = _CountingMarkdownPreviewParser();
    final task = ConversionTask(
      id: 'performance-task',
      sourcePath: r'C:\benchmarks\large.docx',
      displayName: 'large.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 24),
      revision: 1,
      markdown: markdown,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          workspaceControllerProvider.overrideWith(
            () => _BenchmarkWorkspaceController(
              WorkspaceState(
                tasks: [task],
                selectedTaskId: task.id,
                initialized: true,
              ),
            ),
          ),
          desktopWindowEnabledProvider.overrideWithValue(false),
          markdownPreviewParserProvider.overrideWithValue(parser),
        ],
        child: const Any2MdApp(),
      ),
    );
    await tester.tap(find.text('预览'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    final verticalScrollFinder = find.byWidgetPredicate(
      (widget) => widget is CustomScrollView,
    );
    expect(verticalScrollFinder, findsOneWidget);
    expect(parser.parseCalls, 1);

    final scrollView = tester.widget<CustomScrollView>(verticalScrollFinder);
    final controller = scrollView.controller!;
    final maxExtent = controller.position.maxScrollExtent;
    expect(maxExtent, greaterThan(0));

    final timings = <FrameTiming>[];
    void collectTimings(List<FrameTiming> values) => timings.addAll(values);
    SchedulerBinding.instance.addTimingsCallback(collectTimings);
    try {
      for (var pass = 0; pass < 3; pass++) {
        for (var step = 0; step <= 60; step++) {
          final progress = pass.isEven ? step / 60 : 1 - step / 60;
          controller.jumpTo(maxExtent * progress);
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
    } finally {
      SchedulerBinding.instance.removeTimingsCallback(collectTimings);
    }

    expect(parser.parseCalls, 1);
    expect(controller.position.maxScrollExtent, closeTo(maxExtent, 0.5));
    expect(timings, isNotEmpty);

    final buildTimes =
        timings.map((timing) => timing.buildDuration.inMicroseconds).toList()
          ..sort();
    final p95Index = ((buildTimes.length * 0.95).ceil() - 1).clamp(
      0,
      buildTimes.length - 1,
    );
    expect(buildTimes[p95Index], lessThanOrEqualTo(16670));
    expect(buildTimes.last, lessThanOrEqualTo(50000));
  });
}

String _largeMarkdownFixture() {
  final buffer = StringBuffer('# Large preview benchmark\n\n');
  for (var index = 0; index < 3200; index++) {
    buffer.writeln(
      'Paragraph $index contains mixed **bold**, `inline code`, and a '
      '[reference](https://example.com/$index) to exercise rich text layout.',
    );
    buffer.writeln();
  }
  buffer
    ..writeln('| Index | Name | Description |')
    ..writeln('| ---: | --- | --- |');
  for (var index = 0; index < 200; index++) {
    buffer.writeln('| $index | Row $index | Benchmark table value $index |');
  }
  buffer
    ..writeln()
    ..writeln('```text');
  for (var index = 0; index < 1000; index++) {
    buffer.writeln(
      'code_line_$index = a_long_value_used_for_horizontal_scrolling',
    );
  }
  buffer
    ..writeln('```')
    ..writeln();
  while (buffer.length < 1024 * 1024) {
    buffer.writeln(
      'Padding paragraph ${buffer.length} keeps the generated fixture close '
      'to one MiB while remaining valid Markdown.\n',
    );
  }
  return buffer.toString();
}
