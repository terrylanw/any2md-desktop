import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../domain/conversion_task.dart';

class DraftStore {
  final _writes = <String, _PendingDraftWrite>{};

  Future<Directory> _draftDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'Any2MD', 'drafts'));
  }

  Future<List<ConversionTask>> loadAll() async {
    final directory = await _draftDirectory();
    if (!await directory.exists()) return const [];
    final tasks = <ConversionTask>[];
    await for (final entity in directory.list()) {
      if (entity is! File || path.extension(entity.path) != '.json') continue;
      try {
        final json = jsonDecode(await entity.readAsString());
        tasks.add(
          ConversionTask.fromJson((json as Map).cast<String, Object?>()),
        );
      } on Object {
        // A corrupt draft is ignored; other drafts remain recoverable.
      }
    }
    tasks.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return tasks;
  }

  Future<void> save(ConversionTask task) async {
    final pending = _writes.putIfAbsent(task.id, _PendingDraftWrite.new);
    if (pending.latest == null || task.revision >= pending.latest!.revision) {
      pending.latest = task;
    }
    final waiter = Completer<void>();
    pending.waiters.add(waiter);
    if (!pending.running) unawaited(_drain(task.id, pending));
    return waiter.future;
  }

  Future<void> delete(String taskId) async {
    final pending = _writes[taskId];
    if (pending != null) {
      pending.latest = null;
      if (pending.running) {
        await Future.wait(pending.waiters.map((waiter) => waiter.future));
      }
      _writes.remove(taskId);
    }
    final directory = await _draftDirectory();
    final target = File(path.join(directory.path, '$taskId.json'));
    if (await target.exists()) await target.delete();
  }

  Future<void> _drain(String taskId, _PendingDraftWrite pending) async {
    pending.running = true;
    try {
      while (pending.latest != null) {
        final task = pending.latest!;
        pending.latest = null;
        await _write(task);
      }
      for (final waiter in pending.waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
    } on Object catch (error, stackTrace) {
      for (final waiter in pending.waiters) {
        if (!waiter.isCompleted) waiter.completeError(error, stackTrace);
      }
    } finally {
      pending.waiters.clear();
      pending.running = false;
      if (pending.latest == null) _writes.remove(taskId);
    }
  }

  Future<void> _write(ConversionTask task) async {
    final directory = await _draftDirectory();
    await directory.create(recursive: true);
    final target = File(path.join(directory.path, '${task.id}.json'));
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(jsonEncode(task.toJson()), flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }
}

class _PendingDraftWrite {
  ConversionTask? latest;
  bool running = false;
  final waiters = <Completer<void>>[];
}
