import 'dart:io';

class ExportService {
  Future<void> exportMarkdown(String markdown, String destination) async {
    final target = File(destination);
    await target.parent.create(recursive: true);
    final temporary = File('$destination.any2md.tmp');
    final normalized = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    await temporary.writeAsString(normalized, flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }
}
