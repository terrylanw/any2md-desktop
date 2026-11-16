import 'package:any2md_desktop/features/workspace/table_input_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('large pasted input collapses while it is parsed', (
    tester,
  ) async {
    final source = List.generate(
      5000,
      (index) => 'key.$index\ttranslated value $index',
    ).join('\n');
    TsvTableInput? submitted;
    await _openDialog(tester, onResult: (input) => submitted = input);
    await tester.enterText(find.byType(TextField), source);
    await tester.pump();

    expect(find.text('大型表格文本已加载'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('正在解析表格…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 80));
    await _waitForValidation(tester);
    expect(find.text('识别到 2 列、4999 条数据'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    await tester.tap(find.text('生成 Markdown'));
    await tester.pumpAndSettle();
    expect(submitted?.text, source);
    expect(submitted?.table.rows, hasLength(5000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('large input waits for background validation before submission', (
    tester,
  ) async {
    final source = 'Name\tValue\n${'a' * (64 * 1024)}\t1';
    await _openDialog(tester);
    await tester.enterText(find.byType(TextField), source);
    await tester.pump();
    expect(find.text('正在解析表格…'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.pump(const Duration(milliseconds: 80));
    await _waitForValidation(tester);
    expect(find.text('识别到 2 列、1 条数据'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.text('正在解析表格…'), findsNothing);
    expect(find.text('识别到 2 列、2 条数据'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new small input wins over an in-flight large parse', (
    tester,
  ) async {
    await _openDialog(tester);
    await tester.enterText(
      find.byType(TextField),
      'Name\tValue\n${'a' * (64 * 1024)}\t1',
    );
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('编辑原文'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'New\tHeader\nfresh\t2');
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('fresh'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
    expect(find.text('正在解析表格…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the dialog during background validation is safe', (
    tester,
  ) async {
    await _openDialog(tester);
    await tester.enterText(
      find.byType(TextField),
      'Name\tValue\n${'a' * (64 * 1024)}\t1',
    );
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('取消'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pasted table preview scrollbars drag in both directions', (
    tester,
  ) async {
    await _openDialog(tester);
    await tester.enterText(find.byType(TextField), _wideTable);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final table = find.byType(DataTable);
    final scrollbars = find.ancestor(
      of: table,
      matching: find.byType(Scrollbar),
    );
    expect(scrollbars, findsNWidgets(2));
    final horizontalFinder = find.ancestor(
      of: table,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollbar &&
            widget.scrollbarOrientation == ScrollbarOrientation.bottom,
      ),
    );
    final verticalFinder = find.ancestor(
      of: table,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollbar &&
            widget.scrollbarOrientation == ScrollbarOrientation.right,
      ),
    );
    final horizontal = tester.widget<Scrollbar>(horizontalFinder);
    final vertical = tester.widget<Scrollbar>(verticalFinder);
    final views = tester
        .widgetList<SingleChildScrollView>(
          find.ancestor(
            of: table,
            matching: find.byType(SingleChildScrollView),
          ),
        )
        .toList();
    for (final scrollbar in [horizontal, vertical]) {
      expect(scrollbar.thumbVisibility, isTrue);
      expect(scrollbar.interactive, isTrue);
      expect(scrollbar.controller, isNotNull);
      expect(scrollbar.controller!.positions, hasLength(1));
      expect(scrollbar.controller!.position.maxScrollExtent, greaterThan(0));
    }
    expect(
      views
          .singleWhere((view) => view.scrollDirection == Axis.horizontal)
          .controller,
      same(horizontal.controller),
    );
    expect(
      views
          .singleWhere((view) => view.scrollDirection == Axis.vertical)
          .controller,
      same(vertical.controller),
    );

    final horizontalStart = tester.getTopLeft(table);
    await _dragThumb(tester, horizontalFinder, const Offset(120, 0));
    expect(horizontal.controller!.offset, greaterThan(0));
    expect(tester.getTopLeft(table).dx, lessThan(horizontalStart.dx));
    expect(vertical.controller!.offset, 0);
    final horizontalOffset = horizontal.controller!.offset;
    await _dragThumb(tester, horizontalFinder, const Offset(-80, 0));
    expect(horizontal.controller!.offset, lessThan(horizontalOffset));

    final verticalStart = tester.getTopLeft(table);
    final horizontalBeforeVertical = horizontal.controller!.offset;
    await _dragThumb(tester, verticalFinder, const Offset(0, 60));
    expect(vertical.controller!.offset, greaterThan(0));
    expect(tester.getTopLeft(table).dy, lessThan(verticalStart.dy));
    expect(horizontal.controller!.offset, horizontalBeforeVertical);
    final verticalOffset = vertical.controller!.offset;
    await _dragThumb(tester, verticalFinder, const Offset(0, -40));
    expect(vertical.controller!.offset, lessThan(verticalOffset));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'preview controllers survive input validation and dialog reopen',
    (tester) async {
      await _openDialog(tester);
      for (final source in [
        _wideTable,
        'Name\tValue\ninvalid',
        '',
        'Name\tValue\nvalid\t1',
        _wideTable,
      ]) {
        await tester.enterText(find.byType(TextField), source);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.text('Open table'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), _wideTable);
      await tester.pumpAndSettle();
      expect(find.byType(DataTable), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

final _wideTable = List.generate(
  6,
  (row) => List.generate(
    8,
    (column) => row == 0
        ? 'Language $column'
        : 'Translation row $row language $column with wide preview content',
  ).join('\t'),
).join('\n');

Future<void> _openDialog(
  WidgetTester tester, {
  ValueChanged<TsvTableInput?>? onResult,
}) async {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final input = await showTsvTableInputDialog(context);
              onResult?.call(input);
            },
            child: const Text('Open table'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open table'));
  await tester.pumpAndSettle();
}

Future<void> _waitForValidation(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (find.text('正在解析表格…').evaluate().isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  fail('Background TSV validation did not finish');
}

Future<void> _dragThumb(
  WidgetTester tester,
  Finder finder,
  Offset delta,
) async {
  final scrollbar = tester.widget<Scrollbar>(finder);
  final position = scrollbar.controller!.position;
  final rect = tester.getRect(finder);
  final horizontal = position.axis == Axis.horizontal;
  final extent = horizontal ? rect.width : rect.height;
  final thumbExtent =
      (extent *
              position.viewportDimension /
              (position.maxScrollExtent + position.viewportDimension))
          .clamp(18.0, extent);
  final thumbOffset =
      (extent - thumbExtent) * position.pixels / position.maxScrollExtent;
  final center = horizontal
      ? Offset(rect.left + thumbOffset + thumbExtent / 2, rect.bottom - 6)
      : Offset(rect.right - 6, rect.top + thumbOffset + thumbExtent / 2);
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer();
  await gesture.moveTo(center);
  await tester.pumpAndSettle();
  await gesture.down(center);
  await tester.pumpAndSettle();
  await gesture.moveBy(delta);
  await tester.pumpAndSettle();
  await gesture.up();
  await gesture.removePointer();
  await tester.pumpAndSettle();
}
