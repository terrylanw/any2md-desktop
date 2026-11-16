import 'package:any2md_desktop/app.dart';
import 'package:any2md_desktop/features/about/about_dialog.dart';
import 'package:any2md_desktop/services/app_info_service.dart';
import 'package:any2md_desktop/domain/conversion_task.dart';
import 'package:any2md_desktop/domain/workspace_state.dart';
import 'package:any2md_desktop/features/workspace/markdown_preview_parser.dart';
import 'package:any2md_desktop/features/workspace/workspace_controller.dart';
import 'package:any2md_desktop/features/workspace/workspace_page.dart';
import 'package:any2md_desktop/features/workspace/tsv_table_converter.dart';
import 'package:any2md_desktop/services/app_logger.dart';
import 'package:any2md_desktop/services/draft_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestWorkspaceController extends WorkspaceController {
  TestWorkspaceController(this.initialState);

  final WorkspaceState initialState;
  Set<String>? confirmedSheetNames;
  String? editedMarkdown;
  ConversionTask? createdTableTask;
  int _nextTableId = 0;

  @override
  WorkspaceState build() => initialState;

  void updateState(WorkspaceState value) => state = value;

  @override
  Future<void> initialize() async {}

  @override
  void editMarkdown(String taskId, String markdown) {
    editedMarkdown = markdown;
  }

  @override
  Future<ConversionTask> createPastedTable(
    String sourceText, {
    required bool firstRowIsHeader,
    TsvTable? parsedTable,
  }) async {
    final tableNumber = ++_nextTableId;
    final table = parsedTable ?? TsvTableConverter.parse(sourceText);
    final markdown = TsvTableConverter.toMarkdown(
      table,
      firstRowIsHeader: firstRowIsHeader,
    );
    final task = ConversionTask(
      id: 'pasted-table-$tableNumber',
      sourceKind: TaskSourceKind.pastedTable,
      sourceText: sourceText,
      firstRowIsHeader: firstRowIsHeader,
      generatedMarkdown: markdown,
      displayName: '粘贴表格 $tableNumber',
      inputType: 'tsv',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 30),
      markdown: markdown,
      isDirty: true,
    );
    createdTableTask = task;
    state = state.copyWith(
      tasks: [...state.tasks, task],
      selectedTaskId: task.id,
    );
    return task;
  }

  @override
  Future<bool> updatePastedTable({
    required String taskId,
    required String sourceText,
    required bool firstRowIsHeader,
    bool confirmOverwrite = false,
    TsvTable? parsedTable,
  }) async {
    final previous = state.tasks.where((task) => task.id == taskId).firstOrNull;
    if (previous == null || !previous.isPastedTable) return false;
    final markdown = TsvTableConverter.toMarkdown(
      parsedTable ?? TsvTableConverter.parse(sourceText),
      firstRowIsHeader: firstRowIsHeader,
    );
    if (previous.markdown != previous.generatedMarkdown && !confirmOverwrite) {
      return false;
    }
    final updated = previous.copyWith(
      sourceText: sourceText,
      firstRowIsHeader: firstRowIsHeader,
      markdown: markdown,
      generatedMarkdown: markdown,
      isDirty: true,
      revision: previous.revision + 1,
      clearExportedPath: true,
    );
    createdTableTask = updated;
    state = state.copyWith(
      tasks: [
        for (final task in state.tasks)
          if (task.id == taskId) updated else task,
      ],
    );
    return true;
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

class FailingMarkdownPreviewParser extends MarkdownPreviewParser {
  @override
  Future<ParsedMarkdownDocument> parse({
    required String taskId,
    required int revision,
    required String source,
    bool enableTableLineBreaks = false,
  }) {
    return Future.error(StateError('test parser failure'));
  }
}

class TestAppLogger extends AppLogger {
  @override
  Future<void> write(String message) async {}
}

Widget testApp(
  WorkspaceState state, {
  MarkdownPreviewParser? previewParser,
  TestWorkspaceController? controller,
  AppLogger? appLogger,
  AppInfoService? appInfoService,
  DraftStore? draftStore,
}) {
  return ProviderScope(
    overrides: [
      workspaceControllerProvider.overrideWith(
        () => controller ?? TestWorkspaceController(state),
      ),
      desktopWindowEnabledProvider.overrideWithValue(false),
      if (appLogger != null) appLoggerProvider.overrideWithValue(appLogger),
      if (appInfoService != null)
        appInfoServiceProvider.overrideWithValue(appInfoService),
      if (draftStore != null) draftStoreProvider.overrideWithValue(draftStore),
      if (previewParser != null)
        markdownPreviewParserProvider.overrideWithValue(previewParser),
    ],
    child: const Any2MdApp(),
  );
}

void main() {
  for (final fallback in [false, true]) {
    testWidgets(
      'long pasted table keeps a draggable horizontal scrollbar visible '
      '(fallback=$fallback)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = List.generate(
          90,
          (row) => List.generate(8, (column) => 'R$row C$column').join('\t'),
        ).join('\n');
        final markdown = TsvTableConverter.toMarkdown(
          TsvTableConverter.parse(source),
          firstRowIsHeader: true,
        );
        final task = _pastedTableTask(sourceText: source, markdown: markdown);
        await tester.pumpWidget(
          testApp(
            WorkspaceState(
              tasks: [task],
              selectedTaskId: task.id,
              initialized: true,
            ),
            previewParser: fallback ? FailingMarkdownPreviewParser() : null,
            appLogger: TestAppLogger(),
          ),
        );
        await tester.tap(find.text('预览'));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        final scrollbarFinder = find.byKey(
          const ValueKey('pasted-table-preview-horizontal-scrollbar'),
        );
        expect(scrollbarFinder, findsOneWidget);
        final scrollbar = tester.widget<Scrollbar>(scrollbarFinder);
        final controller = scrollbar.controller!;
        expect(controller.position.maxScrollExtent, greaterThan(0));
        final rect = tester.getRect(scrollbarFinder);
        final table = find.byType(Table).first;
        if (fallback) {
          expect(tester.getRect(table).bottom, greaterThan(rect.bottom));
        }
        final start = tester.getTopLeft(table);
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer();
        await gesture.moveTo(Offset(rect.left + 50, rect.bottom - 5));
        await tester.pumpAndSettle();
        await gesture.down(Offset(rect.left + 50, rect.bottom - 5));
        await tester.pumpAndSettle();
        await gesture.moveBy(const Offset(140, 0));
        await tester.pumpAndSettle();
        await gesture.up();
        await gesture.removePointer();
        expect(controller.offset, greaterThan(0));
        expect(tester.getTopLeft(table).dx, lessThan(start.dx));
        final horizontalOffset = controller.offset;
        final vertical = tester.widget<Scrollbar>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Scrollbar &&
                widget.controller != null &&
                widget.controller!.hasClients &&
                widget.controller!.position.axis == Axis.vertical,
          ),
        );
        vertical.controller!.jumpTo(
          vertical.controller!.position.maxScrollExtent / 2,
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(scrollbarFinder), rect);
        expect(controller.offset, horizontalOffset);
        expect(tester.takeException(), isNull);

        tester.view.physicalSize = const Size(2000, 900);
        await tester.pumpAndSettle();
        expect(controller.position.maxScrollExtent, 0);
        expect(controller.offset, 0);
        expect(tester.getSize(table).width, 8 * 180);
        expect(tester.takeException(), isNull);

        tester.view.physicalSize = const Size(1000, 700);
        await tester.pumpAndSettle();
        expect(controller.position.maxScrollExtent, greaterThan(0));
        final resizedRect = tester.getRect(scrollbarFinder);
        expect(resizedRect.width, lessThan(rect.width));
        final resizedStart = tester.getTopLeft(table);
        final resizedGesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await resizedGesture.addPointer();
        final thumbStart = Offset(
          resizedRect.left + 50,
          resizedRect.bottom - 5,
        );
        await resizedGesture.moveTo(thumbStart);
        await tester.pumpAndSettle();
        await resizedGesture.down(thumbStart);
        await tester.pumpAndSettle();
        await resizedGesture.moveBy(const Offset(100, 0));
        await tester.pumpAndSettle();
        await resizedGesture.up();
        await resizedGesture.removePointer();
        expect(controller.offset, greaterThan(0));
        expect(tester.getTopLeft(table).dx, lessThan(resizedStart.dx));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('shows the usable empty workspace', (tester) async {
    await tester.pumpWidget(testApp(const WorkspaceState(initialized: true)));

    expect(find.text('Any2MD'), findsNothing);
    expect(find.text('添加文件'), findsOneWidget);
    expect(find.byTooltip('关于 Any2MD'), findsOneWidget);
    expect(find.text('添加或拖入办公文档'), findsOneWidget);
    expect(find.text('0 个文件 · 完成 0'), findsOneWidget);

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme?.textTheme.bodyMedium?.fontFamily, 'Microsoft YaHei');
  });

  group('About toolbar entry', () {
    late int metadataReads;
    late AppInfoService appInfoService;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      metadataReads = 0;
      appInfoService = AppInfoService(
        operatingSystem: 'windows',
        packageInfoLoader: () async {
          metadataReads++;
          return PackageInfo(
            appName: 'Any2MD',
            packageName: 'com.any2md.desktop',
            version: '0.1.2',
            buildNumber: '1',
          );
        },
      );
    });

    for (final dismissal in ['close', 'escape', 'barrier']) {
      testWidgets('opens and restores focus after $dismissal', (tester) async {
        await tester.pumpWidget(
          testApp(
            const WorkspaceState(initialized: true),
            appInfoService: appInfoService,
          ),
        );
        await tester.pumpAndSettle();
        expect(metadataReads, 0);
        final button = find.ancestor(
          of: find.text('关于'),
          matching: find.byWidgetPredicate((widget) => widget is TextButton),
        );
        final focusNode = tester.widget<TextButton>(button).focusNode!;

        await tester.tap(find.byTooltip('关于 Any2MD'));
        await tester.pumpAndSettle();
        expect(find.byType(AppAboutDialog), findsOneWidget);
        expect(find.text('0.1.2'), findsOneWidget);
        expect(metadataReads, 1);

        switch (dismissal) {
          case 'close':
            await tester.tap(find.text('关闭'));
          case 'escape':
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          case 'barrier':
            await tester.tapAt(const Offset(5, 100));
        }
        await tester.pumpAndSettle();
        expect(find.byType(AppAboutDialog), findsNothing);
        expect(focusNode.hasFocus, isTrue);

        await tester.tap(find.text('关于'));
        await tester.pumpAndSettle();
        expect(metadataReads, 1);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('is available while the workspace initializes', (tester) async {
      await tester.pumpWidget(
        testApp(const WorkspaceState(), appInfoService: appInfoService),
      );
      await tester.tap(find.text('关于'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.byType(AppAboutDialog), findsOneWidget);
      expect(find.text('0.1.2'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps an edited document unchanged', (tester) async {
      final task = ConversionTask(
        id: 'about-dirty-task',
        sourcePath: r'C:\docs\draft.docx',
        displayName: 'draft.docx',
        inputType: 'docx',
        status: ConversionStatus.ready,
        createdAt: DateTime(2026, 11, 12),
        markdown: '# Unsaved document\n',
        isDirty: true,
      );
      await tester.pumpWidget(
        testApp(
          WorkspaceState(
            tasks: [task],
            selectedTaskId: task.id,
            initialized: true,
          ),
          appInfoService: appInfoService,
        ),
      );
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkspacePage)),
      );

      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      final state = container.read(workspaceControllerProvider);
      expect(state.selectedTask, same(task));
      expect(state.selectedTask!.isDirty, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        task.markdown,
      );
    });

    testWidgets('conversion updates continue while About is open', (
      tester,
    ) async {
      final task = ConversionTask(
        id: 'about-converting-task',
        sourcePath: r'C:\docs\report.docx',
        displayName: 'report.docx',
        inputType: 'docx',
        status: ConversionStatus.converting,
        createdAt: DateTime(2026, 11, 12),
      );
      final initial = WorkspaceState(
        tasks: [task],
        selectedTaskId: task.id,
        initialized: true,
      );
      final controller = TestWorkspaceController(initial);
      await tester.pumpWidget(
        testApp(
          initial,
          controller: controller,
          appInfoService: appInfoService,
        ),
      );
      await tester.tap(find.text('关于'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byType(AppAboutDialog), findsOneWidget);

      controller.updateState(
        initial.copyWith(
          tasks: [
            task.copyWith(
              status: ConversionStatus.ready,
              markdown: '# Converted while About was open\n',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppAboutDialog), findsOneWidget);
      expect(find.text('0.1.2'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(find.text('report.docx'), findsWidgets);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '# Converted while About was open\n',
      );
      expect(tester.takeException(), isNull);
    });
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

  testWidgets('creates a table task from the TSV input dialog', (tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TestWorkspaceController(
      const WorkspaceState(initialized: true),
    );
    await tester.pumpWidget(
      testApp(controller.initialState, controller: controller),
    );

    await tester.tap(find.text('粘贴表格'));
    await tester.pumpAndSettle();
    final input = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.expands,
    );
    await tester.enterText(input, 'English\tHindi\nOK\tठीक');
    await tester.pump();

    expect(
      tester.widget<TextField>(input).controller!.text,
      'English\tHindi\nOK\tठीक',
    );
    expect(find.text('识别到 2 列、1 条数据'), findsOneWidget);
    await tester.tap(find.text('生成 Markdown'));
    await tester.pumpAndSettle();

    expect(controller.createdTableTask, isNotNull);
    expect(controller.createdTableTask!.isPastedTable, isTrue);
    expect(controller.createdTableTask!.sourceText, 'English\tHindi\nOK\tठीक');
    expect(controller.createdTableTask!.markdown, contains('| OK | ठीक |'));
    expect(find.text('编辑源数据'), findsOneWidget);
  });

  testWidgets('renames a pasted-table task from its sidebar menu', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final firstTask = _pastedTableTask(id: 'table-one', displayName: '粘贴表格 1');
    final secondTask = _pastedTableTask(id: 'table-two', displayName: '粘贴表格 2');
    final controller = TestWorkspaceController(
      WorkspaceState(
        tasks: [firstTask, secondTask],
        selectedTaskId: firstTask.id,
        initialized: true,
      ),
    );
    final drafts = _WidgetTestDraftStore();
    await tester.pumpWidget(
      testApp(
        controller.initialState,
        controller: controller,
        draftStore: drafts,
      ),
    );

    Future<void> openRenameMenu() async {
      await tester.tap(find.byTooltip('更多任务操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
    }

    await openRenameMenu();
    expect(find.text('重命名任务'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.state.tasks.first.displayName, '粘贴表格 1');

    await openRenameMenu();
    final nameField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(nameField, '粘贴表格 2');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('已有同名粘贴表格任务'), findsOneWidget);
    expect(controller.state.tasks.first.displayName, '粘贴表格 1');

    await tester.enterText(nameField, '  客户名单  ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(controller.state.tasks.first.displayName, '客户名单');
    expect(find.text('客户名单'), findsNWidgets(2));
    expect(drafts.saved.last.displayName, '客户名单');
    expect(tester.takeException(), isNull);
  });

  testWidgets('blocks generation for a ragged TSV record', (tester) async {
    final controller = TestWorkspaceController(
      const WorkspaceState(initialized: true),
    );
    await tester.pumpWidget(
      testApp(controller.initialState, controller: controller),
    );
    await tester.tap(find.text('粘贴表格'));
    await tester.pumpAndSettle();

    final input = find.descendant(
      of: find.byType(Dialog),
      matching: find.byWidgetPredicate(
        (widget) => widget is TextField && widget.expands,
      ),
    );
    await tester.enterText(input, 'A\tB\nonly-one');
    await tester.pump();

    expect(find.textContaining('第 2 条记录'), findsOneWidget);
    final generateButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '生成 Markdown'),
    );
    expect(generateButton.onPressed, isNull);
    expect(controller.createdTableTask, isNull);
  });

  testWidgets('keeps entered text when reading the clipboard fails', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          throw PlatformException(code: 'clipboard_unavailable');
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
    final controller = TestWorkspaceController(
      const WorkspaceState(initialized: true),
    );
    await tester.pumpWidget(
      testApp(controller.initialState, controller: controller),
    );
    await tester.tap(find.text('粘贴表格'));
    await tester.pumpAndSettle();
    final input = find.descendant(
      of: find.byType(Dialog),
      matching: find.byWidgetPredicate(
        (widget) => widget is TextField && widget.expands,
      ),
    );
    const source = 'Name\tValue\nalpha\t1';
    await tester.enterText(input, source);
    await tester.tap(find.text('从剪贴板粘贴'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(input).controller!.text, source);
    expect(find.textContaining('读取剪贴板失败'), findsOneWidget);
    expect(find.text('生成 Markdown'), findsOneWidget);
  });

  testWidgets('canceling table regeneration preserves the task', (
    tester,
  ) async {
    final task = _pastedTableTask(
      markdown: '# Manual edits',
      generatedMarkdown: '| Name | Value |\n| --- | --- |\n| alpha | 1 |',
    );
    final controller = TestWorkspaceController(
      WorkspaceState(tasks: [task], selectedTaskId: task.id, initialized: true),
    );
    await tester.pumpWidget(
      testApp(controller.initialState, controller: controller),
    );

    await tester.tap(find.text('编辑源数据'));
    await tester.pumpAndSettle();
    final input = find.descendant(
      of: find.byType(Dialog),
      matching: find.byWidgetPredicate(
        (widget) => widget is TextField && widget.expands,
      ),
    );
    await tester.enterText(input, 'Name\tValue\nbeta\t2');
    await tester.tap(find.text('重新生成'));
    await tester.pumpAndSettle();
    expect(find.text('覆盖手动编辑？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(controller.state.tasks.single.sourceText, 'Name\tValue\nalpha\t1');
    expect(controller.state.tasks.single.markdown, '# Manual edits');
    expect(controller.createdTableTask, isNull);
  });

  testWidgets('confirms edits before regenerating the same table task', (
    tester,
  ) async {
    final task = _pastedTableTask(
      markdown: '# Manual edits',
      generatedMarkdown: '| Name | Value |\n| --- | --- |\n| alpha | 1 |',
    );
    final controller = TestWorkspaceController(
      WorkspaceState(tasks: [task], selectedTaskId: task.id, initialized: true),
    );
    await tester.pumpWidget(
      testApp(controller.initialState, controller: controller),
    );

    await tester.tap(find.text('编辑源数据'));
    await tester.pumpAndSettle();
    final input = find.descendant(
      of: find.byType(Dialog),
      matching: find.byWidgetPredicate(
        (widget) => widget is TextField && widget.expands,
      ),
    );
    await tester.enterText(input, 'Name\tValue\nbeta\t2');
    await tester.tap(find.text('重新生成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('覆盖并重新生成'));
    await tester.pumpAndSettle();

    expect(controller.state.tasks, hasLength(1));
    expect(controller.state.tasks.single.id, task.id);
    expect(controller.state.tasks.single.sourceText, 'Name\tValue\nbeta\t2');
    expect(controller.state.tasks.single.markdown, contains('| beta | 2 |'));
    expect(
      controller.state.tasks.single.generatedMarkdown,
      controller.state.tasks.single.markdown,
    );
  });

  testWidgets(
    'table preview uses fixed wide columns and scrolls horizontally',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final values = List<String>.generate(8, (index) => 'C$index');
      final source =
          '${values.join('\t')}\n"مرحبا\nsecond"\t${values.skip(1).join('\t')}';
      final markdown = TsvTableConverter.toMarkdown(
        TsvTableConverter.parse(source),
        firstRowIsHeader: true,
      );
      final task = _pastedTableTask(sourceText: source, markdown: markdown);
      await tester.pumpWidget(
        testApp(
          WorkspaceState(
            tasks: [task],
            selectedTaskId: task.id,
            initialized: true,
          ),
        ),
      );
      await tester.tap(find.text('预览'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      final horizontalFinder = find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      );
      expect(horizontalFinder, findsOneWidget);
      final horizontal = tester.widget<SingleChildScrollView>(horizontalFinder);
      expect(horizontal.controller!.position.maxScrollExtent, greaterThan(0));
      expect(
        tester
            .widget<Table>(find.byType(Table))
            .defaultColumnWidth
            .minIntrinsicWidth(const [], double.infinity),
        180,
      );
      final previewText = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((widget) => widget.text.toPlainText())
          .join();
      expect(previewText, contains('مرحبا'));
      expect(previewText, contains('second'));
      expect(previewText, contains('\n'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large pasted table only mounts nearby rows while scrolling', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = List.generate(
      1700,
      (row) => List.generate(12, (column) => 'row-$row-col-$column').join('\t'),
    ).join('\n');
    final task = _pastedTableTask(
      sourceText: source,
      markdown: TsvTableConverter.toMarkdown(
        TsvTableConverter.parse(source),
        firstRowIsHeader: true,
      ),
    );
    final parser = CountingMarkdownPreviewParser();
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
    await tester.tap(find.text('预览'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();

    int mountedRows() => tester
        .widgetList<Table>(find.byType(Table))
        .fold(0, (count, table) => count + table.children.length);
    expect(mountedRows(), inExclusiveRange(0, 128));
    final vertical = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    final horizontal = tester
        .widget<Scrollbar>(
          find.byKey(
            const ValueKey('pasted-table-preview-horizontal-scrollbar'),
          ),
        )
        .controller!;
    horizontal.jumpTo(horizontal.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final offset = horizontal.offset;
    vertical.controller!.jumpTo(
      vertical.controller!.position.maxScrollExtent / 2,
    );
    await tester.pumpAndSettle();
    expect(mountedRows(), inExclusiveRange(0, 128));
    expect(horizontal.offset, offset);
    final tableLefts = find
        .byType(Table)
        .evaluate()
        .map(
          (element) =>
              (element.renderObject as RenderBox).localToGlobal(Offset.zero).dx,
        );
    expect(tableLefts.toSet(), hasLength(1));
    expect(parser.parseCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fallback preview also renders pasted-table line breaks', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const source = 'A\tB\tC\tD\tE\tF\n"first\nsecond"\tمرحبا\t1\t2\t3\t4';
    final markdown = TsvTableConverter.toMarkdown(
      TsvTableConverter.parse(source),
      firstRowIsHeader: true,
    );
    final task = _pastedTableTask(sourceText: source, markdown: markdown);
    await tester.pumpWidget(
      testApp(
        WorkspaceState(
          tasks: [task],
          selectedTaskId: task.id,
          initialized: true,
        ),
        previewParser: FailingMarkdownPreviewParser(),
        appLogger: TestAppLogger(),
      ),
    );
    await tester.tap(find.text('预览'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(Markdown), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(
      tester.widget<Table>(find.byType(Table)).defaultColumnWidth,
      const FixedColumnWidth(180),
    );
    final horizontalScroll = tester.widget<SingleChildScrollView>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
    );
    expect(
      horizontalScroll.controller!.position.maxScrollExtent,
      greaterThan(0),
    );
    expect(tester.takeException(), isNull);
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

  testWidgets('large markdown preview builds offscreen blocks lazily', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final parser = CountingMarkdownPreviewParser();
    final paragraphs = List.generate(
      1100,
      (index) => 'Paragraph $index contains enough content to render.',
    ).join('\n\n');
    final task = ConversionTask(
      id: 'lazy-preview',
      sourcePath: r'C:\docs\large.docx',
      displayName: 'large.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 23),
      revision: 1,
      markdown: '# Lazy preview\n\n$paragraphs',
    );

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
    await tester.tap(find.text('预览'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(parser.parseCalls, 1);
    expect(
      find.byKey(const ValueKey('markdown-preview-block-lazy-preview-1-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('markdown-preview-block-lazy-preview-1-550')),
      findsNothing,
    );

    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    final controller = scrollView.controller!;
    controller.jumpTo(controller.position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('markdown-preview-block-lazy-preview-1-545')),
      findsOneWidget,
    );
  });
}

ConversionTask _pastedTableTask({
  String id = 'pasted-table-task',
  String displayName = '粘贴表格',
  String sourceText = 'Name\tValue\nalpha\t1',
  String? markdown,
  String? generatedMarkdown,
}) {
  final generated =
      generatedMarkdown ?? '| Name | Value |\n| --- | --- |\n| alpha | 1 |';
  return ConversionTask(
    id: id,
    sourceKind: TaskSourceKind.pastedTable,
    sourceText: sourceText,
    firstRowIsHeader: true,
    generatedMarkdown: generated,
    displayName: displayName,
    inputType: 'tsv',
    status: ConversionStatus.ready,
    createdAt: DateTime(2026, 7, 30),
    markdown: markdown ?? generated,
    isDirty: true,
  );
}

class _WidgetTestDraftStore extends DraftStore {
  final saved = <ConversionTask>[];

  @override
  Future<void> save(ConversionTask task) async {
    saved.add(task);
  }
}
