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

  test('workbook metadata and selection survive draft JSON', () {
    final task = ConversionTask(
      id: 'xlsx-1',
      sourcePath: r'C:\docs\report.xlsx',
      displayName: 'report.xlsx',
      inputType: 'xlsx',
      status: ConversionStatus.awaitingSheetSelection,
      createdAt: DateTime.utc(2026, 7, 24),
      workbookSheets: const [
        WorkbookSheetInfo(
          name: 'Summary',
          index: 0,
          visibility: SheetVisibility.visible,
          isEmpty: false,
          rowCount: 2,
          columnCount: 2,
          preview: [
            ['Name', 'Value'],
            ['Alpha', '42'],
          ],
        ),
      ],
      selectedSheetNames: const ['Summary'],
      hasManualEdits: true,
      workbookInspectionVersion:
          ConversionTask.currentWorkbookInspectionVersion,
    );

    final restored = ConversionTask.fromJson(task.toJson());

    expect(restored.status, ConversionStatus.awaitingSheetSelection);
    expect(restored.workbookSheets.single.name, 'Summary');
    expect(restored.workbookSheets.single.preview[1], ['Alpha', '42']);
    expect(restored.selectedSheetNames, ['Summary']);
    expect(restored.hasManualEdits, isTrue);
    expect(
      restored.workbookInspectionVersion,
      ConversionTask.currentWorkbookInspectionVersion,
    );
  });

  test('active workbook states normalize when a draft is restored', () {
    final inspecting = ConversionTask(
      id: 'xlsx-1',
      sourcePath: r'C:\docs\report.xlsx',
      displayName: 'report.xlsx',
      inputType: 'xlsx',
      status: ConversionStatus.inspecting,
      createdAt: DateTime.utc(2026, 7, 24),
    );

    final restored = ConversionTask.fromJson(inspecting.toJson());

    expect(restored.status, ConversionStatus.inspectionQueued);
  });

  test('legacy workbook inspection is refreshed when a draft is restored', () {
    final task = ConversionTask(
      id: 'xlsx-legacy',
      sourcePath: r'C:\docs\report.xlsx',
      displayName: 'report.xlsx',
      inputType: 'xlsx',
      status: ConversionStatus.awaitingSheetSelection,
      createdAt: DateTime.utc(2026, 7, 24),
      workbookSheets: const [
        WorkbookSheetInfo(
          name: 'Summary',
          index: 0,
          visibility: SheetVisibility.visible,
          isEmpty: false,
          rowCount: 1,
          columnCount: 1,
          preview: [
            ['Name'],
          ],
        ),
      ],
      selectedSheetNames: const ['Summary'],
    );

    final restored = ConversionTask.fromJson(task.toJson());

    expect(restored.status, ConversionStatus.inspectionQueued);
    expect(restored.selectedSheetNames, ['Summary']);
  });
}
