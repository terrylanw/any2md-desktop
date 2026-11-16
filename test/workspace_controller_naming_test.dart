import 'package:any2md_desktop/domain/conversion_task.dart';
import 'package:any2md_desktop/domain/workspace_state.dart';
import 'package:any2md_desktop/features/workspace/workspace_controller.dart';
import 'package:any2md_desktop/services/draft_store.dart';
import 'package:any2md_desktop/services/export_service.dart';
import 'package:any2md_desktop/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'settings serialize and persist concurrent number reservations',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService();

      final reservations = await Future.wait(
        List.generate(8, (_) => settings.reserveNextPastedTableNumber()),
      );

      expect(reservations.toList()..sort(), [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(await SettingsService().loadNextPastedTableNumber(), 9);
      expect(await SettingsService().reserveNextPastedTableNumber(), 9);
    },
  );

  test(
    'number allocation continues after removal, export, and restart',
    () async {
      final settings = _MemorySettingsService();
      final drafts = _MemoryDraftStore();
      final export = _RecordingExportService();
      final first = _container(settings, drafts, export: export);
      addTearDown(first.dispose);
      final controller = first.read(workspaceControllerProvider.notifier);

      final removed = await controller.createPastedTable(
        'A\tB\n1\t2',
        firstRowIsHeader: true,
      );
      expect(removed.displayName, '粘贴表格 1');
      await controller.removeTask(removed.id);

      final exported = await controller.createPastedTable(
        'A\tB\n3\t4',
        firstRowIsHeader: true,
      );
      expect(exported.displayName, '粘贴表格 2');
      await controller.exportTask(exported.id, '/unused/export.md');
      expect(export.calls, hasLength(1));

      final restarted = _container(settings, drafts, export: export);
      addTearDown(restarted.dispose);
      final next = await restarted
          .read(workspaceControllerProvider.notifier)
          .createPastedTable('A\tB\n5\t6', firstRowIsHeader: true);

      expect(next.displayName, '粘贴表格 3');
    },
  );

  test('migrates legacy pasted-table names in a stable order', () async {
    final oldDate = DateTime(2026, 1, 1);
    final drafts = _MemoryDraftStore(
      initial: [
        _tableTask(id: 'legacy-b', name: '粘贴表格', createdAt: oldDate),
        _tableTask(id: 'legacy-a', name: '粘贴表格', createdAt: oldDate),
        _tableTask(id: 'numbered', name: '粘贴表格 4', createdAt: oldDate),
        _tableTask(id: 'custom', name: '客户名单', createdAt: oldDate),
        _fileTask(id: 'file', name: '粘贴表格', createdAt: oldDate),
      ],
    );
    final settings = _MemorySettingsService(nextNumber: 2);
    final container = _container(
      settings,
      drafts,
      initialState: const WorkspaceState(),
    );
    addTearDown(container.dispose);
    final controller = container.read(workspaceControllerProvider.notifier);

    await controller.initialize();

    expect(_task(controller, 'legacy-a').displayName, '粘贴表格 5');
    expect(_task(controller, 'legacy-b').displayName, '粘贴表格 6');
    expect(_task(controller, 'numbered').displayName, '粘贴表格 4');
    expect(_task(controller, 'custom').displayName, '客户名单');
    expect(_task(controller, 'file').displayName, '粘贴表格');
    expect(drafts.saved.map((task) => task.id), ['legacy-a', 'legacy-b']);
    expect(settings.nextNumber, 7);

    final next = await controller.createPastedTable(
      'A\tB\n1\t2',
      firstRowIsHeader: true,
    );
    expect(next.displayName, '粘贴表格 7');
  });

  test(
    'rename validates names and preserves table content and revision',
    () async {
      final firstTask = _tableTask(
        id: 'first',
        name: '粘贴表格 1',
        markdown: '# Original',
      );
      final secondTask = _tableTask(id: 'second', name: 'Other table');
      final fileTask = _fileTask(id: 'file', name: 'report.docx');
      final drafts = _MemoryDraftStore();
      final settings = _MemorySettingsService();
      final container = _container(
        settings,
        drafts,
        initialState: WorkspaceState(
          tasks: [firstTask, secondTask, fileTask],
          selectedTaskId: firstTask.id,
          initialized: true,
        ),
      );
      addTearDown(container.dispose);
      final controller = container.read(workspaceControllerProvider.notifier);

      expect(
        await controller.renamePastedTable(firstTask.id, '  Customer list  '),
        PastedTableRenameResult.renamed,
      );
      final renamed = _task(controller, firstTask.id);
      expect(renamed.displayName, 'Customer list');
      expect(renamed.markdown, firstTask.markdown);
      expect(renamed.status, firstTask.status);
      expect(renamed.revision, firstTask.revision);
      expect(controller.state.selectedTaskId, firstTask.id);
      expect(drafts.saved.last.displayName, 'Customer list');

      expect(
        await controller.renamePastedTable(secondTask.id, '  '),
        PastedTableRenameResult.emptyName,
      );
      expect(
        await controller.renamePastedTable(secondTask.id, '粘贴表格'),
        PastedTableRenameResult.reservedName,
      );
      expect(
        await controller.renamePastedTable(secondTask.id, 'customer LIST'),
        PastedTableRenameResult.duplicateName,
      );
      expect(
        await controller.renamePastedTable(fileTask.id, 'New name'),
        PastedTableRenameResult.taskNotFound,
      );
    },
  );

  test(
    'pending Markdown is flushed before the renamed draft is saved',
    () async {
      final task = _tableTask(id: 'pending', name: '粘贴表格 1');
      final drafts = _MemoryDraftStore();
      final container = _container(
        _MemorySettingsService(),
        drafts,
        initialState: WorkspaceState(
          tasks: [task],
          selectedTaskId: task.id,
          initialized: true,
        ),
      );
      addTearDown(container.dispose);
      final controller = container.read(workspaceControllerProvider.notifier);
      controller.editMarkdown(task.id, '# Latest edit');

      final result = await controller.renamePastedTable(
        task.id,
        'Edited table',
      );

      expect(result, PastedTableRenameResult.renamed);
      expect(drafts.saved.last.displayName, 'Edited table');
      expect(drafts.saved.last.markdown, '# Latest edit');
    },
  );
}

