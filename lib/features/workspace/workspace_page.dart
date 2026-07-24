import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:path/path.dart' as path;
import 'package:window_manager/window_manager.dart';

import '../../core/supported_formats.dart';
import '../../domain/conversion_task.dart';
import '../../domain/workspace_state.dart';
import '../../services/settings_service.dart';
import 'markdown_preview_parser.dart';
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
  final _splitController = MultiSplitViewController();
  bool _dragging = false;
  late final bool _windowEnabled;
  late final SettingsService _settingsService;
  Timer? _windowSaveTimer;
  Timer? _sidebarSaveTimer;

  @override
  void initState() {
    super.initState();
    _windowEnabled = ref.read(desktopWindowEnabledProvider);
    _settingsService = ref.read(settingsServiceProvider);
    _splitController.areas = [
      Area(size: 288, min: 240, max: 400),
      Area(flex: 1, min: 480),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(workspaceControllerProvider.notifier).initialize());
      unawaited(_restoreSidebarWidth());
      if (_windowEnabled) {
        windowManager.addListener(this);
        unawaited(windowManager.setPreventClose(true));
      }
    });
  }

  Future<void> _restoreSidebarWidth() async {
    final width = await _settingsService.loadSidebarWidth();
    if (!mounted) return;
    _splitController.areas[0].size = width.clamp(240, 400);
  }

  @override
  void dispose() {
    if (_windowEnabled) {
      windowManager.removeListener(this);
    }
    _splitController.dispose();
    _windowSaveTimer?.cancel();
    _sidebarSaveTimer?.cancel();
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    await ref
        .read(workspaceControllerProvider.notifier)
        .flushAllMarkdown(persistDirty: true);
    final state = ref.read(workspaceControllerProvider);
    if (state.hasUnsavedChanges) {
      final close = await _confirm(
        title: '退出 Any2MD？',
        message: '仍有未导出的 Markdown，草稿会保留并在下次启动时恢复。',
        confirmLabel: '退出',
      );
      if (!close) return;
    }
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
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
                    onCancel: _cancelSelected,
                    onExport: _exportSelected,
                    onOpenLogs: _openLogs,
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
                                    onSelect: (id) {
                                      unawaited(_selectTaskAfterFlush(id));
                                    },
                                    onRemove: _removeTask,
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

  Future<void> _selectTaskAfterFlush(String id) async {
    final controller = ref.read(workspaceControllerProvider.notifier);
    await controller.flushAllMarkdown();
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
    required this.onCancel,
    required this.onExport,
    required this.onOpenLogs,
    required this.onThemeChanged,
  });

  final VoidCallback onAddFiles;
  final VoidCallback onCancel;
  final VoidCallback onExport;
  final VoidCallback onOpenLogs;
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
      onCancel: onCancel,
      onExport: onExport,
      onOpenLogs: onOpenLogs,
      onThemeChanged: onThemeChanged,
    );
  }
}

class _TaskSidebarConsumer extends ConsumerWidget {
  const _TaskSidebarConsumer({required this.onSelect, required this.onRemove});

  final ValueChanged<String> onSelect;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workspaceControllerProvider);
    return _TaskSidebar(state: state, onSelect: onSelect, onRemove: onRemove);
  }
}

class _DocumentWorkspaceConsumer extends ConsumerWidget {
  const _DocumentWorkspaceConsumer({
    required this.onMarkdownChanged,
    required this.onFlush,
    required this.onRetry,
  });

  final void Function(String id, String markdown) onMarkdownChanged;
  final Future<void> Function() onFlush;
  final ValueChanged<String> onRetry;

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
            (task) => task.status == ConversionStatus.converting,
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
    required this.onCancel,
    required this.onExport,
    required this.onOpenLogs,
    required this.onThemeChanged,
  });

  final ConversionTask? selectedTask;
  final AppThemePreference themePreference;
  final VoidCallback onAddFiles;
  final VoidCallback onCancel;
  final VoidCallback onExport;
  final VoidCallback onOpenLogs;
  final ValueChanged<AppThemePreference> onThemeChanged;

  @override
  Widget build(BuildContext context) {
    final selected = selectedTask;
    final converting = selected?.status == ConversionStatus.converting;
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
  });

  final WorkspaceState state;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onRemove;

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
    return switch (task.status) {
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
  });

  final ConversionTask? task;
  final void Function(String id, String markdown) onMarkdownChanged;
  final Future<void> Function() onFlush;
  final ValueChanged<String> onRetry;

  @override
  State<_DocumentWorkspace> createState() => _DocumentWorkspaceState();
}

