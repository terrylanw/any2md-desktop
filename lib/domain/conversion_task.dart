enum ConversionStatus {
  inspectionQueued,
  inspecting,
  awaitingSheetSelection,
  queued,
  converting,
  ready,
  failed,
  cancelled,
}

enum SheetVisibility { visible, hidden, veryHidden }

class WorkbookSheetInfo {
  const WorkbookSheetInfo({
    required this.name,
    required this.index,
    required this.visibility,
    required this.isEmpty,
    required this.rowCount,
    required this.columnCount,
    required this.preview,
  });

  final String name;
  final int index;
  final SheetVisibility visibility;
  final bool isEmpty;
  final int rowCount;
  final int columnCount;
  final List<List<String?>> preview;

  bool get isVisible => visibility == SheetVisibility.visible;
  bool get isSelectable => !isEmpty;

  Map<String, Object?> toJson() => {
    'name': name,
    'index': index,
    'visibility': visibility.name,
    'isEmpty': isEmpty,
    'rowCount': rowCount,
    'columnCount': columnCount,
    'preview': preview,
  };

  factory WorkbookSheetInfo.fromJson(Map<String, Object?> json) {
    final visibilityName = json['visibility'] as String? ?? 'visible';
    final visibility = SheetVisibility.values.firstWhere(
      (value) => value.name == visibilityName,
      orElse: () => SheetVisibility.visible,
    );
    return WorkbookSheetInfo(
      name: json['name']! as String,
      index: (json['index'] as num?)?.toInt() ?? 0,
      visibility: visibility,
      isEmpty: json['isEmpty'] as bool? ?? false,
      rowCount: (json['rowCount'] as num?)?.toInt() ?? 0,
      columnCount: (json['columnCount'] as num?)?.toInt() ?? 0,
      preview: (json['preview'] as List<Object?>? ?? const [])
          .whereType<List<Object?>>()
          .map(
            (row) =>
                row.map((cell) => cell?.toString()).toList(growable: false),
          )
          .toList(growable: false),
    );
  }
}

class ConversionTask {
  static const currentWorkbookInspectionVersion = 1;

  const ConversionTask({
    required this.id,
    required this.sourcePath,
    required this.displayName,
    required this.inputType,
    required this.status,
    required this.createdAt,
    this.revision = 0,
    this.markdown = '',
    this.warnings = const [],
    this.errorCode,
    this.errorMessage,
    this.errorRetryable = false,
    this.isDirty = false,
    this.exportedPath,
    this.workbookSheets = const [],
    this.selectedSheetNames = const [],
    this.hasManualEdits = false,
    this.workbookInspectionVersion = 0,
  });

  final String id;
  final String sourcePath;
  final String displayName;
  final String inputType;
  final ConversionStatus status;
  final DateTime createdAt;
  final int revision;
  final String markdown;
  final List<String> warnings;
  final String? errorCode;
  final String? errorMessage;
  final bool errorRetryable;
  final bool isDirty;
  final String? exportedPath;
  final List<WorkbookSheetInfo> workbookSheets;
  final List<String> selectedSheetNames;
  final bool hasManualEdits;
  final int workbookInspectionVersion;