ProviderContainer _container(
  _MemorySettingsService settings,
  _MemoryDraftStore drafts, {
  ExportService? export,
  WorkspaceState initialState = const WorkspaceState(initialized: true),
}) {
  return ProviderContainer(
    overrides: [
      settingsServiceProvider.overrideWithValue(settings),
      draftStoreProvider.overrideWithValue(drafts),
      if (export != null) exportServiceProvider.overrideWithValue(export),
      workspaceControllerProvider.overrideWith(
        () => _PresetWorkspaceController(initialState),
      ),
    ],
  );
}

ConversionTask _task(WorkspaceController controller, String id) =>
    controller.state.tasks.firstWhere((task) => task.id == id);

ConversionTask _tableTask({
  required String id,
  required String name,
  DateTime? createdAt,
  String markdown = '# Table',
}) => ConversionTask(
  id: id,
  sourceKind: TaskSourceKind.pastedTable,
  sourceText: 'A\tB\n1\t2',
  generatedMarkdown: markdown,
  displayName: name,
  inputType: 'tsv',
  status: ConversionStatus.ready,
  createdAt: createdAt ?? DateTime(2026, 1, 1),
  markdown: markdown,
  isDirty: true,
);

ConversionTask _fileTask({
  required String id,
  required String name,
  DateTime? createdAt,
}) => ConversionTask(
  id: id,
  sourcePath: 'C:/docs/$name',
  displayName: name,
  inputType: 'docx',
  status: ConversionStatus.ready,
  createdAt: createdAt ?? DateTime(2026, 1, 1),
);

class _PresetWorkspaceController extends WorkspaceController {
  _PresetWorkspaceController(this.initialState);

  final WorkspaceState initialState;

  @override
  WorkspaceState build() => initialState;
}

class _MemorySettingsService extends SettingsService {
  _MemorySettingsService({this.nextNumber = 1});

  int nextNumber;

  @override
  Future<AppThemePreference> loadTheme() async => AppThemePreference.system;

  @override
  Future<int> loadNextPastedTableNumber() async => nextNumber;

  @override
  Future<int> reserveNextPastedTableNumber({int minimum = 1}) async {
    final number = nextNumber < minimum ? minimum : nextNumber;
    nextNumber = number + 1;
    return number;
  }

  @override
  Future<void> advanceNextPastedTableNumber(int minimum) async {
    if (nextNumber < minimum) nextNumber = minimum;
  }
}

class _MemoryDraftStore extends DraftStore {
  _MemoryDraftStore({List<ConversionTask> initial = const []})
    : drafts = [...initial];

  final List<ConversionTask> drafts;
  final saved = <ConversionTask>[];

  @override
  Future<List<ConversionTask>> loadAll() async => [...drafts];

  @override
  Future<void> save(ConversionTask task) async {
    saved.add(task);
    final index = drafts.indexWhere((draft) => draft.id == task.id);
    if (index == -1) {
      drafts.add(task);
    } else {
      drafts[index] = task;
    }
  }

  @override
  Future<void> delete(String taskId) async {
    drafts.removeWhere((task) => task.id == taskId);
  }
}

class _RecordingExportService extends ExportService {
  final calls = <(String, String)>[];

  @override
  Future<void> exportMarkdown(String markdown, String destination) async {
    calls.add((markdown, destination));
  }
}
