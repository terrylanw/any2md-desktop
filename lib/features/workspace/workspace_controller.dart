import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../core/supported_formats.dart';
import '../../domain/conversion_task.dart';
import '../../domain/workspace_state.dart';
import '../../services/converter_client.dart';
import '../../services/app_logger.dart';
import '../../services/draft_store.dart';
import '../../services/export_service.dart';
import '../../services/settings_service.dart';

final converterClientProvider = Provider<ConverterClient>((ref) {
  final logger = ref.read(appLoggerProvider);
  final client = ConverterClient(
    logSink: (message) => unawaited(logger.write(message)),
  );
  ref.onDispose(() => unawaited(client.dispose()));
  return client;
});

final appLoggerProvider = Provider<AppLogger>((ref) => AppLogger());

final draftStoreProvider = Provider<DraftStore>((ref) => DraftStore());
final exportServiceProvider = Provider<ExportService>((ref) => ExportService());
final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SettingsService(),
);

final workspaceControllerProvider =
    NotifierProvider<WorkspaceController, WorkspaceState>(
      WorkspaceController.new,
    );

class AddFilesResult {
  const AddFilesResult({
    required this.added,
    required this.duplicates,
    required this.unsupported,
  });

  final int added;
  final int duplicates;
  final List<String> unsupported;
}

class WorkspaceController extends Notifier<WorkspaceState> {
  static const _uuid = Uuid();
  final _draftTimers = <String, Timer>{};
  final _pendingMarkdown = <String, String>{};
  final _cancelledTaskIds = <String>{};
  bool _processing = false;
  bool _initializing = false;

  @override
  WorkspaceState build() {
    ref.onDispose(() {
      for (final timer in _draftTimers.values) {
        timer.cancel();
      }
      _pendingMarkdown.clear();
    });
    return const WorkspaceState();
  }

  Future<void> initialize() async {
    if (state.initialized || _initializing) return;
    _initializing = true;
    try {
      final results = await Future.wait<Object>([
        ref.read(draftStoreProvider).loadAll(),
        ref.read(settingsServiceProvider).loadTheme(),
      ]);
      final drafts = results[0] as List<ConversionTask>;
      final theme = results[1] as AppThemePreference;
      state = state.copyWith(
        tasks: drafts,
        selectedTaskId: drafts.isEmpty ? null : drafts.first.id,
        clearSelection: drafts.isEmpty,
        themePreference: theme,
        initialized: true,
      );
      if (drafts.any(
        (task) =>
            task.status == ConversionStatus.inspectionQueued ||
            task.status == ConversionStatus.queued,
      )) {
        unawaited(_drainQueue());
      }
    } on Object {
      state = state.copyWith(initialized: true);
    } finally {
      _initializing = false;
    }
  }

  Future<AddFilesResult> addPaths(Iterable<String> filePaths) async {
    final paths = filePaths.toList(growable: false);
    final existing = state.tasks
        .map((task) => _comparisonPath(task.sourcePath))
        .toSet();
    final added = <ConversionTask>[];
    final unsupported = <String>[];
    var duplicates = 0;

    final candidates = [
      for (final rawPath in paths)
        (
          rawPath: rawPath,
          absolutePath: path.normalize(path.absolute(rawPath)),
          inputType: inputTypeForPath(path.normalize(path.absolute(rawPath))),
        ),
    ];
    for (var offset = 0; offset < candidates.length; offset += 8) {
      final batch = candidates.skip(offset).take(8).toList(growable: false);
      final checks = await Future.wait(
        batch.map(
          (candidate) async => (
            candidate: candidate,
            exists: candidate.inputType != null
                ? await File(candidate.absolutePath).exists()
                : false,
          ),
        ),
      );
      for (final check in checks) {
        final candidate = check.candidate;
        if (candidate.inputType == null || !check.exists) {
          unsupported.add(candidate.rawPath);
          continue;
        }
        final absolutePath = candidate.absolutePath;
        final inputType = candidate.inputType!;
        if (!existing.add(_comparisonPath(absolutePath))) {
          duplicates++;
          continue;
        }
        added.add(
          ConversionTask(
            id: _uuid.v4(),
            sourcePath: absolutePath,
            displayName: path.basename(absolutePath),
            inputType: inputType,
            status: inputType == 'xlsx'
                ? ConversionStatus.inspectionQueued
                : ConversionStatus.queued,
            createdAt: DateTime.now(),
          ),
        );
      }
    }

    if (added.isNotEmpty) {
      state = state.copyWith(
        tasks: [...state.tasks, ...added],
        selectedTaskId: added.first.id,
      );
      await Future.wait(
        added
            .where((task) => task.inputType == 'xlsx')
            .map((task) => ref.read(draftStoreProvider).save(task)),
      );
      unawaited(_drainQueue());
    } else if (duplicates > 0 && paths.length == 1) {
      final rawPath = paths.first;
      final match = state.tasks.where(
        (task) =>
            _comparisonPath(task.sourcePath) ==
            _comparisonPath(path.normalize(path.absolute(rawPath))),
      );
      if (match.isNotEmpty) selectTask(match.first.id);
    }
    return AddFilesResult(
      added: added.length,
      duplicates: duplicates,
      unsupported: unsupported,
    );
  }