  ConversionTask copyWith({
    ConversionStatus? status,
    String? markdown,
    List<String>? warnings,
    String? errorCode,
    String? errorMessage,
    bool? errorRetryable,
    bool clearError = false,
    bool? isDirty,
    String? exportedPath,
    bool clearExportedPath = false,
    int? revision,
    List<WorkbookSheetInfo>? workbookSheets,
    bool clearWorkbookSheets = false,
    List<String>? selectedSheetNames,
    bool clearSelectedSheetNames = false,
    bool? hasManualEdits,
    int? workbookInspectionVersion,
  }) {
    return ConversionTask(
      id: id,
      sourcePath: sourcePath,
      displayName: displayName,
      inputType: inputType,
      status: status ?? this.status,
      createdAt: createdAt,
      revision: revision ?? this.revision,
      markdown: markdown ?? this.markdown,
      warnings: warnings ?? this.warnings,
      errorCode: clearError ? null : errorCode ?? this.errorCode,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      errorRetryable: clearError
          ? false
          : errorRetryable ?? this.errorRetryable,
      isDirty: isDirty ?? this.isDirty,
      exportedPath: clearExportedPath
          ? null
          : exportedPath ?? this.exportedPath,
      workbookSheets: clearWorkbookSheets
          ? const []
          : workbookSheets ?? this.workbookSheets,
      selectedSheetNames: clearSelectedSheetNames
          ? const []
          : selectedSheetNames ?? this.selectedSheetNames,
      hasManualEdits: hasManualEdits ?? this.hasManualEdits,
      workbookInspectionVersion:
          workbookInspectionVersion ?? this.workbookInspectionVersion,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'sourcePath': sourcePath,
    'displayName': displayName,
    'inputType': inputType,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'revision': revision,
    'markdown': markdown,
    'warnings': warnings,
    'errorCode': errorCode,
    'errorMessage': errorMessage,
    'errorRetryable': errorRetryable,
    'isDirty': isDirty,
    'exportedPath': exportedPath,
    'workbookSheets': workbookSheets.map((sheet) => sheet.toJson()).toList(),
    'selectedSheetNames': selectedSheetNames,
    'hasManualEdits': hasManualEdits,
    'workbookInspectionVersion': workbookInspectionVersion,
  };

  factory ConversionTask.fromJson(Map<String, Object?> json) {
    final inputType = json['inputType']! as String;
    final sheets = (json['workbookSheets'] as List<Object?>? ?? const [])
        .whereType<Map>()
        .map(
          (sheet) => WorkbookSheetInfo.fromJson(sheet.cast<String, Object?>()),
        )
        .toList(growable: false);
    final persistedStatusName = json['status'] as String? ?? 'ready';
    final workbookInspectionVersion =
        (json['workbookInspectionVersion'] as num?)?.toInt() ?? 0;
    var status = ConversionStatus.values.firstWhere(
      (value) => value.name == persistedStatusName,
      orElse: () => ConversionStatus.ready,
    );
    if (status == ConversionStatus.inspecting) {
      status = ConversionStatus.inspectionQueued;
    } else if (status == ConversionStatus.converting) {
      status = inputType == 'xlsx' && sheets.isEmpty
          ? ConversionStatus.inspectionQueued
          : ConversionStatus.queued;
    } else if (status == ConversionStatus.queued &&
        inputType == 'xlsx' &&
        sheets.isEmpty) {
      status = ConversionStatus.inspectionQueued;
    } else if (status == ConversionStatus.awaitingSheetSelection &&
        inputType == 'xlsx' &&
        workbookInspectionVersion < currentWorkbookInspectionVersion) {
      status = ConversionStatus.inspectionQueued;
    }
    return ConversionTask(
      id: json['id']! as String,
      sourcePath: json['sourcePath']! as String,
      displayName: json['displayName']! as String,
      inputType: inputType,
      status: status,
      createdAt: DateTime.parse(json['createdAt']! as String),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      markdown: json['markdown'] as String? ?? '',
      warnings: (json['warnings'] as List<Object?>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      errorCode: json['errorCode'] as String?,
      errorMessage: json['errorMessage'] as String?,
      errorRetryable: json['errorRetryable'] as bool? ?? false,
      isDirty: json['isDirty'] as bool? ?? true,
      exportedPath: json['exportedPath'] as String?,
      workbookSheets: sheets,
      selectedSheetNames:
          (json['selectedSheetNames'] as List<Object?>? ?? const [])
              .whereType<String>()
              .toList(growable: false),
      hasManualEdits: json['hasManualEdits'] as bool? ?? false,
      workbookInspectionVersion: workbookInspectionVersion,
    );
  }
}
