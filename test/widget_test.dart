import 'package:any2md_desktop/app.dart';
import 'package:any2md_desktop/domain/conversion_task.dart';
import 'package:any2md_desktop/domain/workspace_state.dart';
import 'package:any2md_desktop/features/workspace/markdown_preview_parser.dart';
import 'package:any2md_desktop/features/workspace/workspace_controller.dart';
import 'package:any2md_desktop/features/workspace/workspace_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestWorkspaceController extends WorkspaceController {
  TestWorkspaceController(this.initialState);

  final WorkspaceState initialState;
  Set<String>? confirmedSheetNames;
  String? editedMarkdown;

  @override
  WorkspaceState build() => initialState;

  @override
  Future<void> initialize() async {}

  @override
  void editMarkdown(String taskId, String markdown) {
    editedMarkdown = markdown;
  }

  @override
  Future<void> updateSheetSelection(
    String id,
    Iterable<String> sheetNames,
  ) async {}

  @override
  Future<void> confirmSheetSelection(
    String id,
    Iterable<String> sheetNames,
  ) async {
    confirmedSheetNames = sheetNames.toSet();
  }
}

class CountingMarkdownPreviewParser extends MarkdownPreviewParser {
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

Widget testApp(
  WorkspaceState state, {
  MarkdownPreviewParser? previewParser,
  TestWorkspaceController? controller,
}) {
  return ProviderScope(
    overrides: [
      workspaceControllerProvider.overrideWith(
        () => controller ?? TestWorkspaceController(state),
      ),
      desktopWindowEnabledProvider.overrideWithValue(false),
      if (previewParser != null)
        markdownPreviewParserProvider.overrideWithValue(previewParser),
    ],
    child: const Any2MdApp(),
  );
}

void main() {
  testWidgets('shows the usable empty workspace', (tester) async {
    await tester.pumpWidget(testApp(const WorkspaceState(initialized: true)));

    expect(find.text('Any2MD'), findsNothing);
    expect(find.text('添加文件'), findsOneWidget);
    expect(find.text('添加或拖入办公文档'), findsOneWidget);
    expect(find.text('0 个文件 · 完成 0'), findsOneWidget);

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme?.textTheme.bodyMedium?.fontFamily, 'Microsoft YaHei');
  });

  testWidgets('shows a converted task in the editor', (tester) async {
    final task = ConversionTask(
      id: 'task-1',
      sourcePath: r'C:\docs\report.docx',
      displayName: 'report.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 23),
      markdown: '# Report\n',
      isDirty: true,
    );
    await tester.pumpWidget(
      testApp(
        WorkspaceState(
          tasks: [task],
          selectedTaskId: task.id,
          initialized: true,
        ),
      ),
    );

    expect(find.text('report.docx'), findsWidgets);
    expect(find.text('未导出'), findsWidgets);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('copies all markdown from the editor toolbar', (tester) async {
    const markdown = '# Report\n\nComplete document body.\n';
    final task = ConversionTask(
      id: 'copy-task',
      sourcePath: r'C:\docs\copy.docx',
      displayName: 'copy.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 23),
      markdown: markdown,
    );
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      testApp(
        WorkspaceState(
          tasks: [task],
          selectedTaskId: task.id,
          initialized: true,
        ),
      ),
    );
    await tester.tap(find.byTooltip('复制全部 Markdown'));
    await tester.pump();

    expect(clipboardText, markdown);
  });

  testWidgets('focuses the editor after leaving preview and accepts input', (
    tester,
  ) async {
    final task = ConversionTask(
      id: 'focus-task',
      sourcePath: r'C:\docs\focus.docx',
      displayName: 'focus.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 27),
      markdown: '# Original',
      isDirty: true,
    );
    final controller = TestWorkspaceController(
      WorkspaceState(tasks: [task], selectedTaskId: task.id, initialized: true),
    );
    await tester.pumpWidget(
      testApp(controller.initialState, controller: controller),
    );

    await tester.tap(find.text('预览'));
    await tester.pump();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    final editorFinder = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.expands,
    );
    final editableText = tester.widget<EditableText>(
      find.descendant(of: editorFinder, matching: find.byType(EditableText)),
    );
    expect(editableText.focusNode.hasPrimaryFocus, isTrue);

    tester.testTextInput.enterText('# Updated');
    await tester.pump();

    expect(
      tester.widget<TextField>(editorFinder).controller!.text,
      '# Updated',
    );
    expect(controller.editedMarkdown, '# Updated');
  });

