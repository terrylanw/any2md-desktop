import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:multi_split_view/multi_split_view.dart';
import 'package:path/path.dart' as path;
import 'package:window_manager/window_manager.dart';

import '../../core/supported_formats.dart';
import '../../domain/conversion_task.dart';
import '../../domain/workspace_state.dart';
import '../../services/settings_service.dart';
import '../../services/windows_tray_service.dart';
import '../about/about_dialog.dart';
import 'markdown_preview_parser.dart';
import 'table_input_dialog.dart';
import 'tsv_table_converter.dart';
import 'workspace_controller.dart';

enum EditorMode { edit, preview }

final desktopWindowEnabledProvider = Provider<bool>(
  (ref) => Platform.isWindows || Platform.isMacOS,
);

class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key});

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage>
    with WindowListener {
  static const _sidebarMinWidth = 180.0;
  static const _sidebarMaxWidth = 400.0;

  final _splitController = MultiSplitViewController();
  final _aboutFocusNode = FocusNode(debugLabel: 'about-button');
  bool _aboutDialogOpen = false;
  bool _dragging = false;
  late final bool _windowEnabled;
  late final bool _trayEnabled;
  late final SettingsService _settingsService;
  WindowsTrayService? _trayService;
  bool _trayReady = false;
  bool _exitInProgress = false;
  Timer? _windowSaveTimer;
  Timer? _sidebarSaveTimer;

  @override
  void initState() {
    super.initState();
    _windowEnabled = ref.read(desktopWindowEnabledProvider);
    _trayEnabled = _windowEnabled && Platform.isWindows;
    _settingsService = ref.read(settingsServiceProvider);
    if (_trayEnabled) {
      _trayService = WindowsTrayService(ref.read(appLoggerProvider).write);
    }
    _splitController.areas = [
      Area(size: 288, min: _sidebarMinWidth, max: _sidebarMaxWidth),
      Area(flex: 1, min: 480),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(workspaceControllerProvider.notifier).initialize());
      unawaited(_restoreSidebarWidth());
      if (_windowEnabled) {
        windowManager.addListener(this);
        unawaited(windowManager.setPreventClose(true));
      }
      if (_trayEnabled) unawaited(_initializeTray());
    });
  }

  Future<void> _initializeTray() async {
    final service = _trayService;
    if (service == null) return;
    final ready = await service.initialize(
      onShowRequested: _showWindow,
      onExitRequested: _requestExit,
    );
    if (!mounted) {
      if (ready) await service.shutdown();
      return;
    }
    _trayReady = ready;
  }

  Future<void> _restoreSidebarWidth() async {
    final width = await _settingsService.loadSidebarWidth();
    if (!mounted) return;
    _splitController.areas[0].size = width.clamp(
      _sidebarMinWidth,
      _sidebarMaxWidth,
    );
  }

  @override
  void dispose() {
    if (_windowEnabled) {
      windowManager.removeListener(this);
    }
    _trayService?.dispose();
    _splitController.dispose();
    _aboutFocusNode.dispose();
    _windowSaveTimer?.cancel();
    _sidebarSaveTimer?.cancel();
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    if (_trayReady && !_exitInProgress) {
      await windowManager.hide();
      return;
    }
    await _requestExit();
  }

  Future<void> _showWindow() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _requestExit() async {
    if (_exitInProgress) return;
    _exitInProgress = true;
    try {
      await ref
          .read(workspaceControllerProvider.notifier)
          .flushAllMarkdown(persistDirty: true);
      if (!mounted) return;
      final state = ref.read(workspaceControllerProvider);
      if (state.hasUnsavedChanges) {
        await _showWindow();
        if (!mounted) return;
        final close = await _confirm(
          title: '退出 Any2MD？',
          message: '仍有未导出的 Markdown，草稿会保留并在下次启动时恢复。',
          confirmLabel: '退出',
        );
        if (!close) return;
      }
      _trayReady = false;
      _windowSaveTimer?.cancel();
      _sidebarSaveTimer?.cancel();
      await windowManager.hide();
      await Future.wait<void>([
        ref.read(workspaceControllerProvider.notifier).stopForExit(),
        if (_trayService case final trayService?) trayService.shutdown(),
      ]);
      await windowManager.destroy();
    } finally {
      _exitInProgress = false;
    }
  }

  @override
  void onWindowMove() => _scheduleWindowBoundsSave();

  @override
  void onWindowResize() => _scheduleWindowBoundsSave();

  void _scheduleWindowBoundsSave() {
    _windowSaveTimer?.cancel();
    _windowSaveTimer = Timer(const Duration(milliseconds: 500), () async {
      final bounds = await windowManager.getBounds();
      await _settingsService.saveWindowBounds(bounds);
    });
  }

  Future<void> _showAbout() async {
    if (_aboutDialogOpen) return;
    _aboutDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => const AppAboutDialog(),
      );
    } finally {
      _aboutDialogOpen = false;
      if (mounted) _aboutFocusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final initialized = ref.watch(
      workspaceControllerProvider.select((state) => state.initialized),
    );
    return Scaffold(
      body: SafeArea(
        child: DropTarget(
          onDragEntered: (_) => setState(() => _dragging = true),
          onDragExited: (_) => setState(() => _dragging = false),
          onDragDone: (details) {
            setState(() => _dragging = false);
            unawaited(_addPaths(details.files.map((file) => file.path)));
          },
          child: Stack(
            children: [
              Column(
                children: [
                  _ToolbarConsumer(
                    onAddFiles: _pickFiles,
                    onPasteTable: _createPastedTable,
                    onCancel: _cancelSelected,
                    onExport: _exportSelected,
                    onOpenLogs: _openLogs,
                    onAbout: _showAbout,
                    aboutFocusNode: _aboutFocusNode,
                    onThemeChanged: (theme) => ref
                        .read(workspaceControllerProvider.notifier)
                        .setTheme(theme),
                  ),
                  Divider(height: 1, color: Theme.of(context).dividerColor),
                  Expanded(
                    child: initialized
                        ? MultiSplitView(
                            controller: _splitController,
                            onDividerDragUpdate: (_) {
                              final width = _splitController.areas[0].size;
                              if (width != null) {
                                _scheduleSidebarWidthSave(width);
                              }
                            },
                            builder: (context, area) => area.index == 0
                                ? _TaskSidebarConsumer(
                                    onSelect: _selectTask,
                                    onRemove: _removeTask,
                                    onRename: _renamePastedTable,
                                  )
                                : _DocumentWorkspaceConsumer(
                                    onMarkdownChanged: (id, markdown) => ref
                                        .read(
                                          workspaceControllerProvider.notifier,
                                        )
                                        .editMarkdown(id, markdown),
                                    onFlush: () => ref
                                        .read(
                                          workspaceControllerProvider.notifier,
                                        )
                                        .flushAllMarkdown(),
                                    onRetry: (id) => ref
                                        .read(
                                          workspaceControllerProvider.notifier,
                                        )
                                        .retryTask(id),
                                    onSheetSelectionChanged: (id, names) => ref
                                        .read(
                                          workspaceControllerProvider.notifier,
                                        )
                                        .updateSheetSelection(id, names),
                                    onConfirmSheetSelection: (id, names) => ref
                                        .read(
                                          workspaceControllerProvider.notifier,
                                        )
                                        .confirmSheetSelection(id, names),
                                    onEditTableSource: _editPastedTableSource,
                                  ),
                          )
                        : const Center(child: CircularProgressIndicator()),
                  ),
                  const _StatusBarConsumer(),
                ],
              ),
              if (_dragging) const _DropOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  void _scheduleSidebarWidthSave(double width) {
    _sidebarSaveTimer?.cancel();
    _sidebarSaveTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_settingsService.saveSidebarWidth(width));
    });
  }

  void _selectTask(String id) {
    final controller = ref.read(workspaceControllerProvider.notifier);
    unawaited(controller.flushAllMarkdown());
    controller.selectTask(id);
  }

  Future<void> _pickFiles() async {
    final files = await openFiles(
      acceptedTypeGroups: [
        XTypeGroup(
          label: '可转换文件（${supportedFormatsLabel()}）',
          extensions: supportedPickerExtensions(),
        ),
      ],
    );
    await _addPaths(files.map((file) => file.path));
  }

  Future<void> _createPastedTable() async {
    final input = await showTsvTableInputDialog(context);
    if (input == null || !mounted) return;
    try {
      await ref
          .read(workspaceControllerProvider.notifier)
          .createPastedTable(
            input.text,
            firstRowIsHeader: input.firstRowIsHeader,
            parsedTable: input.table,
          );
      if (mounted) _showMessage('Markdown 表格已添加到任务列表');
    } on TsvTableFormatException catch (error) {
      if (mounted) _showMessage(error.toString());
    } on Object catch (error) {
      if (mounted) _showMessage('创建表格失败：$error');
    }
  }

  Future<void> _editPastedTableSource(ConversionTask originalTask) async {
    final controller = ref.read(workspaceControllerProvider.notifier);
    await controller.flushMarkdown(originalTask.id);
    final task = ref
        .read(workspaceControllerProvider)
        .tasks
        .where((task) => task.id == originalTask.id && task.isPastedTable)
        .firstOrNull;
    if (task == null || !mounted) return;

    final input = await showTsvTableInputDialog(
      context,
      initialText: task.sourceText ?? '',
      firstRowIsHeader: task.firstRowIsHeader,
      isEditing: true,
    );
    if (input == null || !mounted) return;
    try {
      final saved = await controller.updatePastedTable(
        taskId: task.id,
        sourceText: input.text,
        firstRowIsHeader: input.firstRowIsHeader,
        parsedTable: input.table,
      );
      if (saved) {
        if (mounted) _showMessage('表格 Markdown 已重新生成');
        return;
      }
      final currentTask = ref
          .read(workspaceControllerProvider)
          .tasks
          .where((item) => item.id == task.id && item.isPastedTable)
          .firstOrNull;
      if (currentTask == null ||
          currentTask.markdown == currentTask.generatedMarkdown) {
        return;
      }

      final overwrite = await _confirm(
        title: '覆盖手动编辑？',
        message: '当前 Markdown 与上次生成结果不同，重新生成会覆盖手动编辑内容。',
        confirmLabel: '覆盖并重新生成',
      );
      if (!mounted || !overwrite) return;
      final savedAfterConfirmation = await controller.updatePastedTable(
        taskId: task.id,
        sourceText: input.text,
        firstRowIsHeader: input.firstRowIsHeader,
        confirmOverwrite: true,
        parsedTable: input.table,
      );
      if (savedAfterConfirmation && mounted) {
        _showMessage('表格 Markdown 已重新生成');
      }
    } on TsvTableFormatException catch (error) {
      if (mounted) _showMessage(error.toString());
    } on Object catch (error) {
      if (mounted) _showMessage('更新表格失败：$error');
    }
  }

  Future<void> _addPaths(Iterable<String> paths) async {
    final result = await ref
        .read(workspaceControllerProvider.notifier)
        .addPaths(paths);
    if (!mounted) return;
    if (result.unsupported.isNotEmpty) {
      _showMessage('已忽略 ${result.unsupported.length} 个不支持的文件');
    } else if (result.added == 0 && result.duplicates > 0) {
      _showMessage('文件已在任务列表中');
    }
  }

  Future<void> _cancelSelected() async {
    final task = ref.read(workspaceControllerProvider).selectedTask;
    if (task == null) return;
    await ref.read(workspaceControllerProvider.notifier).cancelTask(task.id);
  }

  Future<void> _exportSelected() async {
    final task = ref.read(workspaceControllerProvider).selectedTask;
    if (task == null || task.status != ConversionStatus.ready) return;
    final location = await getSaveLocation(
      suggestedName: '${path.basenameWithoutExtension(task.displayName)}.md',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Markdown', extensions: ['md', 'markdown']),
      ],
    );
    if (location == null) return;
    var destination = location.path;
    if (!const [
      '.md',
      '.markdown',
    ].contains(path.extension(destination).toLowerCase())) {
      destination = '$destination.md';
    }
    try {
      await ref
          .read(workspaceControllerProvider.notifier)
          .exportTask(task.id, destination);
      if (mounted) _showMessage('已导出到 $destination');
    } on Object catch (error) {
      if (mounted) _showMessage('导出失败：$error');
    }
  }

  Future<void> _openLogs() async {
    try {
      await ref.read(appLoggerProvider).openDirectory();
    } on Object catch (error) {
      if (mounted) _showMessage('无法打开日志目录：$error');
    }
  }

  Future<void> _removeTask(String id) async {
    final task = ref
        .read(workspaceControllerProvider)
        .tasks
        .where((item) => item.id == id)
        .firstOrNull;
    if (task == null) return;
    if (task.isDirty) {
      final remove = await _confirm(
        title: '移除任务？',
        message: '“${task.displayName}”包含未导出的内容，移除后草稿也会删除。',
        confirmLabel: '移除',
      );
      if (!remove) return;
    }
    await ref.read(workspaceControllerProvider.notifier).removeTask(id);
  }

  Future<void> _renamePastedTable(String id) async {
    final task = ref
        .read(workspaceControllerProvider)
        .tasks
        .where((item) => item.id == id && item.isPastedTable)
        .firstOrNull;
    if (task == null) return;
    final controller = ref.read(workspaceControllerProvider.notifier);
    await showDialog<void>(
      context: context,
      builder: (context) => _RenamePastedTableDialog(
        initialName: task.displayName,
        onRename: (name) => controller.renamePastedTable(id, name),
      ),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ToolbarConsumer extends ConsumerWidget {
  const _ToolbarConsumer({
    required this.onAddFiles,
    required this.onPasteTable,
    required this.onCancel,
    required this.onExport,
    required this.onOpenLogs,
    required this.onAbout,
    required this.aboutFocusNode,
    required this.onThemeChanged,
  });

  final VoidCallback onAddFiles;
  final VoidCallback onPasteTable;
  final VoidCallback onCancel;
  final VoidCallback onExport;
  final VoidCallback onOpenLogs;
  final VoidCallback onAbout;
  final FocusNode aboutFocusNode;
  final ValueChanged<AppThemePreference> onThemeChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(
      workspaceControllerProvider.select(
        (state) =>
            (selectedTask: state.selectedTask, theme: state.themePreference),
      ),
    );
    return _Toolbar(
      selectedTask: selection.selectedTask,
      themePreference: selection.theme,
      onAddFiles: onAddFiles,
      onPasteTable: onPasteTable,
      onCancel: onCancel,
      onExport: onExport,
      onOpenLogs: onOpenLogs,
      onAbout: onAbout,
      aboutFocusNode: aboutFocusNode,
      onThemeChanged: onThemeChanged,
    );
  }
}

class _TaskSidebarConsumer extends ConsumerWidget {
  const _TaskSidebarConsumer({
    required this.onSelect,
    required this.onRemove,
    required this.onRename,
  });

  final ValueChanged<String> onSelect;
  final ValueChanged<String> onRemove;
  final ValueChanged<String> onRename;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workspaceControllerProvider);
    return _TaskSidebar(
      state: state,
      onSelect: onSelect,
      onRemove: onRemove,
      onRename: onRename,
    );
  }
}

class _DocumentWorkspaceConsumer extends ConsumerWidget {
  const _DocumentWorkspaceConsumer({
    required this.onMarkdownChanged,
    required this.onFlush,
    required this.onRetry,
    required this.onSheetSelectionChanged,
    required this.onConfirmSheetSelection,
    required this.onEditTableSource,
  });

  final void Function(String id, String markdown) onMarkdownChanged;
  final Future<void> Function() onFlush;
  final ValueChanged<String> onRetry;
  final Future<void> Function(String id, Iterable<String> names)
  onSheetSelectionChanged;
  final Future<void> Function(String id, Iterable<String> names)
  onConfirmSheetSelection;
  final ValueChanged<ConversionTask> onEditTableSource;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(
      workspaceControllerProvider.select((state) => state.selectedTask),
    );
    return _DocumentWorkspace(
      task: task,
      onMarkdownChanged: onMarkdownChanged,
      onFlush: onFlush,
      onRetry: onRetry,
      onSheetSelectionChanged: onSheetSelectionChanged,
      onConfirmSheetSelection: onConfirmSheetSelection,
      onEditTableSource: onEditTableSource,
    );
  }
}

