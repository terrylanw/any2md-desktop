import 'package:any2md_desktop/domain/conversion_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('draft JSON restores a ready editable task', () {
    final task = ConversionTask(
      id: 'task-1',
      sourcePath: r'C:\docs\report.docx',
      displayName: 'report.docx',
      inputType: 'docx',
      status: ConversionStatus.ready,
      createdAt: DateTime.utc(2026, 7, 23),
      markdown: '# Report',
      warnings: const ['possible_scanned_pdf'],
      isDirty: true,
    );

    final restored = ConversionTask.fromJson(task.toJson());

    expect(restored.id, task.id);
    expect(restored.status, ConversionStatus.ready);
    expect(restored.markdown, '# Report');
    expect(restored.warnings, ['possible_scanned_pdf']);
    expect(restored.isDirty, isTrue);
  });

  test('copyWith can clear stale errors and exported path', () {
    final task = ConversionTask(
      id: 'task-1',
      sourcePath: '/tmp/report.pdf',
      displayName: 'report.pdf',
      inputType: 'pdf',
      status: ConversionStatus.failed,
      createdAt: DateTime.utc(2026, 7, 23),
      errorCode: 'timeout',
      errorMessage: 'late',
      errorRetryable: true,
      exportedPath: '/tmp/report.md',
    );

    final queued = task.copyWith(
      status: ConversionStatus.queued,
      clearError: true,
      clearExportedPath: true,
    );

    expect(queued.errorCode, isNull);
    expect(queued.errorMessage, isNull);
    expect(queued.errorRetryable, isFalse);
    expect(queued.exportedPath, isNull);
  });
}
