import 'package:any2md_desktop/app.dart';
import 'package:any2md_desktop/domain/conversion_task.dart';
import 'package:any2md_desktop/domain/workspace_state.dart';
import 'package:any2md_desktop/features/workspace/markdown_preview_parser.dart';
import 'package:any2md_desktop/features/workspace/workspace_controller.dart';
import 'package:any2md_desktop/features/workspace/workspace_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestWorkspaceController extends WorkspaceController {
  TestWorkspaceController(this.initialState);

  final WorkspaceState initialState;

  @override
  WorkspaceState build() => initialState;

  @override
  Future<void> initialize() async {}
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

Widget testApp(WorkspaceState state, {MarkdownPreviewParser? previewParser}) {
  return ProviderScope(
    overrides: [
      workspaceControllerProvider.overrideWith(
        () => TestWorkspaceController(state),
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