class _StatusBarConsumer extends ConsumerWidget {
  const _StatusBarConsumer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(
      workspaceControllerProvider.select(
        (state) => (
          taskCount: state.tasks.length,
          completedCount: state.completedCount,
          converting: state.tasks.any(
            (task) =>
                task.status == ConversionStatus.converting ||
                task.status == ConversionStatus.inspecting,
          ),
        ),
      ),
    );
    return _StatusBar(
      taskCount: summary.taskCount,
      completedCount: summary.completedCount,
      converting: summary.converting,
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.selectedTask,
    required this.themePreference,
    required this.onAddFiles,
    required this.onPasteTable,
    required this.onCancel,
    required this.onExport,
    required this.onOpenLogs,
    required this.onAbout,
    required this.aboutFocusNode,
    required this.onThemeChanged,
  });

  final ConversionTask? selectedTask;
  final AppThemePreference themePreference;
  final VoidCallback onAddFiles;
  final VoidCallback onPasteTable;
  final VoidCallback onCancel;
  final VoidCallback onExport;
  final VoidCallback onOpenLogs;
  final VoidCallback onAbout;
  final FocusNode aboutFocusNode;
  final ValueChanged<AppThemePreference> onThemeChanged;

  @override
  Widget build(BuildContext context) {
    final selected = selectedTask;
    final converting =
        selected?.status == ConversionStatus.converting ||
        selected?.status == ConversionStatus.inspecting;
    final exportable = selected?.status == ConversionStatus.ready;
    return SizedBox(
      height: 54,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            FilledButton.icon(
              onPressed: onAddFiles,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加文件'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: onPasteTable,
              icon: const Icon(Icons.table_chart_outlined, size: 18),
              label: const Text('粘贴表格'),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: converting ? onCancel : null,
              tooltip: '取消转换',
              icon: const Icon(Icons.stop_circle_outlined),
            ),
            IconButton(
              onPressed: exportable ? onExport : null,
              tooltip: '导出 Markdown',
              icon: const Icon(Icons.save_alt),
            ),
            const Spacer(),
            IconButton(
              onPressed: onOpenLogs,
              tooltip: '打开日志目录',
              icon: const Icon(Icons.folder_open_outlined),
            ),
            PopupMenuButton<AppThemePreference>(
              tooltip: '主题',
              initialValue: themePreference,
              onSelected: onThemeChanged,
              icon: const Icon(Icons.brightness_6_outlined),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: AppThemePreference.system,
                  child: Text('跟随系统'),
                ),
                PopupMenuItem(
                  value: AppThemePreference.light,
                  child: Text('浅色'),
                ),
                PopupMenuItem(
                  value: AppThemePreference.dark,
                  child: Text('深色'),
                ),
              ],
            ),
            Tooltip(
              message: '关于 Any2MD',
              excludeFromSemantics: true,
              child: TextButton.icon(
                onPressed: onAbout,
                focusNode: aboutFocusNode,
                icon: const Icon(Icons.info_outline, size: 18),
                label: const Text('关于', semanticsLabel: '关于 Any2MD'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskSidebar extends StatelessWidget {
  const _TaskSidebar({
    required this.state,
    required this.onSelect,
    required this.onRemove,
    required this.onRename,
  });

  final WorkspaceState state;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onRemove;
  final ValueChanged<String> onRename;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Text('转换任务', style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(
            child: state.tasks.isEmpty
                ? const _SidebarEmptyState()
                : ListView.builder(
                    itemCount: state.tasks.length,
                    itemBuilder: (context, index) {
                      final task = state.tasks[index];
                      final selected = task.id == state.selectedTaskId;
                      return Material(
                        color: selected
                            ? colors.secondaryContainer.withValues(alpha: 0.55)
                            : Colors.transparent,
                        child: InkWell(
                          onTap: () => onSelect(task.id),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                            child: Row(
                              children: [
                                _TaskStatusIcon(task: task),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        task.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              fontWeight: selected
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                            ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _statusLabel(task),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (task.isPastedTable)
                                  PopupMenuButton<_PastedTableTaskAction>(
                                    tooltip: '更多任务操作',
                                    icon: const Icon(Icons.more_vert),
                                    onSelected: (action) {
                                      switch (action) {
                                        case _PastedTableTaskAction.rename:
                                          onRename(task.id);
                                      }
                                    },
                                    itemBuilder: (context) => const [
                                      PopupMenuItem(
                                        value: _PastedTableTaskAction.rename,
                                        child: Text('重命名'),
                                      ),
                                    ],
                                  ),
                                IconButton(
                                  onPressed: () => onRemove(task.id),
                                  tooltip: '移除任务',
                                  iconSize: 18,
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

enum _PastedTableTaskAction { rename }

class _RenamePastedTableDialog extends StatefulWidget {
  const _RenamePastedTableDialog({
    required this.initialName,
    required this.onRename,
  });

  final String initialName;
  final Future<PastedTableRenameResult> Function(String name) onRename;

  @override
  State<_RenamePastedTableDialog> createState() =>
      _RenamePastedTableDialogState();
}

class _RenamePastedTableDialogState extends State<_RenamePastedTableDialog> {
  late final TextEditingController _nameController;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名任务'),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _nameController,
          autofocus: true,
          enabled: !_saving,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(labelText: '任务名称', errorText: _error),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _save(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.onRename(_nameController.text);
      if (!mounted) return;
      if (result == PastedTableRenameResult.renamed) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _saving = false;
        _error = switch (result) {
          PastedTableRenameResult.taskNotFound => '任务不存在或不支持重命名',
          PastedTableRenameResult.emptyName => '任务名称不能为空',
          PastedTableRenameResult.reservedName => '请为任务输入一个唯一名称',
          PastedTableRenameResult.duplicateName => '已有同名粘贴表格任务',
          PastedTableRenameResult.renamed => null,
        };
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败，请重试';
      });
    }
  }
}

class _SidebarEmptyState extends StatelessWidget {
  const _SidebarEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '拖入文件后，转换任务会显示在这里',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _TaskStatusIcon extends StatelessWidget {
  const _TaskStatusIcon({required this.task});

  final ConversionTask task;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (task.isPastedTable) {
      return Icon(
        Icons.table_chart_outlined,
        size: 20,
        color: task.isDirty ? colors.secondary : colors.primary,
      );
    }
    return switch (task.status) {
      ConversionStatus.inspectionQueued => Icon(
        Icons.table_view_outlined,
        size: 19,
        color: colors.onSurfaceVariant,
      ),
      ConversionStatus.inspecting => const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      ConversionStatus.awaitingSheetSelection => Icon(
        Icons.checklist_outlined,
        size: 20,
        color: colors.secondary,
      ),
      ConversionStatus.queued => Icon(
        Icons.schedule,
        size: 19,
        color: colors.onSurfaceVariant,
      ),
      ConversionStatus.converting => const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      ConversionStatus.ready => Icon(
        task.isDirty ? Icons.edit_note : Icons.check_circle_outline,
        size: 20,
        color: task.isDirty ? colors.secondary : colors.primary,
      ),
      ConversionStatus.failed => Icon(
        Icons.error_outline,
        size: 20,
        color: colors.error,
      ),
      ConversionStatus.cancelled => Icon(
        Icons.block,
        size: 19,
        color: colors.onSurfaceVariant,
      ),
    };
  }
}

class _DocumentWorkspace extends StatefulWidget {
  const _DocumentWorkspace({
    required this.task,
    required this.onMarkdownChanged,
    required this.onFlush,
    required this.onRetry,
    required this.onSheetSelectionChanged,
    required this.onConfirmSheetSelection,
    required this.onEditTableSource,
  });

  final ConversionTask? task;
  final void Function(String id, String markdown) onMarkdownChanged;
  final Future<void> Function() onFlush;
  final ValueChanged<String> onRetry;
  final Future<void> Function(String id, Iterable<String> names)
  onSheetSelectionChanged;
  final Future<void> Function(String id, Iterable<String> names)
  onConfirmSheetSelection;
  final ValueChanged<ConversionTask> onEditTableSource;

  @override
  State<_DocumentWorkspace> createState() => _DocumentWorkspaceState();
}

class _DocumentWorkspaceState extends State<_DocumentWorkspace> {
  EditorMode _mode = EditorMode.edit;
  bool _reselectingSheets = false;

  @override
  void didUpdateWidget(covariant _DocumentWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task?.id != widget.task?.id ||
        widget.task?.status != ConversionStatus.ready) {
      _reselectingSheets = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    if (task == null) return const _WorkspaceEmptyState();
    if (task.status == ConversionStatus.inspectionQueued ||
        task.status == ConversionStatus.inspecting ||
        task.status == ConversionStatus.queued ||
        task.status == ConversionStatus.converting) {
      return _BusyState(task: task);
    }
    if (task.status == ConversionStatus.awaitingSheetSelection ||
        _reselectingSheets) {
      return _WorkbookSheetSelector(
        key: ValueKey('${task.id}-${_reselectingSheets ? 'reselect' : 'new'}'),
        task: task,
        allowCancel: _reselectingSheets,
        onCancel: () => setState(() => _reselectingSheets = false),
        onSelectionChanged:
            task.status == ConversionStatus.awaitingSheetSelection
            ? (names) => widget.onSheetSelectionChanged(task.id, names)
            : null,
        onConvert: (names) => _convertSelectedSheets(task, names),
      );
    }
    if (task.status == ConversionStatus.failed ||
        task.status == ConversionStatus.cancelled) {
      return _FailureState(task: task, onRetry: widget.onRetry);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DocumentHeader(
          task: task,
          onEditTableSource: task.isPastedTable
              ? () => widget.onEditTableSource(task)
              : null,
          onReselectSheets: task.inputType == 'xlsx'
              ? () => setState(() => _reselectingSheets = true)
              : null,
        ),
        if (task.warnings.isNotEmpty) _WarningBanner(warnings: task.warnings),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<EditorMode>(
              segments: const [
                ButtonSegment(
                  value: EditorMode.edit,
                  icon: Icon(Icons.edit_outlined, size: 17),
                  label: Text('编辑'),
                ),
                ButtonSegment(
                  value: EditorMode.preview,
                  icon: Icon(Icons.visibility_outlined, size: 17),
                  label: Text('预览'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) {
                unawaited(_changeMode(selection.first));
              },
              showSelectedIcon: false,
            ),
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(
          child: _mode == EditorMode.edit
              ? _MarkdownEditor(
                  key: ValueKey(task.id),
                  markdown: task.markdown,
                  onChanged: (markdown) =>
                      widget.onMarkdownChanged(task.id, markdown),
                )
              : _MarkdownPreview(
                  taskId: task.id,
                  revision: task.revision,
                  markdown: task.markdown,
                  isPastedTable: task.isPastedTable,
                ),
        ),
      ],
    );
  }

  Future<void> _changeMode(EditorMode mode) async {
    await widget.onFlush();
    if (mounted) setState(() => _mode = mode);
  }

  Future<void> _convertSelectedSheets(
    ConversionTask task,
    Set<String> names,
  ) async {
    if (task.hasManualEdits) {
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重新转换工作表？'),
          content: const Text('当前 Markdown 包含手动编辑，重新转换后这些修改会被覆盖。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('重新转换'),
            ),
          ],
        ),
      );
      if (overwrite != true) return;
    }
    await widget.onConfirmSheetSelection(task.id, names);
    if (mounted) setState(() => _reselectingSheets = false);
  }
}

class _DocumentHeader extends StatelessWidget {
  const _DocumentHeader({
    required this.task,
    this.onReselectSheets,
    this.onEditTableSource,
  });

  final ConversionTask task;
  final VoidCallback? onReselectSheets;
  final VoidCallback? onEditTableSource;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              task.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (onReselectSheets != null) ...[
            TextButton.icon(
              onPressed: onReselectSheets,
              icon: const Icon(Icons.table_view_outlined, size: 17),
              label: Text('${task.selectedSheetNames.length} 个工作表'),
            ),
            const SizedBox(width: 8),
          ],
          if (onEditTableSource != null) ...[
            TextButton.icon(
              onPressed: onEditTableSource,
              icon: const Icon(Icons.edit_note, size: 17),
              label: const Text('编辑源数据'),
            ),
            const SizedBox(width: 8),
          ],
          if (task.isDirty)
            Text(
              '未导出',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.secondary,
              ),
            ),
        ],
      ),
    );
  }
}

class _WorkbookSheetSelector extends StatefulWidget {
  const _WorkbookSheetSelector({
    super.key,
    required this.task,
    required this.allowCancel,
    required this.onCancel,
    required this.onConvert,
    this.onSelectionChanged,
  });

  final ConversionTask task;
  final bool allowCancel;
  final VoidCallback onCancel;
  final ValueChanged<Set<String>>? onSelectionChanged;
  final Future<void> Function(Set<String> names) onConvert;

  @override
  State<_WorkbookSheetSelector> createState() => _WorkbookSheetSelectorState();
}

class _WorkbookSheetSelectorState extends State<_WorkbookSheetSelector> {
  final _searchController = TextEditingController();
  late final Set<String> _selectedNames;
  String _query = '';
  String? _previewSheetName;
  bool _showHidden = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _selectedNames = widget.task.selectedSheetNames.toSet();
    _previewSheetName = widget.task.workbookSheets
        .where((sheet) => _selectedNames.contains(sheet.name))
        .firstOrNull
        ?.name;
    _previewSheetName ??= widget.task.workbookSheets
        .where((sheet) => sheet.isSelectable)
        .firstOrNull
        ?.name;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sheets = widget.task.workbookSheets;
    final filtered = _filteredSheets(_query, _showHidden);
    final previewSheet = sheets
        .where((sheet) => sheet.name == _previewSheetName)
        .firstOrNull;
    final selectableCount = sheets.where((sheet) => sheet.isSelectable).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          color: Theme.of(context).colorScheme.surface,
          child: Row(
            children: [
              Icon(
                Icons.table_chart_outlined,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.task.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${sheets.length} 个工作表 · 已选 ${_selectedNames.length}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.allowCancel)
                TextButton(onPressed: widget.onCancel, child: const Text('取消')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _selectedNames.isEmpty || _submitting
                    ? null
                    : _submit,
                icon: _submitting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow, size: 18),
                label: Text('转换所选 (${_selectedNames.length})'),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 700;
              final search = SizedBox(
                height: 34,
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: '搜索工作表',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    border: const OutlineInputBorder(
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: const OutlineInputBorder(
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onChanged: _updateQuery,
                ),
              );
              return Row(
                children: [
                  if (compact)
                    Expanded(child: search)
                  else
                    SizedBox(width: 260, child: search),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: _selectVisibleSheets,
                    tooltip: '全选可见非空工作表',
                    icon: const Icon(Icons.select_all, size: 20),
                  ),
                  IconButton(
                    onPressed: _selectedNames.isEmpty ? null : _clearSelection,
                    tooltip: '取消全选',
                    icon: const Icon(Icons.deselect, size: 20),
                  ),
                  const Spacer(),
                  if (compact)
                    IconButton(
                      onPressed: () => _updateShowHidden(!_showHidden),
                      tooltip: _showHidden ? '隐藏不可见工作表' : '显示隐藏工作表',
                      isSelected: _showHidden,
                      icon: const Icon(Icons.visibility_off_outlined, size: 19),
                      selectedIcon: const Icon(
                        Icons.visibility_outlined,
                        size: 19,
                      ),
                    )
                  else
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.visibility_off_outlined,
                          size: 18,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 7),
                        const Text('显示隐藏工作表'),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 42,
                          height: 28,
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: Switch(
                              value: _showHidden,
                              onChanged: _updateShowHidden,
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
        if (selectableCount == 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Text(
              '工作簿中没有可转换的数据。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final list = _SheetList(
                sheets: filtered,
                selectedNames: _selectedNames,
                previewSheetName: _previewSheetName,
                onToggle: _toggleSheet,
                onPreview: (name) => setState(() => _previewSheetName = name),
              );
              final preview = _SheetPreview(sheet: previewSheet);
              if (constraints.maxWidth >= 760) {
                return Row(
                  children: [
                    SizedBox(width: 316, child: list),
                    VerticalDivider(
                      width: 1,
                      color: Theme.of(context).dividerColor,
                    ),
                    Expanded(child: preview),
                  ],
                );
              }
              return Column(
                children: [
                  SizedBox(height: 230, child: list),
                  Divider(height: 1, color: Theme.of(context).dividerColor),
                  Expanded(child: preview),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  void _toggleSheet(WorkbookSheetInfo sheet, bool selected) {
    if (!sheet.isSelectable) return;
    setState(() {
      if (selected) {
        _selectedNames.add(sheet.name);
      } else {
        _selectedNames.remove(sheet.name);
      }
      _previewSheetName = sheet.name;
    });
    widget.onSelectionChanged?.call(Set.unmodifiable(_selectedNames));
  }

  void _selectVisibleSheets() {
    setState(() {
      _selectedNames
        ..clear()
        ..addAll(
          widget.task.workbookSheets
              .where((sheet) => sheet.isVisible && sheet.isSelectable)
              .map((sheet) => sheet.name),
        );
    });
    widget.onSelectionChanged?.call(Set.unmodifiable(_selectedNames));
  }

  void _clearSelection() {
    setState(_selectedNames.clear);
    widget.onSelectionChanged?.call(const {});
  }

  void _updateQuery(String value) {
    setState(() {
      _query = value;
      _keepPreviewIn(_filteredSheets(value, _showHidden));
    });
  }

  void _updateShowHidden(bool value) {
    setState(() {
      _showHidden = value;
      _keepPreviewIn(_filteredSheets(_query, value));
    });
  }

  List<WorkbookSheetInfo> _filteredSheets(String query, bool showHidden) {
    final normalizedQuery = query.trim().toLowerCase();
    return widget.task.workbookSheets
        .where(
          (sheet) =>
              (showHidden || sheet.isVisible) &&
              (normalizedQuery.isEmpty ||
                  sheet.name.toLowerCase().contains(normalizedQuery)),
        )
        .toList(growable: false);
  }

  void _keepPreviewIn(List<WorkbookSheetInfo> visibleSheets) {
    if (!visibleSheets.any((sheet) => sheet.name == _previewSheetName)) {
      _previewSheetName = visibleSheets.firstOrNull?.name;
    }
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      await widget.onConvert(Set.unmodifiable(_selectedNames));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _SheetList extends StatelessWidget {
  const _SheetList({
    required this.sheets,
    required this.selectedNames,
    required this.previewSheetName,
    required this.onToggle,
    required this.onPreview,
  });

  final List<WorkbookSheetInfo> sheets;
  final Set<String> selectedNames;
  final String? previewSheetName;
  final void Function(WorkbookSheetInfo sheet, bool selected) onToggle;
  final ValueChanged<String> onPreview;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.centerLeft,
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            child: Text(
              '工作表',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          Expanded(
            child: sheets.isEmpty
                ? Center(
                    child: Text(
                      '没有匹配的工作表',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: sheets.length,
                    itemBuilder: (context, index) {
                      final sheet = sheets[index];
                      final selected = selectedNames.contains(sheet.name);
                      final previewing = previewSheetName == sheet.name;
                      return Material(
                        color: previewing
                            ? Theme.of(context).colorScheme.surfaceContainerHigh
                            : Colors.transparent,
                        child: InkWell(
                          onTap: () => onPreview(sheet.name),
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  width: 3,
                                  color: previewing
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.transparent,
                                ),
                              ),
                            ),
                            padding: const EdgeInsets.fromLTRB(5, 6, 12, 6),
                            child: Row(
                              children: [
                                Checkbox(
                                  key: ValueKey(
                                    'sheet-checkbox-${sheet.index}',
                                  ),
                                  value: selected,
                                  visualDensity: VisualDensity.compact,
                                  onChanged: sheet.isSelectable
                                      ? (value) =>
                                            onToggle(sheet, value ?? false)
                                      : null,
                                ),
                                const SizedBox(width: 2),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        sheet.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        _sheetMetadataLabel(sheet),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (!sheet.isVisible)
                                  Icon(
                                    Icons.visibility_off_outlined,
                                    size: 17,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SheetPreview extends StatefulWidget {
  const _SheetPreview({required this.sheet});

  final WorkbookSheetInfo? sheet;

  @override
  State<_SheetPreview> createState() => _SheetPreviewState();
}

class _SheetPreviewState extends State<_SheetPreview> {
  static const _scrollbarGutter = 16.0;

  final _horizontalScrollController = ScrollController();
  final _verticalScrollController = ScrollController();

  @override
  void didUpdateWidget(covariant _SheetPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sheet?.name != widget.sheet?.name) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_horizontalScrollController.hasClients) {
          _horizontalScrollController.jumpTo(0);
        }
        if (_verticalScrollController.hasClients) {
          _verticalScrollController.jumpTo(0);
        }
      });
    }
  }

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheet;
    if (sheet == null) {
      return const Center(child: Text('选择工作表以查看预览'));
    }
    if (sheet.preview.isEmpty) {
      return Center(child: Text(sheet.isEmpty ? '空工作表' : '没有可预览的数据'));
    }
    final columnCount = sheet.preview
        .map((row) => row.length)
        .fold<int>(0, (maximum, length) => math.max(maximum, length));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          child: Row(
            children: [
              Icon(
                Icons.grid_on_outlined,
                size: 17,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sheet.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              Text(
                '${sheet.rowCount} 行 × ${sheet.columnCount} 列',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: ScrollbarTheme(
              data: ScrollbarTheme.of(context).copyWith(
                thickness: WidgetStateProperty.resolveWith(
                  (states) =>
                      states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.dragged)
                      ? 12
                      : 10,
                ),
                trackVisibility: WidgetStateProperty.resolveWith(
                  (states) =>
                      states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.dragged),
                ),
                minThumbLength: 48,
                crossAxisMargin: 2,
                radius: const Radius.circular(6),
              ),
              child: Scrollbar(
                controller: _verticalScrollController,
                thumbVisibility: true,
                interactive: true,
                scrollbarOrientation: ScrollbarOrientation.right,
                notificationPredicate: (notification) =>
                    notification.metrics.axis == Axis.vertical,
                child: Scrollbar(
                  controller: _horizontalScrollController,
                  thumbVisibility: true,
                  interactive: true,
                  scrollbarOrientation: ScrollbarOrientation.bottom,
                  notificationPredicate: (notification) =>
                      notification.metrics.axis == Axis.horizontal,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      right: _scrollbarGutter,
                      bottom: _scrollbarGutter,
                    ),
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(scrollbars: false),
                      child: SingleChildScrollView(
                        controller: _horizontalScrollController,
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.all(16),
                        child: SingleChildScrollView(
                          controller: _verticalScrollController,
                          child: _SheetPreviewGrid(
                            preview: sheet.preview,
                            columnCount: columnCount,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetPreviewGrid extends StatelessWidget {
  const _SheetPreviewGrid({required this.preview, required this.columnCount});

  static const _rowHeaderWidth = 42.0;
  static const _columnWidth = 148.0;
  static const _headerHeight = 32.0;
  static const _rowHeight = 42.0;

  final List<List<String?>> preview;
  final int columnCount;

  @override
  Widget build(BuildContext context) {
    final borderColor = Theme.of(context).dividerColor;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: borderColor),
          left: BorderSide(color: borderColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SheetGridCell(
                width: _rowHeaderWidth,
                height: _headerHeight,
                text: '',
                header: true,
              ),
              for (var index = 0; index < columnCount; index++)
                _SheetGridCell(
                  width: _columnWidth,
                  height: _headerHeight,
                  text: _spreadsheetColumnName(index),
                  header: true,
                ),
            ],
          ),
          for (var rowIndex = 0; rowIndex < preview.length; rowIndex++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SheetGridCell(
                    width: _rowHeaderWidth,
                    height: _rowHeight,
                    text: '${rowIndex + 1}',
                    header: true,
                  ),
                  for (
                    var columnIndex = 0;
                    columnIndex < columnCount;
                    columnIndex++
                  )
                    _SheetGridCell(
                      width: _columnWidth,
                      height: _rowHeight,
                      text: columnIndex < preview[rowIndex].length
                          ? preview[rowIndex][columnIndex] ?? ''
                          : '',
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SheetGridCell extends StatelessWidget {
  const _SheetGridCell({
    required this.width,
    required this.height,
    required this.text,
    this.header = false,
  });

  final double width;
  final double height;
  final String text;
  final bool header;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      constraints: BoxConstraints(minHeight: height),
      padding: EdgeInsets.symmetric(horizontal: header ? 6 : 10, vertical: 6),
      alignment: header ? Alignment.center : Alignment.centerLeft,
      decoration: BoxDecoration(
        color: header
            ? Theme.of(context).colorScheme.surfaceContainerLow
            : Theme.of(context).colorScheme.surface,
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Text(
        text,
        maxLines: header ? 1 : null,
        overflow: header ? TextOverflow.ellipsis : TextOverflow.clip,
        style: header
            ? Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              )
            : Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

String _sheetMetadataLabel(WorkbookSheetInfo sheet) {
  if (sheet.isEmpty) return '空工作表';
  final visibility = switch (sheet.visibility) {
    SheetVisibility.visible => '',
    SheetVisibility.hidden => ' · 已隐藏',
    SheetVisibility.veryHidden => ' · 深度隐藏',
  };
  return '${sheet.rowCount} 行 × ${sheet.columnCount} 列$visibility';
}

String _spreadsheetColumnName(int zeroBasedIndex) {
  var value = zeroBasedIndex + 1;
  final characters = <int>[];
  while (value > 0) {
    value--;
    characters.add(65 + value % 26);
    value ~/= 26;
  }
  return String.fromCharCodes(characters.reversed);
}

class _MarkdownEditor extends StatefulWidget {
  const _MarkdownEditor({
    super.key,
    required this.markdown,
    required this.onChanged,
  });

  final String markdown;
  final ValueChanged<String> onChanged;

  @override
  State<_MarkdownEditor> createState() => _MarkdownEditorState();
}

class _MarkdownEditorState extends State<_MarkdownEditor> {
  static const _scrollbarGutterWidth = 16.0;

  late final TextEditingController _controller;
  final _searchController = TextEditingController();
  final _undoController = UndoHistoryController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  bool _showSearch = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.markdown);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    _undoController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: {
        SingleActivator(
          LogicalKeyboardKey.keyF,
          control: Platform.isWindows,
          meta: Platform.isMacOS,
        ): const _FindIntent(),
      },
      child: Actions(
        actions: {
          _FindIntent: CallbackAction<_FindIntent>(
            onInvoke: (_) {
              setState(() => _showSearch = true);
              return null;
            },
          ),
        },
        child: Column(
          children: [
            Container(
              height: 43,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Row(
                children: [
                  ValueListenableBuilder<UndoHistoryValue>(
                    valueListenable: _undoController,
                    builder: (context, value, _) => Row(
                      children: [
                        IconButton(
                          onPressed: value.canUndo ? _undo : null,
                          tooltip: '撤销',
                          iconSize: 19,
                          icon: const Icon(Icons.undo),
                        ),
                        IconButton(
                          onPressed: value.canRedo ? _redo : null,
                          tooltip: '重做',
                          iconSize: 19,
                          icon: const Icon(Icons.redo),
                        ),
                        IconButton(
                          onPressed: _copyAll,
                          tooltip: '复制全部 Markdown',
                          iconSize: 19,
                          icon: const Icon(Icons.copy_all_outlined),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (_showSearch) ...[
                    SizedBox(
                      width: 220,
                      child: TextField(
                        controller: _searchController,
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText: '查找',
                          prefixIcon: Icon(Icons.search, size: 18),
                          contentPadding: EdgeInsets.symmetric(vertical: 8),
                        ),
                        onSubmitted: (_) => _findNext(),
                      ),
                    ),
                    IconButton(
                      onPressed: _findNext,
                      tooltip: '下一个匹配项',
                      iconSize: 19,
                      icon: const Icon(Icons.keyboard_arrow_down),
                    ),
                    IconButton(
                      onPressed: _closeSearch,
                      tooltip: '关闭查找',
                      iconSize: 18,
                      icon: const Icon(Icons.close),
                    ),
                  ] else
                    IconButton(
                      onPressed: () => setState(() => _showSearch = true),
                      tooltip: '查找',
                      iconSize: 19,
                      icon: const Icon(Icons.search),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ScrollbarTheme(
                data: ScrollbarTheme.of(context).copyWith(
                  thickness: WidgetStateProperty.resolveWith(
                    (states) =>
                        states.contains(WidgetState.hovered) ||
                            states.contains(WidgetState.dragged)
                        ? 12
                        : 10,
                  ),
                  trackVisibility: WidgetStateProperty.resolveWith(
                    (states) =>
                        states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.dragged),
                  ),
                  minThumbLength: 48,
                  crossAxisMargin: 2,
                  radius: const Radius.circular(6),
                ),
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  interactive: true,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      right: _scrollbarGutterWidth,
                    ),
                    child: ScrollConfiguration(
                      behavior: const _EditorScrollBehavior(),
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (_) => _focusNode.requestFocus(),
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          undoController: _undoController,
                          scrollController: _scrollController,
                          expands: true,
                          maxLines: null,
                          minLines: null,
                          keyboardType: TextInputType.multiline,
                          textAlignVertical: TextAlignVertical.top,
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            fontFamilyFallback: ['Menlo', 'monospace'],
                            fontSize: 14,
                            height: 1.55,
                            letterSpacing: 0,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.all(18),
                          ),
                          onChanged: widget.onChanged,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _findNext() {
    final query = _searchController.text;
    if (query.isEmpty) return;
    final text = _controller.text.toLowerCase();
    final start = _controller.selection.isValid
        ? _controller.selection.end.clamp(0, text.length)
        : 0;
    var index = text.indexOf(query.toLowerCase(), start);
    if (index < 0 && start > 0) index = text.indexOf(query.toLowerCase());
    if (index < 0) return;
    _controller.selection = TextSelection(
      baseOffset: index,
      extentOffset: index + query.length,
    );
    _focusNode.requestFocus();
  }

  void _undo() {
    _undoController.undo();
    _focusNode.requestFocus();
  }

  void _redo() {
    _undoController.redo();
    _focusNode.requestFocus();
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _controller.text));
  }

  void _closeSearch() {
    setState(() => _showSearch = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }
}

class _FindIntent extends Intent {
  const _FindIntent();
}

class _EditorScrollBehavior extends MaterialScrollBehavior {
  const _EditorScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // EditableText enables a desktop scrollbar again for multiline fields.
    return child;
  }
}

class _MarkdownPreview extends ConsumerStatefulWidget {
  const _MarkdownPreview({
    required this.taskId,
    required this.revision,
    required this.markdown,
    required this.isPastedTable,
  });

  final String taskId;
  final int revision;
  final String markdown;
  final bool isPastedTable;

  @override
  ConsumerState<_MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends ConsumerState<_MarkdownPreview> {
  final _scrollController = ScrollController();
  ParsedMarkdownDocument? _document;
  bool _fallback = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(_MarkdownPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.taskId != oldWidget.taskId ||
        widget.revision != oldWidget.revision ||
        widget.isPastedTable != oldWidget.isPastedTable ||
        widget.markdown != oldWidget.markdown) {
      _resetScrollPosition();
      _parse();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_fallback) {
      return _buildScrollablePreview(
        _LegacyMarkdownPreview(
          markdown: widget.markdown,
          controller: _scrollController,
          isPastedTable: widget.isPastedTable,
        ),
      );
    }
    final document = _document;
    if (document == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _buildScrollablePreview(
      _ParsedMarkdownView(
        document: document,
        controller: _scrollController,
        imageBuilder: _imageBuilder,
        isPastedTable: widget.isPastedTable,
      ),
    );
  }

  Widget _buildScrollablePreview(Widget child) {
    return Scrollbar(
      controller: _scrollController,
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.vertical,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: widget.isPastedTable && _fallback
            ? _PastedTablePreviewScrollFrame(
                key: ValueKey((widget.taskId, widget.revision, _fallback)),
                child: child,
              )
            : child,
      ),
    );
  }

  void _parse() {
    final request = ++_request;
    setState(() {
      _document = null;
      _fallback = false;
    });
    ref
        .read(markdownPreviewParserProvider)
        .parse(
          taskId: widget.taskId,
          revision: widget.revision,
          source: widget.markdown,
          enableTableLineBreaks: widget.isPastedTable,
        )
        .then((document) {
          if (!mounted || request != _request) return;
          setState(() => _document = document);
        })
        .catchError((Object error) {
          if (!mounted || request != _request) return;
          unawaited(
            ref
                .read(appLoggerProvider)
                .write(
                  'Markdown preview parse failed task=${widget.taskId} '
                  'revision=${widget.revision} error=${error.runtimeType}',
                ),
          );
          setState(() => _fallback = true);
        });
  }

  void _resetScrollPosition() {
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  Widget _imageBuilder(Uri uri, String? title, String? alt) {
    return Container(
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_not_supported_outlined),
          const SizedBox(width: 10),
          Flexible(child: Text(alt?.isNotEmpty == true ? alt! : '图片未加载')),
        ],
      ),
    );
  }
}

/// Keep the table's horizontal control at the viewport edge, even when the
/// bottom of a long table is far below the visible portion of the document.
class _PastedTablePreviewScrollFrame extends StatefulWidget {
  const _PastedTablePreviewScrollFrame({
    super.key,
    required this.child,
    this.controller,
  });

  final Widget child;
  final ScrollController? controller;

  @override
  State<_PastedTablePreviewScrollFrame> createState() =>
      _PastedTablePreviewScrollFrameState();
}

class _PastedTablePreviewScrollFrameState
    extends State<_PastedTablePreviewScrollFrame> {
  // Borrow the table's existing controller; its owner retains disposal. This
  // avoids another scroll view or rebuilding the parsed Markdown on scrolling.
  ScrollController? _observedController;

  ScrollController? get _horizontalController =>
      widget.controller ?? _observedController;

  void _observeHorizontalScroll(BuildContext? notificationContext, Axis axis) {
    if (widget.controller != null) return;
    if (axis != Axis.horizontal || notificationContext == null) return;
    final controller = Scrollable.maybeOf(
      notificationContext,
      axis: Axis.horizontal,
    )?.widget.controller;
    if (controller == null || identical(controller, _horizontalController)) {
      return;
    }
    setState(() => _observedController = controller);
    // The first metrics notification arrived before the pinned scrollbar was
    // attached to this controller. Replay it after rebuilding so its painter
    // and drag hit area are initialized without requiring a first scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !notificationContext.mounted ||
          !identical(controller, _horizontalController) ||
          !controller.hasClients) {
        return;
      }
      ScrollMetricsNotification(
        metrics: controller.position.copyWith(),
        context: notificationContext,
      ).dispatch(notificationContext);
    });
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        _observeHorizontalScroll(
          notification.context,
          notification.metrics.axis,
        );
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          _observeHorizontalScroll(
            notification.context,
            notification.metrics.axis,
          );
          return false;
        },
        child: Scrollbar(
          key: const ValueKey('pasted-table-preview-horizontal-scrollbar'),
          controller: _horizontalController,
          thumbVisibility: _horizontalController != null,
          interactive: _horizontalController != null,
          thickness: 10,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          notificationPredicate: (notification) =>
              notification.metrics.axis == Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: ScrollbarTheme(
              data: ScrollbarTheme.of(context).copyWith(
                thickness: const WidgetStatePropertyAll(0),
                interactive: false,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class _ParsedMarkdownView extends StatefulWidget {
  const _ParsedMarkdownView({
    required this.document,
    required this.controller,
    required this.imageBuilder,
    required this.isPastedTable,
  });

  final ParsedMarkdownDocument document;
  final ScrollController controller;
  final MarkdownImageBuilder imageBuilder;
  final bool isPastedTable;

  @override
  State<_ParsedMarkdownView> createState() => _ParsedMarkdownViewState();
}

class _ParsedMarkdownViewState extends State<_ParsedMarkdownView>
    implements MarkdownBuilderDelegate {
  static const _padding = EdgeInsets.fromLTRB(28, 22, 28, 48);
  static const _eagerSourceLimit = 256 * 1024;
  static const _eagerNodeLimit = 1000;
  // Even-sized groups preserve the table's alternating row decorations.
  static const _tableRowsPerBlock = 2;
  static const _tableColumnWidth = 180.0;

  final _horizontalController = ScrollController();
  final List<GestureRecognizer> _recognizers = [];
  List<Widget> _children = const [];
  List<GlobalKey> _measurementKeys = const [];
  List<double>? _itemExtents;
  List<md.Node> _nodes = const [];
  final Set<int> _tableContinuations = {};
  double _tableWidth = 0;
  late MarkdownStyleSheet _styleSheet;
  bool _ready = false;
  int _layoutGeneration = 0;

  bool get _useEagerLayout =>
      !widget.isPastedTable &&
      widget.document.sourceLength <= _eagerSourceLimit &&
      widget.document.nodes.length <= _eagerNodeLimit;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _buildChildren();
  }

  @override
  void didUpdateWidget(_ParsedMarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.document.key != oldWidget.document.key ||
        !identical(widget.document.nodes, oldWidget.document.nodes) ||
        widget.imageBuilder != oldWidget.imageBuilder) {
      _buildChildren();
    }
  }

  @override
  void dispose() {
    _horizontalController.dispose();
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget verticalScrollable;
    if (_useEagerLayout) {
      verticalScrollable = SingleChildScrollView(
        controller: widget.controller,
        padding: _padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _children,
        ),
      );
    } else if (_itemExtents == null) {
      verticalScrollable = SingleChildScrollView(
        controller: widget.controller,
        padding: _padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < _children.length; index++)
              SizedBox(key: _measurementKeys[index], child: _children[index]),
          ],
        ),
      );
    } else {
      verticalScrollable = CustomScrollView(
        controller: widget.controller,
        scrollCacheExtent: ScrollCacheExtent.viewport(
          widget.isPastedTable ? 0 : 0.5,
        ),
        slivers: [
          SliverPadding(
            padding: _padding,
            sliver: _MeasuredExtentSliver(
              itemExtents: _itemExtents!,
              delegate: SliverChildBuilderDelegate(
                (context, index) => _children[index],
                childCount: _children.length,
                addAutomaticKeepAlives: false,
              ),
            ),
          ),
        ],
      );
    }

    final scrollable = widget.isPastedTable
        ? _PastedTablePreviewScrollFrame(
            controller: _horizontalController,
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                controller: _horizontalController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(
                    constraints.maxWidth,
                    _tableWidth + _padding.horizontal,
                  ),
                  child: verticalScrollable,
                ),
              ),
            ),
          )
        : verticalScrollable;

    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          ignoring: !_ready,
          child: Opacity(
            opacity: _ready ? 1 : 0,
            child: SelectionArea(child: scrollable),
          ),
        ),
        if (!_ready) const Center(child: CircularProgressIndicator()),
      ],
    );
  }

  void _buildChildren() {
    _disposeRecognizers();
    _prepareNodes();
    final baseStyleSheet = MarkdownStyleSheet.fromTheme(
      Theme.of(context),
    ).copyWith(textScaler: MediaQuery.textScalerOf(context));
    _styleSheet = widget.isPastedTable
        ? baseStyleSheet.copyWith(
            tableColumnWidth: const _PastedTableColumnWidth(_tableColumnWidth),
          )
        : baseStyleSheet;
    _children = _useEagerLayout
        ? List.unmodifiable(_createMarkdownBuilder().build(_nodes))
        : List.unmodifiable(
            List<Widget>.generate(_nodes.length, _buildMarkdownBlock),
          );
    _itemExtents = null;
    _measurementKeys = _useEagerLayout
        ? const []
        : List<GlobalKey>.generate(_children.length, (_) => GlobalKey());
    _ready = false;
    _scheduleReadyAfterLayout();
  }

  void _scheduleReadyAfterLayout() {
    final generation = ++_layoutGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _layoutGeneration) return;
      if (!widget.controller.hasClients ||
          !widget.controller.position.hasContentDimensions) {
        _scheduleReadyAfterLayout();
        return;
      }
      if (!_useEagerLayout && _itemExtents == null) {
        final extents = <double>[];
        for (final key in _measurementKeys) {
          final height = key.currentContext?.size?.height;
          if (height == null) {
            _scheduleReadyAfterLayout();
            return;
          }
          extents.add(height);
        }
        setState(() {
          _itemExtents = List.unmodifiable(extents);
          _measurementKeys = const [];
        });
        _scheduleReadyAfterLayout();
        return;
      }
      setState(() => _ready = true);
    });
  }

  void _prepareNodes() {
    _tableContinuations.clear();
    _tableWidth = 0;
    if (!widget.isPastedTable) {
      _nodes = widget.document.nodes;
      return;
    }
    final nodes = <md.Node>[];
    for (final node in widget.document.nodes) {
      if (node is! md.Element || node.tag != 'table') {
        nodes.add(node);
        continue;
      }
      final rows = <md.Element>[
        for (final section in node.children ?? <md.Node>[])
          if (section is md.Element)
            if (section.tag == 'tr')
              section
            else
              ...?section.children?.whereType<md.Element>().where(
                (child) => child.tag == 'tr',
              ),
      ];
      for (final row in rows) {
        _tableWidth = math.max(
          _tableWidth,
          (row.children?.length ?? 0) * _tableColumnWidth,
        );
      }
      for (var start = 0; start < rows.length; start += _tableRowsPerBlock) {
        if (start > 0) _tableContinuations.add(nodes.length);
        nodes.add(
          md.Element('table', [
            md.Element(
              'tbody',
              rows.sublist(
                start,
                math.min(start + _tableRowsPerBlock, rows.length),
              ),
            ),
          ])..attributes.addAll(node.attributes),
        );
      }
    }
    _nodes = nodes;
  }

  Widget _buildMarkdownBlock(int index) {
    final documentKey = widget.document.key;
    var styleSheet = _styleSheet;
    if (_tableContinuations.contains(index)) {
      final border = styleSheet.tableBorder;
      styleSheet = styleSheet.copyWith(
        // A continuation starts with a body row, so do not repeat the header
        // decoration or double the horizontal border between groups.
        tableHeadCellsDecoration:
            styleSheet.tableCellsDecoration ?? const BoxDecoration(),
        tableBorder: border == null
            ? null
            : TableBorder(
                left: border.left,
                right: border.right,
                bottom: border.bottom,
                horizontalInside: border.horizontalInside,
                verticalInside: border.verticalInside,
              ),
      );
    }
    final node = _nodes[index];
    final block = _MarkdownPreviewBlock(
      key: ValueKey(
        'markdown-preview-block-${documentKey.taskId}-${documentKey.revision}-$index',
      ),
      node: node,
      styleSheet: styleSheet,
      imageBuilder: widget.imageBuilder,
    );
    // Sliver children receive a tight viewport width. Loosen it for tables so
    // fixed columns retain their width when the window is wider than the table.
    return widget.isPastedTable && node is md.Element && node.tag == 'table'
        ? Align(alignment: AlignmentDirectional.topStart, child: block)
        : block;
  }

  MarkdownBuilder _createMarkdownBuilder() => MarkdownBuilder(
    delegate: this,
    selectable: false,
    styleSheet: _styleSheet,
    imageDirectory: null,
    imageBuilder: widget.imageBuilder,
    checkboxBuilder: null,
    bulletBuilder: null,
    builders: const <String, MarkdownElementBuilder>{},
    paddingBuilders: const <String, MarkdownPaddingBuilder>{},
    listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
    fitContent: false,
  );

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()..onTap = () {};
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) {
    return TextSpan(
      style: styleSheet.code,
      text: code.replaceFirst(RegExp(r'\n$'), ''),
    );
  }
}

// Fixed widths without per-group horizontal scroll views from MarkdownBuilder.
// The containing preview owns one shared horizontal viewport and scrollbar.
class _PastedTableColumnWidth extends TableColumnWidth {
  const _PastedTableColumnWidth(this.width);

  final double width;

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      width;

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      width;
}

class _MeasuredExtentSliver extends SliverMultiBoxAdaptorWidget {
  const _MeasuredExtentSliver({
    required super.delegate,
    required this.itemExtents,
  });

  final List<double> itemExtents;

  @override
  RenderSliverMultiBoxAdaptor createRenderObject(BuildContext context) {
    return _RenderMeasuredExtentSliver(
      childManager: context as SliverMultiBoxAdaptorElement,
      itemExtents: itemExtents,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasuredExtentSliver renderObject,
  ) {
    renderObject.itemExtents = itemExtents;
  }
}

class _RenderMeasuredExtentSliver extends RenderSliverVariedExtentList {
  _RenderMeasuredExtentSliver({
    required super.childManager,
    required List<double> itemExtents,
  }) : _itemExtents = itemExtents,
       _offsets = _buildOffsets(itemExtents),
       super(itemExtentBuilder: (index, dimensions) => itemExtents[index]);

  List<double> _itemExtents;
  List<double> _offsets;

  set itemExtents(List<double> value) {
    if (identical(value, _itemExtents)) return;
    _itemExtents = value;
    _offsets = _buildOffsets(value);
    itemExtentBuilder = (index, dimensions) => value[index];
  }

  @override
  double indexToLayoutOffset(double itemExtent, int index) =>
      _offsets[index.clamp(0, _itemExtents.length)];

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) {
    if (_itemExtents.isEmpty) return 0;
    return (_upperBound(_offsets, scrollOffset) - 1).clamp(
      0,
      _itemExtents.length - 1,
    );
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) {
    if (_itemExtents.isEmpty) return 0;
    return (_lowerBound(_offsets, scrollOffset) - 1).clamp(
      0,
      _itemExtents.length - 1,
    );
  }

  @override
  double estimateMaxScrollOffset(
    SliverConstraints constraints, {
    int? firstIndex,
    int? lastIndex,
    double? leadingScrollOffset,
    double? trailingScrollOffset,
  }) => _offsets.last;

  @override
  double computeMaxScrollOffset(
    SliverConstraints constraints,
    double itemExtent,
  ) => _offsets.last;

  static List<double> _buildOffsets(List<double> extents) {
    final offsets = List<double>.filled(extents.length + 1, 0);
    for (var index = 0; index < extents.length; index++) {
      offsets[index + 1] = offsets[index] + extents[index];
    }
    return offsets;
  }

  static int _lowerBound(List<double> values, double target) {
    var low = 0;
    var high = values.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (values[middle] < target) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  static int _upperBound(List<double> values, double target) {
    var low = 0;
    var high = values.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (values[middle] <= target) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }
}

class _MarkdownPreviewBlock extends StatefulWidget {
  const _MarkdownPreviewBlock({
    super.key,
    required this.node,
    required this.styleSheet,
    required this.imageBuilder,
  });

  final md.Node node;
  final MarkdownStyleSheet styleSheet;
  final MarkdownImageBuilder imageBuilder;

  @override
  State<_MarkdownPreviewBlock> createState() => _MarkdownPreviewBlockState();
}

class _MarkdownPreviewBlockState extends State<_MarkdownPreviewBlock>
    implements MarkdownBuilderDelegate {
  final List<GestureRecognizer> _recognizers = [];
  List<Widget> _children = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _buildChildren();
  }

  @override
  void didUpdateWidget(_MarkdownPreviewBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.node, oldWidget.node) ||
        widget.styleSheet != oldWidget.styleSheet ||
        widget.imageBuilder != oldWidget.imageBuilder) {
      _buildChildren();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_children.isEmpty) return const SizedBox.shrink();
    if (_children.length == 1) return _children.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: _children,
    );
  }

  void _buildChildren() {
    _disposeRecognizers();
    final builder = MarkdownBuilder(
      delegate: this,
      selectable: false,
      styleSheet: widget.styleSheet,
      imageDirectory: null,
      imageBuilder: widget.imageBuilder,
      checkboxBuilder: null,
      bulletBuilder: null,
      builders: const <String, MarkdownElementBuilder>{},
      paddingBuilders: const <String, MarkdownPaddingBuilder>{},
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
      fitContent: false,
    );
    _children = List.unmodifiable(builder.build([widget.node]));
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()..onTap = () {};
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) {
    return TextSpan(
      style: styleSheet.code,
      text: code.replaceFirst(RegExp(r'\n$'), ''),
    );
  }
}

class _LegacyMarkdownPreview extends StatelessWidget {
  const _LegacyMarkdownPreview({
    required this.markdown,
    required this.controller,
    required this.isPastedTable,
  });

  final String markdown;
  final ScrollController controller;
  final bool isPastedTable;

  @override
  Widget build(BuildContext context) {
    return Markdown(
      data: markdown,
      controller: controller,
      selectable: true,
      styleSheet: isPastedTable
          ? MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              tableColumnWidth: const FixedColumnWidth(180),
              tableScrollbarThumbVisibility: true,
            )
          : null,
      extensionSet: isPastedTable ? tableMarkdownPreviewExtensionSet() : null,
      padding: const EdgeInsets.fromLTRB(28, 22, 28, 48),
      imageBuilder: (uri, title, alt) => Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported_outlined),
            const SizedBox(width: 10),
            Flexible(child: Text(alt?.isNotEmpty == true ? alt! : '图片未加载')),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceEmptyState extends StatelessWidget {
  const _WorkspaceEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.file_open_outlined,
              size: 44,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 18),
            Text('添加或拖入办公文档', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              supportedFormatsLabel(),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BusyState extends StatelessWidget {
  const _BusyState({required this.task});

  final ConversionTask task;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 34,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 18),
          Text(switch (task.status) {
            ConversionStatus.inspectionQueued => '等待读取工作簿',
            ConversionStatus.inspecting => '正在读取工作簿',
            ConversionStatus.queued => '等待转换',
            _ => '正在转换',
          }, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(task.displayName, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _FailureState extends StatelessWidget {
  const _FailureState({required this.task, required this.onRetry});

  final ConversionTask task;
  final ValueChanged<String> onRetry;

  @override
  Widget build(BuildContext context) {
    final cancelled = task.status == ConversionStatus.cancelled;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                cancelled ? Icons.block : Icons.error_outline,
                size: 42,
                color: cancelled
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                cancelled ? '转换已取消' : _errorTitle(task.errorCode),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!cancelled && task.errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  task.errorMessage!,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: () => onRetry(task.id),
                icon: const Icon(Icons.refresh),
                label: const Text('重新转换'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final text = warnings.contains('possible_scanned_pdf')
        ? '此 PDF 可提取文本较少，可能是扫描文档；当前版本不支持 OCR。'
        : '转换结果包含需要检查的内容。';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Row(
        children: [
          const Icon(Icons.warning_amber, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.taskCount,
    required this.completedCount,
    required this.converting,
  });

  final int taskCount;
  final int completedCount;
  final bool converting;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Text(
            '$taskCount 个文件 · 完成 $completedCount',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const Spacer(),
          if (converting) ...[
            const SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 7),
            Text('转换中', style: Theme.of(context).textTheme.labelSmall),
          ] else
            Text('本地转换', style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: ColoredBox(
        color: colors.surface.withValues(alpha: 0.92),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 28),
            decoration: BoxDecoration(
              border: Border.all(color: colors.primary, width: 2),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.move_to_inbox_outlined,
                  size: 42,
                  color: colors.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  '释放文件以开始转换',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _statusLabel(ConversionTask task) => switch (task.status) {
  ConversionStatus.inspectionQueued => '等待读取工作簿',
  ConversionStatus.inspecting => '正在读取工作簿',
  ConversionStatus.awaitingSheetSelection => '待选择工作表',
  ConversionStatus.queued => '等待转换',
  ConversionStatus.converting => '正在转换',
  ConversionStatus.ready => task.isDirty ? '未导出' : '已导出',
  ConversionStatus.failed => _errorTitle(task.errorCode),
  ConversionStatus.cancelled => '已取消',
};

String _errorTitle(String? code) => switch (code) {
  'unsupported_type' => '不支持的文件格式',
  'unreadable_file' => '无法读取文件',
  'password_protected' => '文件受密码保护',
  'no_extractable_text' => '未找到可提取文本',
  'timeout' => '转换超时',
  'worker_crashed' => '转换服务不可用',
  'protocol_error' => '转换服务版本不兼容',
  'sheet_selection_invalid' => '工作表选择已失效',
  _ => '转换失败',
};
