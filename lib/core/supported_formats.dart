import 'package:path/path.dart' as path;

const supportedExtensions = <String, String>{
  '.docx': 'docx',
  '.xlsx': 'xlsx',
  '.pptx': 'pptx',
  '.pdf': 'pdf',
  '.txt': 'txt',
  '.csv': 'csv',
  '.html': 'html',
  '.htm': 'html',
};

String? inputTypeForPath(String filePath) =>
    supportedExtensions[path.extension(filePath).toLowerCase()];

List<String> supportedPickerExtensions() => supportedExtensions.keys
    .map((extension) => extension.substring(1))
    .toList(growable: false);

String supportedFormatsLabel() => 'DOCX、XLSX、PPTX、PDF、TXT、CSV、HTML';
