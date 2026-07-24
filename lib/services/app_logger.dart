import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class AppLogger {
  static const _maxBytes = 2 * 1024 * 1024;
  static const _maxFiles = 5;
  Future<void> _writeChain = Future.value();

  Future<Directory> logDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'Any2MD', 'logs'));
  }

  Future<void> write(String message) {
    _writeChain = _writeChain.then((_) => _write(message));
    return _writeChain;
  }

  Future<void> _write(String message) async {
    final directory = await logDirectory();
    await directory.create(recursive: true);
    final current = File(path.join(directory.path, 'any2md.log'));
    if (await current.exists() && await current.length() >= _maxBytes) {
      await _rotate(directory);
    }
    final sanitized = message.replaceAll(RegExp(r'[\r\n]+'), ' ');
    await current.writeAsString(
      '${DateTime.now().toIso8601String()} $sanitized\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> _rotate(Directory directory) async {
    final oldest = File(path.join(directory.path, 'any2md.log.$_maxFiles'));
    if (await oldest.exists()) await oldest.delete();
    for (var index = _maxFiles - 1; index >= 1; index--) {
      final source = File(path.join(directory.path, 'any2md.log.$index'));
      if (await source.exists()) {
        await source.rename(
          path.join(directory.path, 'any2md.log.${index + 1}'),
        );
      }
    }
    final current = File(path.join(directory.path, 'any2md.log'));
    if (await current.exists()) {
      await current.rename(path.join(directory.path, 'any2md.log.1'));
    }
  }

  Future<void> openDirectory() async {
    final directory = await logDirectory();
    await directory.create(recursive: true);
    if (Platform.isWindows) {
      await Process.run('explorer.exe', [directory.path], runInShell: false);
    } else if (Platform.isMacOS) {
      await Process.run('open', [directory.path], runInShell: false);
    }
  }
}
