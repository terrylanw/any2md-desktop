import 'dart:math' as math;

import 'package:any2md_desktop/app.dart';
import 'package:any2md_desktop/domain/conversion_task.dart';
import 'package:any2md_desktop/domain/workspace_state.dart';
import 'package:any2md_desktop/features/workspace/markdown_preview_parser.dart';
import 'package:any2md_desktop/features/workspace/workspace_controller.dart';
import 'package:any2md_desktop/features/workspace/workspace_page.dart';
import 'package:flutter/gestures.dart';
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
    bool enableTableLineBreaks = false,
  }) {
    parseCalls++;
    return super.parse(
      taskId: taskId,
      revision: revision,
      source: source,
      enableTableLineBreaks: enableTableLineBreaks,
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'large pasted table vertical scrollbar stays within frame budget',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        final parser = _CountingMarkdownPreviewParser();
        final task = ConversionTask(
          id: 'vertical-performance-task',
          sourceKind: TaskSourceKind.pastedTable,
          displayName: 'Wide pasted table',
          inputType: 'tsv',
          status: ConversionStatus.ready,
          createdAt: DateTime(2026, 11, 16),
          markdown: _wideTableFixture(),
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

        final scrollView = tester.widget<CustomScrollView>(
          find.byType(CustomScrollView),
        );
        final controller = scrollView.controller!;
        expect(controller.position.maxScrollExtent, greaterThan(0));
        final scrollbarFinder = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollbar && identical(widget.controller, controller),
        );
        expect(scrollbarFinder, findsOneWidget);
        final rect = tester.getRect(scrollbarFinder);
        final position = controller.position;
        final thumbExtent = math.max(
          48.0,
          rect.height *
              position.viewportDimension /
              (position.viewportDimension + position.maxScrollExtent),
        );
        final start = Offset(rect.right - 4, rect.top + thumbExtent / 2);
        final end = Offset(rect.right - 4, rect.bottom - thumbExtent / 2);
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: start);
        await gesture.moveTo(start);
        await tester.pumpAndSettle();
        await gesture.down(start);

        final timings = <FrameTiming>[];
        void collectTimings(List<FrameTiming> values) => timings.addAll(values);
        SchedulerBinding.instance.addTimingsCallback(collectTimings);
        try {
          for (var pass = 0; pass < 4; pass++) {
            for (var step = 1; step <= 60; step++) {
              final progress = pass.isEven ? step / 60 : 1 - step / 60;
              await gesture.moveTo(Offset.lerp(start, end, progress)!);
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(
              controller.offset,
              closeTo(pass.isEven ? controller.position.maxScrollExtent : 0, 4),
            );
          }
          await gesture.up();
          await gesture.removePointer();
          await tester.pumpAndSettle();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)),
          );
        } finally {
          SchedulerBinding.instance.removeTimingsCallback(collectTimings);
        }
        expect(parser.parseCalls, 1);
        expect(timings, isNotEmpty);
        final buildTimes =
            timings.map((t) => t.buildDuration.inMicroseconds).toList()..sort();
        final rasterTimes =
            timings.map((t) => t.rasterDuration.inMicroseconds).toList()
              ..sort();
        final p95 = (timings.length * 0.95).ceil() - 1;
        debugPrint(
          'Vertical table frames=${timings.length}, '
          'build p95=${buildTimes[p95]}us max=${buildTimes.last}us, '
          'raster p95=${rasterTimes[p95]}us max=${rasterTimes.last}us',
        );
        expect(buildTimes[p95], lessThanOrEqualTo(16670));
        expect(rasterTimes[p95], lessThanOrEqualTo(16670));
        expect(buildTimes.last, lessThanOrEqualTo(50000));
        expect(rasterTimes.last, lessThanOrEqualTo(50000));
      } finally {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        semantics.dispose();
      }
    },
  );

  testWidgets('wide pasted table scrollbar stays within the frame budget', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final parser = _CountingMarkdownPreviewParser();
      final task = ConversionTask(
        id: 'horizontal-performance-task',
        sourceKind: TaskSourceKind.pastedTable,
        displayName: 'Wide pasted table',
        inputType: 'tsv',
        status: ConversionStatus.ready,
        createdAt: DateTime(2026, 11, 16),
        markdown: _wideTableFixture(),
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

      final scrollbarFinder = find.byKey(
        const ValueKey('pasted-table-preview-horizontal-scrollbar'),
      );
      final controller = tester.widget<Scrollbar>(scrollbarFinder).controller!;
      expect(controller.position.maxScrollExtent, greaterThan(0));
      final rect = tester.getRect(scrollbarFinder);
      final thumbWidth =
          rect.width *
          controller.position.viewportDimension /
          (controller.position.maxScrollExtent +
              controller.position.viewportDimension);
      final left = Offset(rect.left + thumbWidth / 2, rect.bottom - 5);
      final right = Offset(rect.right - thumbWidth / 2, rect.bottom - 5);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: left);
      await gesture.moveTo(left);
      await tester.pumpAndSettle();
      await gesture.down(left);

      final timings = <FrameTiming>[];
      void collectTimings(List<FrameTiming> values) => timings.addAll(values);
      SchedulerBinding.instance.addTimingsCallback(collectTimings);
      try {
        for (var pass = 0; pass < 4; pass++) {
          for (var step = 1; step <= 60; step++) {
            final progress = pass.isEven ? step / 60 : 1 - step / 60;
            await gesture.moveTo(Offset.lerp(left, right, progress)!);
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(
            controller.offset,
            closeTo(pass.isEven ? controller.position.maxScrollExtent : 0, 4),
          );
        }
        await gesture.up();
        await gesture.removePointer();
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(collectTimings);
      }
      expect(parser.parseCalls, 1);
      expect(timings, isNotEmpty);
      final buildTimes =
          timings.map((t) => t.buildDuration.inMicroseconds).toList()..sort();
      final rasterTimes =
          timings.map((t) => t.rasterDuration.inMicroseconds).toList()..sort();
      final p95 = (timings.length * 0.95).ceil() - 1;
      debugPrint(
        'Horizontal table frames=${timings.length}, '
        'build p95=${buildTimes[p95]}us max=${buildTimes.last}us, '
        'raster p95=${rasterTimes[p95]}us max=${rasterTimes.last}us',
      );
      expect(buildTimes[p95], lessThanOrEqualTo(16670));
      expect(rasterTimes[p95], lessThanOrEqualTo(16670));
      expect(buildTimes.last, lessThanOrEqualTo(50000));
      expect(rasterTimes.last, lessThanOrEqualTo(50000));
    } finally {
      semantics.dispose();
    }
  });
}

String _wideTableFixture() {
  final buffer = StringBuffer()
    ..writeln(
      '| ${List.generate(12, (column) => 'Column $column').join(' | ')} |',
    )
    ..writeln('| ${List.filled(12, '---').join(' | ')} |');
  for (var row = 0; row < 1690; row++) {
    buffer.writeln(
      '| ${List.generate(12, (column) => 'Row $row **column $column**<br>Multiline preview content').join(' | ')} |',
    );
  }
  return buffer.toString();
}
