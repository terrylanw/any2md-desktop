import 'conversion_task.dart';

enum AppThemePreference { system, light, dark }

class WorkspaceState {
  const WorkspaceState({
    this.tasks = const [],
    this.selectedTaskId,
    this.themePreference = AppThemePreference.system,
    this.initialized = false,
  });

  final List<ConversionTask> tasks;
  final String? selectedTaskId;
  final AppThemePreference themePreference;
  final bool initialized;

  ConversionTask? get selectedTask {
    for (final task in tasks) {
      if (task.id == selectedTaskId) return task;
    }
    return null;
  }

  int get completedCount =>
      tasks.where((task) => task.status == ConversionStatus.ready).length;

  bool get hasUnsavedChanges => tasks.any((task) => task.isDirty);

  WorkspaceState copyWith({
    List<ConversionTask>? tasks,
    String? selectedTaskId,
    bool clearSelection = false,
    AppThemePreference? themePreference,
    bool? initialized,
  }) {
    return WorkspaceState(
      tasks: tasks ?? this.tasks,
      selectedTaskId: clearSelection
          ? null
          : selectedTaskId ?? this.selectedTaskId,
      themePreference: themePreference ?? this.themePreference,
      initialized: initialized ?? this.initialized,
    );
  }
}
