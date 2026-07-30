import 'package:any2md_desktop/domain/conversion_task.dart';
import 'package:any2md_desktop/domain/workspace_state.dart';
import 'package:any2md_desktop/features/workspace/workspace_controller.dart';
import 'package:any2md_desktop/services/draft_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
