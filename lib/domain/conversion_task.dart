enum ConversionStatus { queued, converting, ready, failed, cancelled }

class ConversionTask {
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
    'isDirty': isDirty,
    'exportedPath': exportedPath,
  };

  factory ConversionTask.fromJson(Map<String, Object?> json) {
    return ConversionTask(
      id: json['id']! as String,
      sourcePath: json['sourcePath']! as String,
      displayName: json['displayName']! as String,
      inputType: json['inputType']! as String,
      status: ConversionStatus.ready,
      createdAt: DateTime.parse(json['createdAt']! as String),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      markdown: json['markdown'] as String? ?? '',
      warnings: (json['warnings'] as List<Object?>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      isDirty: json['isDirty'] as bool? ?? true,
      exportedPath: json['exportedPath'] as String?,
    );
  }
}