  void selectTask(String id) {
    if (state.tasks.any((task) => task.id == id)) {
      state = state.copyWith(selectedTaskId: id);
    }
  }

  void editMarkdown(String taskId, String markdown) {
    final task = _taskById(taskId);
    if (task == null) return;
    _pendingMarkdown[taskId] = markdown;
    if (!task.isDirty) {
      _replaceTask(
        task.copyWith(
          isDirty: true,
          hasManualEdits: true,
          clearExportedPath: true,
        ),
      );
    }
    _draftTimers.remove(taskId)?.cancel();
    _draftTimers[taskId] = Timer(const Duration(milliseconds: 120), () {
      _draftTimers.remove(taskId);
      unawaited(flushMarkdown(taskId));
    });
  }

  void updateMarkdown(String taskId, String markdown) {
    _pendingMarkdown.remove(taskId);
    _draftTimers.remove(taskId)?.cancel();
    unawaited(_commitMarkdown(taskId, markdown));
  }

  Future<void> flushMarkdown(String taskId) async {
    final markdown = _pendingMarkdown.remove(taskId);
    _draftTimers.remove(taskId)?.cancel();
    if (markdown != null) {
      await _commitMarkdown(taskId, markdown, persistNow: true);
    }
  }

  Future<void> flushAllMarkdown({bool persistDirty = false}) async {
    await Future.wait(
      _pendingMarkdown.keys.toList(growable: false).map(flushMarkdown),
    );
    if (!persistDirty) return;
    final dirtyTasks = state.tasks
        .where((task) => task.isDirty)
        .toList(growable: false);
    for (final task in dirtyTasks) {
      _draftTimers.remove(task.id)?.cancel();
    }
    await Future.wait(
      dirtyTasks.map((task) => ref.read(draftStoreProvider).save(task)),
    );
  }

  Future<void> _commitMarkdown(
    String taskId,
    String markdown, {
    bool persistNow = false,
  }) async {
    final task = _taskById(taskId);
    if (task == null || task.markdown == markdown) return;
    final updated = task.copyWith(
      markdown: markdown,
      isDirty: true,
      clearExportedPath: true,
      revision: task.revision + 1,
    );
    _replaceTask(updated);
    if (persistNow) {
      await ref.read(draftStoreProvider).save(updated);
    } else {
      _scheduleDraft(updated);
    }
  }

  Future<void> retryTask(String id) async {
    final task = _taskById(id);
    if (task == null || task.status == ConversionStatus.converting) return;
    final needsInspection =
        task.inputType == 'xlsx' &&
        (task.workbookSheets.isEmpty ||
            task.errorCode == 'sheet_selection_invalid');
    final nextStatus = needsInspection
        ? ConversionStatus.inspectionQueued
        : task.inputType == 'xlsx' && task.selectedSheetNames.isEmpty
        ? ConversionStatus.awaitingSheetSelection
        : ConversionStatus.queued;
    final updated = task.copyWith(
      status: nextStatus,
      clearError: true,
      warnings: const [],
    );
    _replaceTask(updated);
    await ref.read(draftStoreProvider).save(updated);
    unawaited(_drainQueue());
  }

  Future<void> updateSheetSelection(
    String id,
    Iterable<String> sheetNames,
  ) async {
    final task = _taskById(id);
    if (task == null ||
        task.inputType != 'xlsx' ||
        task.status != ConversionStatus.awaitingSheetSelection) {
      return;
    }
    final selectable = {
      for (final sheet in task.workbookSheets)
        if (sheet.isSelectable) sheet.name,
    };
    final requested = sheetNames.toSet();
    final ordered = [
      for (final sheet in task.workbookSheets)
        if (requested.contains(sheet.name) && selectable.contains(sheet.name))
          sheet.name,
    ];
    final updated = task.copyWith(
      selectedSheetNames: ordered,
      revision: task.revision + 1,
    );
    _replaceTask(updated);
    await ref.read(draftStoreProvider).save(updated);
  }

