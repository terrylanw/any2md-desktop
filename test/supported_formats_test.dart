import 'package:any2md_desktop/core/supported_formats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file picker exposes only converter-supported extensions', () {
    expect(supportedPickerExtensions(), [
      'docx',
      'xlsx',
      'pptx',
      'pdf',
      'txt',
      'csv',
      'html',
      'htm',
    ]);
  });
}