  testWidgets('allows the task sidebar to shrink to 180 pixels', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'sidebar_width': 120.0});
    final task = ConversionTask(
      id: 'narrow-sidebar',
      sourcePath: r'C:\docs\a-very-long-document-name.docx',
      displayName: 'a-very-long-document-name.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 24),
      markdown: '# Report',
    );

    await tester.pumpWidget(
      testApp(
        WorkspaceState(
          tasks: [task],
          selectedTaskId: task.id,
          initialized: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final splitView = tester.widget<MultiSplitView>(
      find.byType(MultiSplitView),
    );
    expect(splitView.controller!.areas.first.min, 180);
    expect(splitView.controller!.areas.first.size, 180);
    expect(find.byTooltip('移除任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selects and previews workbook sheets', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = ConversionTask(
      id: 'xlsx-1',
      sourcePath: r'C:\docs\report.xlsx',
      displayName: 'report.xlsx',
      inputType: 'xlsx',
      status: ConversionStatus.awaitingSheetSelection,
      createdAt: DateTime(2026, 7, 24),
      workbookSheets: const [
        WorkbookSheetInfo(
          name: 'Summary',
          index: 0,
          visibility: SheetVisibility.visible,
          isEmpty: false,
          rowCount: 2,
          columnCount: 2,
          preview: [
            ['Name', 'Value'],
            ['Alpha', '42'],
          ],
        ),
        WorkbookSheetInfo(
          name: 'Archive',
          index: 1,
          visibility: SheetVisibility.hidden,
          isEmpty: false,
          rowCount: 8,
          columnCount: 3,
          preview: [
            ['Old'],
          ],
        ),
        WorkbookSheetInfo(
          name: 'Empty',
          index: 2,
          visibility: SheetVisibility.visible,
          isEmpty: true,
          rowCount: 0,
          columnCount: 0,
          preview: [],
        ),
      ],
      selectedSheetNames: const ['Summary'],
    );
    await tester.pumpWidget(
      testApp(
        WorkspaceState(
          tasks: [task],
          selectedTaskId: task.id,
          initialized: true,
        ),
      ),
    );

    expect(find.text('3 个工作表 · 已选 1'), findsOneWidget);
    expect(find.text('转换所选 (1)'), findsOneWidget);
    expect(find.text('Summary'), findsWidgets);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Archive'), findsNothing);
    expect(find.text('空工作表'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.text('Archive'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('转换所选 (0)'), findsOneWidget);
    final convertButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '转换所选 (0)'),
    );
    expect(convertButton.onPressed, isNull);
  });

  testWidgets('warns before replacing manually edited workbook markdown', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = ConversionTask(
      id: 'xlsx-1',
      sourcePath: r'C:\docs\report.xlsx',
      displayName: 'report.xlsx',
      inputType: 'xlsx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 24),
      markdown: '# Edited',
      isDirty: true,
      hasManualEdits: true,
      workbookSheets: const [
        WorkbookSheetInfo(
          name: 'Summary',
          index: 0,
          visibility: SheetVisibility.visible,
          isEmpty: false,
          rowCount: 2,
          columnCount: 2,
          preview: [
            ['Name', 'Value'],
          ],
        ),
      ],
      selectedSheetNames: const ['Summary'],
    );
    final controller = TestWorkspaceController(
      WorkspaceState(tasks: [task], selectedTaskId: task.id, initialized: true),
    );
    await tester.pumpWidget(
      testApp(controller.initialState, controller: controller),
    );

    await tester.tap(find.text('1 个工作表'));
    await tester.pump();
    await tester.tap(find.text('转换所选 (1)'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('重新转换工作表？'), findsOneWidget);
    expect(find.textContaining('手动编辑'), findsOneWidget);
    expect(controller.confirmedSheetNames, isNull);
  });

  testWidgets('keeps the workbook selector compact in a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final task = ConversionTask(
      id: 'xlsx-narrow',
      sourcePath: r'C:\docs\narrow.xlsx',
      displayName: 'narrow.xlsx',
      inputType: 'xlsx',
      status: ConversionStatus.awaitingSheetSelection,
      createdAt: DateTime(2026, 7, 24),
      workbookSheets: const [
        WorkbookSheetInfo(
          name: 'Summary',
          index: 0,
          visibility: SheetVisibility.visible,
          isEmpty: false,
          rowCount: 1,
          columnCount: 1,
          preview: [
            ['Value'],
          ],
        ),
      ],
      selectedSheetNames: const ['Summary'],
    );

    await tester.pumpWidget(
      testApp(
        WorkspaceState(
          tasks: [task],
          selectedTaskId: task.id,
          initialized: true,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(Switch), findsNothing);
    expect(find.byTooltip('显示隐藏工作表'), findsOneWidget);
    expect(find.text('转换所选 (1)'), findsOneWidget);
    expect(find.text('Value'), findsOneWidget);
  });

  testWidgets('expands preview rows to show complete cell contents', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const longValue =
        'This workbook cell contains a long translation that must remain '
        'fully visible instead of being clipped after the second line.';
    final task = ConversionTask(
      id: 'xlsx-long-cell',
      sourcePath: r'C:\docs\long-cell.xlsx',
      displayName: 'long-cell.xlsx',
      inputType: 'xlsx',
      status: ConversionStatus.awaitingSheetSelection,
      createdAt: DateTime(2026, 7, 24),
      workbookSheets: const [
        WorkbookSheetInfo(
          name: 'Translations',
          index: 0,
          visibility: SheetVisibility.visible,
          isEmpty: false,
          rowCount: 1,
          columnCount: 1,
          preview: [
            [longValue],
          ],
        ),
      ],
      selectedSheetNames: const ['Translations'],
    );

    await tester.pumpWidget(
      testApp(
        WorkspaceState(
          tasks: [task],
          selectedTaskId: task.id,
          initialized: true,
        ),
      ),
    );

    final cellText = tester.widget<Text>(find.text(longValue));
    expect(cellText.maxLines, isNull);
    expect(tester.getSize(find.text(longValue)).height, greaterThan(42));
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows draggable scrollbars for the workbook preview', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preview = List.generate(
      20,
      (row) => List.generate(
        8,
        (column) => 'Row $row column $column contains scrolling content',
      ),
    );
    final task = ConversionTask(
      id: 'xlsx-scrollbars',
      sourcePath: r'C:\docs\scrollbars.xlsx',
      displayName: 'scrollbars.xlsx',
      inputType: 'xlsx',
      status: ConversionStatus.awaitingSheetSelection,
      createdAt: DateTime(2026, 7, 24),
      workbookSheets: [
        WorkbookSheetInfo(
          name: 'Large sheet',
          index: 0,
          visibility: SheetVisibility.visible,
          isEmpty: false,
          rowCount: preview.length,
          columnCount: preview.first.length,
          preview: preview,
        ),
      ],
      selectedSheetNames: const ['Large sheet'],
    );

    try {
      await tester.pumpWidget(
        testApp(
          WorkspaceState(
            tasks: [task],
            selectedTaskId: task.id,
            initialized: true,
          ),
        ),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    await tester.pump();

    final scrollViews = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .toList();
    final horizontalScroll = scrollViews.singleWhere(
      (view) => view.scrollDirection == Axis.horizontal,
    );
    final verticalScroll = scrollViews.singleWhere(
      (view) => view.scrollDirection == Axis.vertical,
    );
    final scrollbars = tester
        .widgetList<Scrollbar>(find.byType(Scrollbar))
        .toList();
    final horizontalScrollbar = scrollbars.singleWhere(
      (scrollbar) =>
          identical(scrollbar.controller, horizontalScroll.controller),
    );
    final verticalScrollbar = scrollbars.singleWhere(
      (scrollbar) => identical(scrollbar.controller, verticalScroll.controller),
    );

    expect(horizontalScrollbar.thumbVisibility, isTrue);
    expect(horizontalScrollbar.interactive, isTrue);
    expect(
      horizontalScrollbar.scrollbarOrientation,
      ScrollbarOrientation.bottom,
    );
    expect(verticalScrollbar.thumbVisibility, isTrue);
    expect(verticalScrollbar.interactive, isTrue);
    expect(verticalScrollbar.scrollbarOrientation, ScrollbarOrientation.right);
    expect(
      horizontalScroll.controller!.position.maxScrollExtent,
      greaterThan(0),
    );
    expect(verticalScroll.controller!.position.maxScrollExtent, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('provides a dedicated draggable scrollbar for the editor', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final task = ConversionTask(
      id: 'task-1',
      sourcePath: r'C:\docs\report.docx',
      displayName: 'report.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 23),
      markdown: List.generate(200, (index) => 'Line $index').join('\n'),
    );
    try {
      await tester.pumpWidget(
        testApp(
          WorkspaceState(
            tasks: [task],
            selectedTaskId: task.id,
            initialized: true,
          ),
        ),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    await tester.pump();

    final editorFinder = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.expands,
    );
    final scrollbarFinder = find.ancestor(
      of: editorFinder,
      matching: find.byType(Scrollbar),
    );
    final themeFinder = find.ancestor(
      of: editorFinder,
      matching: find.byType(ScrollbarTheme),
    );
    final generatedScrollbarFinder = find.descendant(
      of: editorFinder,
      matching: find.byWidgetPredicate((widget) => widget is RawScrollbar),
    );

    expect(editorFinder, findsOneWidget);
    expect(scrollbarFinder, findsOneWidget);
    expect(themeFinder, findsOneWidget);
    expect(generatedScrollbarFinder, findsNothing);

    final editor = tester.widget<TextField>(editorFinder);
    final scrollbar = tester.widget<Scrollbar>(scrollbarFinder);
    final scrollbarTheme = tester.widget<ScrollbarTheme>(themeFinder).data;
    final scrollController = editor.scrollController!;

    expect(identical(scrollbar.controller, scrollController), isTrue);
    expect(scrollbar.thumbVisibility, isTrue);
    expect(scrollbar.interactive, isTrue);
    expect(scrollbarTheme.thickness!.resolve(const <WidgetState>{}), 10);
    expect(scrollbarTheme.thickness!.resolve(const {WidgetState.hovered}), 12);
    expect(
      scrollbarTheme.trackVisibility!.resolve(const <WidgetState>{}),
      isFalse,
    );
    expect(
      scrollbarTheme.trackVisibility!.resolve(const {WidgetState.hovered}),
      isTrue,
    );
    expect(scrollbarTheme.minThumbLength, 48);
    expect(scrollController.position.maxScrollExtent, greaterThan(0));

    final scrollbarRect = tester.getRect(scrollbarFinder);
    final editorRect = tester.getRect(editorFinder);
    expect(scrollbarRect.right - editorRect.right, 16);

    final position = scrollController.position;
    final thumbHeight =
        (scrollbarRect.height *
                position.viewportDimension /
                (position.maxScrollExtent + position.viewportDimension))
            .clamp(48.0, scrollbarRect.height);
    final thumbCenter = Offset(
      scrollbarRect.right - 8,
      scrollbarRect.top + thumbHeight / 2,
    );
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer();
    await gesture.moveTo(thumbCenter);
    await tester.pumpAndSettle();
    await gesture.down(thumbCenter);
    await tester.pumpAndSettle();
    await gesture.moveBy(const Offset(0, 100));
    await tester.pumpAndSettle();
    await gesture.up();
    await gesture.removePointer();

    expect(scrollController.offset, greaterThan(0));
  });

  testWidgets('preview does not duplicate desktop scrollbars', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final parser = CountingMarkdownPreviewParser();
    final wideCode = List.filled(80, 'very_wide_code').join('_');
    final paragraphs = List.generate(
      200,
      (index) => 'Paragraph $index with enough text to render.',
    ).join('\n\n');
    final task = ConversionTask(
      id: 'task-1',
      sourcePath: r'C:\docs\report.docx',
      displayName: 'report.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 23),
      markdown: '# Preview\n\n$paragraphs\n\n```text\n$wideCode\n```\n',
    );
    try {
      await tester.pumpWidget(
        testApp(
          WorkspaceState(
            tasks: [task],
            selectedTaskId: task.id,
            initialized: true,
          ),
          previewParser: parser,
        ),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }

    await tester.tap(find.text('预览'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    final previewScrollFinder = find.byWidgetPredicate(
      (widget) =>
          widget is SingleChildScrollView &&
          widget.scrollDirection == Axis.vertical &&
          widget.padding == const EdgeInsets.fromLTRB(28, 22, 28, 48),
    );
    final horizontalScrollFinder = find.byWidgetPredicate(
      (widget) =>
          widget is SingleChildScrollView &&
          widget.scrollDirection == Axis.horizontal,
    );

    expect(previewScrollFinder, findsOneWidget);
    expect(horizontalScrollFinder, findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
    expect(parser.parseCalls, 1);

    final previewScroll = tester.widget<SingleChildScrollView>(
      previewScrollFinder,
    );
    final previewController = previewScroll.controller!;
    final previewAncestorScrollbars = find
        .ancestor(of: previewScrollFinder, matching: find.byType(Scrollbar))
        .evaluate()
        .map((element) => element.widget)
        .whereType<Scrollbar>();
    final previewDescendantScrollbars = find
        .descendant(of: previewScrollFinder, matching: find.byType(Scrollbar))
        .evaluate()
        .map((element) => element.widget)
        .whereType<Scrollbar>();

    expect(
      previewAncestorScrollbars.where(
        (scrollbar) => identical(scrollbar.controller, previewController),
      ),
      hasLength(1),
    );
    expect(
      previewDescendantScrollbars.where(
        (scrollbar) => identical(scrollbar.controller, previewController),
      ),
      isEmpty,
    );

    final maxScrollExtent = previewController.position.maxScrollExtent;
    expect(maxScrollExtent, greaterThan(0));
    previewController.jumpTo(maxScrollExtent);
    await tester.pump();
    previewController.jumpTo(0);
    await tester.pump();
    expect(previewController.position.maxScrollExtent, maxScrollExtent);
    expect(parser.parseCalls, 1);

    final horizontalScroll = tester.widget<SingleChildScrollView>(
      horizontalScrollFinder,
    );
    final horizontalController = horizontalScroll.controller!;
    final horizontalAncestorScrollbars = find
        .ancestor(of: horizontalScrollFinder, matching: find.byType(Scrollbar))
        .evaluate()
        .map((element) => element.widget)
        .whereType<Scrollbar>();
    final horizontalDescendantScrollbars = find
        .descendant(
          of: horizontalScrollFinder,
          matching: find.byType(Scrollbar),
        )
        .evaluate()
        .map((element) => element.widget)
        .whereType<Scrollbar>();

    expect(
      horizontalAncestorScrollbars.where(
        (scrollbar) => identical(scrollbar.controller, horizontalController),
      ),
      hasLength(1),
    );
    expect(
      horizontalDescendantScrollbars.where(
        (scrollbar) => identical(scrollbar.controller, horizontalController),
      ),
      isEmpty,
    );
  });
}