  Future<void> confirmSheetSelection(
    String id,
    Iterable<String> sheetNames,
  ) async {
    await flushMarkdown(id);
    final task = _taskById(id);
    if (task == null || task.inputType != 'xlsx') return;
    final requested = sheetNames.toSet();
    final ordered = [
      for (final sheet in task.workbookSheets)
        if (sheet.isSelectable && requested.contains(sheet.name)) sheet.name,
    ];
    if (ordered.isEmpty) return;
    final updated = task.copyWith(
      status: ConversionStatus.queued,
      selectedSheetNames: ordered,
      clearError: true,
      clearExportedPath: true,
      revision: task.revision + 1,
    );
    _replaceTask(updated);
    await ref.read(draftStoreProvider).save(updated);
    unawaited(_drainQueue());
  }

  Future<void> cancelTask(String id) async {
    final task = _taskById(id);
    if (task == null) return;
    await flushMarkdown(id);
    if (task.status == ConversionStatus.queued ||
        task.status == ConversionStatus.inspectionQueued ||
        task.status == ConversionStatus.awaitingSheetSelection) {
      final cancelled = task.copyWith(status: ConversionStatus.cancelled);
      _replaceTask(cancelled);
      await ref.read(draftStoreProvider).save(cancelled);
      return;
    }
    if (task.status != ConversionStatus.converting &&
        task.status != ConversionStatus.inspecting) {
      return;
    }
    _cancelledTaskIds.add(id);
    await ref.read(converterClientProvider).cancelCurrent();
  }

  Future<void> removeTask(String id) async {
    final task = _taskById(id);
    if (task == null) return;
    if (task.status == ConversionStatus.converting ||
        task.status == ConversionStatus.inspecting) {
      _cancelledTaskIds.add(id);
      await ref.read(converterClientProvider).cancelCurrent();
    }
    _draftTimers.remove(id)?.cancel();
    _pendingMarkdown.remove(id);
    await ref.read(draftStoreProvider).delete(id);
    final remaining = state.tasks.where((item) => item.id != id).toList();
    var selectedId = state.selectedTaskId;
    if (selectedId == id) {
      selectedId = remaining.isEmpty ? null : remaining.first.id;
    }
    state = state.copyWith(
      tasks: remaining,
      selectedTaskId: selectedId,
      clearSelection: selectedId == null,
    );
  }

  Future<void> exportTask(String id, String destination) async {
    await flushMarkdown(id);
    final task = _taskById(id);
    if (task == null || task.status != ConversionStatus.ready) return;
    await ref
        .read(exportServiceProvider)
        .exportMarkdown(task.markdown, destination);
    final updated = task.copyWith(isDirty: false, exportedPath: destination);
    _replaceTask(updated);
    await ref.read(draftStoreProvider).delete(id);
  }

  Future<void> setTheme(AppThemePreference preference) async {
    state = state.copyWith(themePreference: preference);
    await ref.read(settingsServiceProvider).saveTheme(preference);
  }

