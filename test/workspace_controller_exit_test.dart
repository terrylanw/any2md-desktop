import 'dart:async';

import 'package:any2md_desktop/domain/conversion_task.dart';
import 'package:any2md_desktop/domain/workspace_state.dart';
import 'package:any2md_desktop/features/workspace/workspace_controller.dart';
import 'package:any2md_desktop/services/converter_client.dart';
import 'package:any2md_desktop/services/draft_store.dart';
import 'package:any2md_desktop/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an edit made during background regeneration is preserved', () async {
    final task = ConversionTask(
      id: 'background-table',
      sourceKind: TaskSourceKind.pastedTable,
      sourceText: 'Name\tValue\nold\t1',
      generatedMarkdown: '| Name | Value |\n| --- | --- |\n| old | 1 |',
      displayName: '粘贴表格',
      inputType: 'tsv',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 30),
      markdown: '| Name | Value |\n| --- | --- |\n| old | 1 |',
    );
    final draftStore = _RecordingDraftStore();
    final container = ProviderContainer(
      overrides: [
        draftStoreProvider.overrideWithValue(draftStore),
        workspaceControllerProvider.overrideWith(
          () => _PresetWorkspaceController(
            WorkspaceState(
              tasks: [task],
              selectedTaskId: task.id,
              initialized: true,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(workspaceControllerProvider.notifier);
    final update = controller.updatePastedTable(
      taskId: task.id,
      sourceText: 'Name\tValue\n${'a' * (64 * 1024)}\t2',
      firstRowIsHeader: true,
      confirmOverwrite: true,
    );
    // Allow regeneration to pass the initial revision check and start its
    // background work before a newer edit is committed.
    await Future<void>.delayed(Duration.zero);
    controller.editMarkdown(task.id, '# Newer manual edit');
    expect(await update, isFalse);
    expect(controller.state.selectedTask!.markdown, '# Newer manual edit');
    expect(controller.state.selectedTask!.sourceText, task.sourceText);
  });

  test(
    'creates a ready pasted-table task without starting the file worker',
    () async {
      final draftStore = _RecordingDraftStore();
      final converter = _TrackingConverterClient();
      final container = ProviderContainer(
        overrides: [
          draftStoreProvider.overrideWithValue(draftStore),
          settingsServiceProvider.overrideWithValue(_TestSettingsService()),
          converterClientProvider.overrideWithValue(converter),
          workspaceControllerProvider.overrideWith(
            () => _PresetWorkspaceController(
              const WorkspaceState(initialized: true),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(workspaceControllerProvider.notifier);

      final task = await controller.createPastedTable(
        'English\tHindi\nOK\tठीक',
        firstRowIsHeader: true,
      );

      expect(task.isPastedTable, isTrue);
      expect(task.sourcePath, isNull);
      expect(task.sourceText, 'English\tHindi\nOK\tठीक');
      expect(task.status, ConversionStatus.ready);
      expect(task.markdown, contains('| OK | ठीक |'));
      expect(task.generatedMarkdown, task.markdown);
      expect(controller.state.selectedTaskId, task.id);
      expect(draftStore.saved.single.sourceText, task.sourceText);
      expect(converter.convertCalls, 0);
      expect(converter.inspectCalls, 0);
    },
  );

  test(
    'updates a pasted-table task only after edited Markdown is confirmed',
    () async {
      final originalMarkdown = '| Name | Value |\n| --- | --- |\n| alpha | 1 |';
      final task = ConversionTask(
        id: 'table-edit',
        sourcePath: null,
        sourceKind: TaskSourceKind.pastedTable,
        sourceText: 'Name\tValue\nalpha\t1',
        firstRowIsHeader: true,
        generatedMarkdown: originalMarkdown,
        displayName: '粘贴表格',
        inputType: 'tsv',
        status: ConversionStatus.ready,
        createdAt: DateTime(2026, 7, 30),
        markdown: originalMarkdown,
        exportedPath: r'C:\exports\table.md',
      );
      final draftStore = _RecordingDraftStore();
      final container = ProviderContainer(
        overrides: [
          draftStoreProvider.overrideWithValue(draftStore),
          workspaceControllerProvider.overrideWith(
            () => _PresetWorkspaceController(
              WorkspaceState(
                tasks: [task],
                selectedTaskId: task.id,
                initialized: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(workspaceControllerProvider.notifier);
      controller.editMarkdown(task.id, '# Manually edited');
      await controller.flushMarkdown(task.id);
      final revisionAfterManualEdit = controller.state.selectedTask!.revision;

      final blocked = await controller.updatePastedTable(
        taskId: task.id,
        sourceText: 'Name\tValue\nbeta\t2',
        firstRowIsHeader: true,
      );

      expect(blocked, isFalse);
      expect(controller.state.selectedTask!.markdown, '# Manually edited');
      expect(
        controller.state.selectedTask!.sourceText,
        'Name\tValue\nalpha\t1',
      );

      final updated = await controller.updatePastedTable(
        taskId: task.id,
        sourceText: 'Name\tValue\nbeta\t2',
        firstRowIsHeader: true,
        confirmOverwrite: true,
      );

      expect(updated, isTrue);
      expect(controller.state.selectedTask!.id, task.id);
      expect(controller.state.selectedTask!.markdown, contains('| beta | 2 |'));
      expect(controller.state.selectedTask!.sourceText, 'Name\tValue\nbeta\t2');
      expect(
        controller.state.selectedTask!.generatedMarkdown,
        controller.state.selectedTask!.markdown,
      );
      expect(
        controller.state.selectedTask!.revision,
        revisionAfterManualEdit + 1,
      );
      expect(controller.state.selectedTask!.exportedPath, isNull);
    },
  );

  test('exit flush persists pending markdown only once', () async {
    final task = ConversionTask(
      id: 'task-1',
      sourcePath: 'document.docx',
      displayName: 'document.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 30),
      markdown: '# Before\n',
    );
    final draftStore = _RecordingDraftStore();
    final container = ProviderContainer(
      overrides: [
        draftStoreProvider.overrideWithValue(draftStore),
        workspaceControllerProvider.overrideWith(
          () => _PresetWorkspaceController(
            WorkspaceState(
              tasks: [task],
              selectedTaskId: task.id,
              initialized: true,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(workspaceControllerProvider.notifier);

    controller.editMarkdown(task.id, '# After\n');
    await controller.flushAllMarkdown(persistDirty: true);

    expect(draftStore.saved, hasLength(1));
    expect(draftStore.saved.single.markdown, '# After\n');
    expect(
      container.read(workspaceControllerProvider).selectedTask?.markdown,
      '# After\n',
    );
  });

  test('flush commits pending Markdown before draft save completes', () async {
    final task = ConversionTask(
      id: 'task-1',
      sourcePath: 'document.docx',
      displayName: 'document.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime(2026, 7, 30),
      markdown: '# Before\n',
    );
    final draftStore = _BlockingDraftStore();
    final container = ProviderContainer(
      overrides: [
        draftStoreProvider.overrideWithValue(draftStore),
        workspaceControllerProvider.overrideWith(
          () => _PresetWorkspaceController(
            WorkspaceState(
              tasks: [task],
              selectedTaskId: task.id,
              initialized: true,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(workspaceControllerProvider.notifier);

    controller.editMarkdown(task.id, '# After\n');
    var flushCompleted = false;
    final flush = controller.flushAllMarkdown().then((_) {
      flushCompleted = true;
    });
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.selectedTask!.markdown, '# After\n');
    expect(draftStore.saved, hasLength(1));
    expect(flushCompleted, isFalse);

    draftStore.writeGate.complete();
    await flush;
  });
}

class _PresetWorkspaceController extends WorkspaceController {
  _PresetWorkspaceController(this.initialState);

  final WorkspaceState initialState;

  @override
  WorkspaceState build() => initialState;
}

class _RecordingDraftStore extends DraftStore {
  final saved = <ConversionTask>[];

  @override
  Future<void> save(ConversionTask task) async {
    saved.add(task);
  }
}

class _BlockingDraftStore extends DraftStore {
  final writeGate = Completer<void>();
  final saved = <ConversionTask>[];

  @override
  Future<void> save(ConversionTask task) async {
    saved.add(task);
    await writeGate.future;
  }
}

class _TestSettingsService extends SettingsService {
  int _nextTableNumber = 1;

  @override
  Future<int> reserveNextPastedTableNumber({int minimum = 1}) async {
    final number = _nextTableNumber < minimum ? minimum : _nextTableNumber;
    _nextTableNumber = number + 1;
    return number;
  }

  @override
  Future<void> advanceNextPastedTableNumber(int minimum) async {
    if (_nextTableNumber < minimum) _nextTableNumber = minimum;
  }
}

class _TrackingConverterClient extends ConverterClient {
  int convertCalls = 0;
  int inspectCalls = 0;

  @override
  Future<ConversionOutput> convert({
    required String inputPath,
    required String inputType,
    List<String>? sheetNames,
  }) async {
    convertCalls++;
    return const ConversionOutput(markdown: '', warnings: []);
  }

  @override
  Future<WorkbookInspectionOutput> inspectWorkbook({
    required String inputPath,
  }) async {
    inspectCalls++;
    return const WorkbookInspectionOutput(sheets: []);
  }
}