class _DocumentWorkspaceState extends State<_DocumentWorkspace> {
  EditorMode _mode = EditorMode.edit;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    if (task == null) return const _WorkspaceEmptyState();
    if (task.status == ConversionStatus.queued ||
        task.status == ConversionStatus.converting) {
      return _BusyState(task: task);
    }
    if (task.status == ConversionStatus.failed ||
        task.status == ConversionStatus.cancelled) {
      return _FailureState(task: task, onRetry: widget.onRetry);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DocumentHeader(task: task),
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
                ),
        ),
      ],
    );
  }

  Future<void> _changeMode(EditorMode mode) async {
    await widget.onFlush();
    if (mounted) setState(() => _mode = mode);
  }
}

class _DocumentHeader extends StatelessWidget {
  const _DocumentHeader({required this.task});

  final ConversionTask task;

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
                          onPressed: value.canUndo
                              ? _undoController.undo
                              : null,
                          tooltip: '撤销',
                          iconSize: 19,
                          icon: const Icon(Icons.undo),
                        ),
                        IconButton(
                          onPressed: value.canRedo
                              ? _undoController.redo
                              : null,
                          tooltip: '重做',
                          iconSize: 19,
                          icon: const Icon(Icons.redo),
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
                      onPressed: () => setState(() => _showSearch = false),
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
  });

  final String taskId;
  final int revision;
  final String markdown;

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
      ),
    );
  }

  Widget _buildScrollablePreview(Widget child) {
    return Scrollbar(
      controller: _scrollController,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: child,
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

class _ParsedMarkdownView extends StatefulWidget {
  const _ParsedMarkdownView({
    required this.document,
    required this.controller,
    required this.imageBuilder,
  });

  final ParsedMarkdownDocument document;
  final ScrollController controller;
  final MarkdownImageBuilder imageBuilder;

  @override
  State<_ParsedMarkdownView> createState() => _ParsedMarkdownViewState();
}

class _ParsedMarkdownViewState extends State<_ParsedMarkdownView>
    implements MarkdownBuilderDelegate {
  static const _padding = EdgeInsets.fromLTRB(28, 22, 28, 48);
  static const _eagerSourceLimit = 256 * 1024;
  static const _eagerNodeLimit = 1000;

  final List<GestureRecognizer> _recognizers = [];
  List<Widget> _children = const [];
  List<GlobalKey> _measurementKeys = const [];
  List<double>? _itemExtents;
  late MarkdownStyleSheet _styleSheet;
  bool _ready = false;
  int _layoutGeneration = 0;

  bool get _useEagerLayout =>
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
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget scrollable;
    if (_useEagerLayout) {
      scrollable = SingleChildScrollView(
        controller: widget.controller,
        padding: _padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _children,
        ),
      );
    } else if (_itemExtents == null) {
      scrollable = SingleChildScrollView(
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
      final itemExtents = _itemExtents!;
      scrollable = CustomScrollView(
        controller: widget.controller,
        scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
        slivers: [
          SliverPadding(
            padding: _padding,
            sliver: _MeasuredExtentSliver(
              itemExtents: itemExtents,
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
    _styleSheet = MarkdownStyleSheet.fromTheme(
      Theme.of(context),
    ).copyWith(textScaler: MediaQuery.textScalerOf(context));
    final builder = MarkdownBuilder(
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
    _children = List.unmodifiable(builder.build(widget.document.nodes));
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
  double indexToLayoutOffset(double itemExtent, int index) {
    return _offsets[index.clamp(0, _itemExtents.length)];
  }

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
  ) {
    return _offsets.last;
  }

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

class _LegacyMarkdownPreview extends StatelessWidget {
  const _LegacyMarkdownPreview({
    required this.markdown,
    required this.controller,
  });

  final String markdown;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return Markdown(
      data: markdown,
      controller: controller,
      selectable: true,
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
          Text(
            task.status == ConversionStatus.queued ? '等待转换' : '正在转换',
            style: Theme.of(context).textTheme.titleMedium,
          ),
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
  _ => '转换失败',
};