  Future<void> _drainQueue() async {
    if (_processing) return;
    _processing = true;
    try {
      while (true) {
        final queued = state.tasks.where(
          (task) =>
              task.status == ConversionStatus.inspectionQueued ||
              task.status == ConversionStatus.queued,
        );
        if (queued.isEmpty) break;
        final task = queued.first;
        if (task.status == ConversionStatus.inspectionQueued) {
          await _inspectTask(task);
          continue;
        }
        _replaceTask(task.copyWith(status: ConversionStatus.converting));
        try {
          final output = await ref
              .read(converterClientProvider)
              .convert(
                inputPath: task.sourcePath,
                inputType: task.inputType,
                sheetNames: task.inputType == 'xlsx'
                    ? task.selectedSheetNames
                    : null,
              );
          final current = _taskById(task.id);
          if (current == null) continue;
          final ready = current.copyWith(
            status: ConversionStatus.ready,
            markdown: output.markdown,
            warnings: output.warnings,
            isDirty: true,
            hasManualEdits: false,
            clearError: true,
            revision: current.revision + 1,
          );
          _replaceTask(ready);
          await ref.read(draftStoreProvider).save(ready);
        } on ConverterException catch (error) {
          final current = _taskById(task.id);
          if (current == null) continue;
          final wasCancelled =
              error.code == 'cancelled' || _cancelledTaskIds.remove(task.id);
          if (!wasCancelled && error.code == 'sheet_selection_invalid') {
            final stale = current.copyWith(
              status: ConversionStatus.inspectionQueued,
              clearWorkbookSheets: true,
              errorCode: error.code,
              errorMessage: error.message,
              errorRetryable: false,
            );
            _replaceTask(stale);
            await ref.read(draftStoreProvider).save(stale);
          } else {
            final failed = current.copyWith(
              status: wasCancelled
                  ? ConversionStatus.cancelled
                  : ConversionStatus.failed,
              errorCode: wasCancelled ? null : error.code,
              errorMessage: wasCancelled ? null : error.message,
              errorRetryable: !wasCancelled && error.retryable,
              clearError: wasCancelled,
            );
            _replaceTask(failed);
            await ref.read(draftStoreProvider).save(failed);
          }
        } on Object catch (error) {
          final current = _taskById(task.id);
          if (current == null) continue;
          final failed = current.copyWith(
            status: ConversionStatus.failed,
            errorCode: 'worker_crashed',
            errorMessage: error.toString(),
            errorRetryable: true,
          );
          _replaceTask(failed);
          await ref.read(draftStoreProvider).save(failed);
        }
      }
    } finally {
      _processing = false;
      if (state.tasks.any(
        (task) =>
            task.status == ConversionStatus.inspectionQueued ||
            task.status == ConversionStatus.queued,
      )) {
        unawaited(_drainQueue());
      }
    }
  }

  Future<void> _inspectTask(ConversionTask task) async {
    _replaceTask(task.copyWith(status: ConversionStatus.inspecting));
    try {
      final output = await ref
          .read(converterClientProvider)
          .inspectWorkbook(inputPath: task.sourcePath);
      final current = _taskById(task.id);
      if (current == null) return;
      final previousSelection = current.selectedSheetNames.toSet();
      final defaultSelection = [
        for (final sheet in output.sheets)
          if (sheet.isVisible && sheet.isSelectable) sheet.name,
      ];
      final retainedSelection = [
        for (final sheet in output.sheets)
          if (sheet.isSelectable && previousSelection.contains(sheet.name))
            sheet.name,
      ];
      final selection = previousSelection.isEmpty
          ? defaultSelection
          : retainedSelection;
      final autoConvert =
          previousSelection.isEmpty && defaultSelection.length == 1;
      final inspected = current.copyWith(
        status: autoConvert
            ? ConversionStatus.queued
            : ConversionStatus.awaitingSheetSelection,
        workbookSheets: output.sheets,
        selectedSheetNames: selection,
        workbookInspectionVersion:
            ConversionTask.currentWorkbookInspectionVersion,
        clearError: true,
        revision: current.revision + 1,
      );
      _replaceTask(inspected);
      await ref.read(draftStoreProvider).save(inspected);
    } on ConverterException catch (error) {
      final current = _taskById(task.id);
      if (current == null) return;
      final wasCancelled =
          error.code == 'cancelled' || _cancelledTaskIds.remove(task.id);
      final failed = current.copyWith(
        status: wasCancelled
            ? ConversionStatus.cancelled
            : ConversionStatus.failed,
        errorCode: wasCancelled ? null : error.code,
        errorMessage: wasCancelled ? null : error.message,
        errorRetryable: !wasCancelled && error.retryable,
        clearError: wasCancelled,
      );
      _replaceTask(failed);
      await ref.read(draftStoreProvider).save(failed);
    } on Object catch (error) {
      final current = _taskById(task.id);
      if (current == null) return;
      final failed = current.copyWith(
        status: ConversionStatus.failed,
        errorCode: 'worker_crashed',
        errorMessage: error.toString(),
        errorRetryable: true,
      );
      _replaceTask(failed);
      await ref.read(draftStoreProvider).save(failed);
    }
  }

  void _replaceTask(ConversionTask replacement) {
    state = state.copyWith(
      tasks: [
        for (final task in state.tasks)
          if (task.id == replacement.id) replacement else task,
      ],
    );
  }

  ConversionTask? _taskById(String id) {
    for (final task in state.tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  void _scheduleDraft(ConversionTask task) {
    _draftTimers.remove(task.id)?.cancel();
    _draftTimers[task.id] = Timer(const Duration(milliseconds: 700), () {
      unawaited(ref.read(draftStoreProvider).save(task));
      _draftTimers.remove(task.id);
    });
  }

  String _comparisonPath(String value) =>
      Platform.isWindows ? value.toLowerCase() : value;
}
