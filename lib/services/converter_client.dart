import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

class ConversionOutput {
  const ConversionOutput({required this.markdown, required this.warnings});

  final String markdown;
  final List<String> warnings;
}

class ConverterException implements Exception {
  const ConverterException(this.code, this.message, {this.retryable = false});

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => 'ConverterException($code): $message';
}

class ConverterLaunchSpec {
  const ConverterLaunchSpec(
    this.executable,
    this.arguments, {
    this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
}

typedef ConverterLauncher = Future<Process> Function(ConverterLaunchSpec spec);

class ConverterClient {
  ConverterClient({
    ConverterLauncher? launcher,
    void Function(String message)? logSink,
    this.conversionTimeout = const Duration(minutes: 5),
  }) : _launcher = launcher ?? _defaultLauncher,
       _logSink = logSink ?? _discardLog;

  static const _protocolVersion = 1;
  static const _uuid = Uuid();

  final ConverterLauncher _launcher;
  final void Function(String message) _logSink;
  final Duration conversionTimeout;
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Completer<void>? _readyCompleter;
  Completer<ConversionOutput>? _activeCompleter;
  String? _activeRequestId;
  int _generation = 0;
  bool _disposed = false;

  Future<ConversionOutput> convert({
    required String inputPath,
    required String inputType,
  }) async {
    if (_disposed) {
      throw const ConverterException('worker_crashed', '转换服务已关闭');
    }
    if (_activeCompleter != null) {
      throw const ConverterException('protocol_error', '转换服务正忙');
    }

    await _ensureStarted();
    final requestId = _uuid.v4();
    final completer = Completer<ConversionOutput>();
    _activeRequestId = requestId;
    _activeCompleter = completer;
    _process!.stdin.writeln(
      jsonEncode({
        'v': _protocolVersion,
        'id': requestId,
        'method': 'convert',
        'params': {
          'inputPath': inputPath,
          'inputType': inputType,
          'preferFileResult': true,
        },
      }),
    );
    await _process!.stdin.flush();

    try {
      return await completer.future.timeout(conversionTimeout);
    } on TimeoutException {
      await restart();
      throw const ConverterException(
        'timeout',
        '转换超过 5 分钟，已终止任务',
        retryable: true,
      );
    } finally {
      if (identical(_activeCompleter, completer)) {
        _activeCompleter = null;
        _activeRequestId = null;
      }
    }
  }

  Future<void> cancelCurrent() async {
    final completer = _activeCompleter;
    _activeCompleter = null;
    _activeRequestId = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(const ConverterException('cancelled', '转换已取消'));
    }
    await restart();
  }

  Future<void> _ensureStarted() async {
    if (_process != null && _readyCompleter?.isCompleted == true) return;

    final generation = ++_generation;
    final ready = Completer<void>();
    _readyCompleter = ready;
    final spec = _resolveLaunchSpec();
    final process = await _launcher(spec);
    _process = process;

    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _handleLine(line, generation),
          onError: (Object error, StackTrace stackTrace) {
            _failWorker('无法读取转换服务响应：$error', generation);
          },
        );
    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _logSink('converter: $line'));
    unawaited(
      process.exitCode.then((code) {
        if (generation == _generation && !_disposed) {
          _failWorker('转换服务意外退出（代码 $code）', generation);
        }
      }),
    );

    try {
      await ready.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      await restart();
      throw const ConverterException(
        'worker_crashed',
        '转换服务启动超时',
        retryable: true,
      );
    }
  }

  void _handleLine(String line, int generation) {
    if (generation != _generation) return;
    Map<String, Object?> message;
    try {
      message = (jsonDecode(line) as Map).cast<String, Object?>();
    } on Object {
      _failWorker('转换服务返回了无效协议消息', generation);
      return;
    }

    if (message['v'] != _protocolVersion) {
      _failWorker('转换服务协议版本不兼容', generation);
      return;
    }
    if (message['type'] == 'ready') {
      final ready = _readyCompleter;
      if (ready != null && !ready.isCompleted) ready.complete();
      return;
    }
    if (message['type'] != 'result' || message['id'] != _activeRequestId) {
      return;
    }

    final completer = _activeCompleter;
    if (completer == null || completer.isCompleted) return;
    if (message['ok'] == true) {
      final data = (message['data'] as Map).cast<String, Object?>();
      final warnings = (data['warnings'] as List<Object?>? ?? const [])
          .whereType<String>()
          .toList(growable: false);
      final markdownPath = data['markdownPath'] as String?;
      if (markdownPath != null) {
        unawaited(
          _completeFileResult(markdownPath, warnings, completer, generation),
        );
      } else {
        completer.complete(
          ConversionOutput(
            markdown: data['markdown'] as String? ?? '',
            warnings: warnings,
          ),
        );
      }
    } else {
      final error = (message['error'] as Map).cast<String, Object?>();
      completer.completeError(
        ConverterException(
          error['code'] as String? ?? 'conversion_failed',
          error['message'] as String? ?? '转换失败',
          retryable: error['retryable'] as bool? ?? false,
        ),
      );
    }
  }

  Future<void> _completeFileResult(
    String markdownPath,
    List<String> warnings,
    Completer<ConversionOutput> completer,
    int generation,
  ) async {
    final file = File(markdownPath);
    try {
      final markdown = await file.readAsString();
      if (generation == _generation && !completer.isCompleted) {
        completer.complete(
          ConversionOutput(markdown: markdown, warnings: warnings),
        );
      }
    } on Object catch (error) {
      if (!completer.isCompleted) {
        completer.completeError(
          ConverterException(
            'protocol_error',
            '无法读取转换结果：$error',
            retryable: true,
          ),
        );
      }
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } on Object {
        // Temporary result cleanup is best-effort.
      }
    }
  }

  void _failWorker(String message, int generation) {
    if (generation != _generation) return;
    final ready = _readyCompleter;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        ConverterException('worker_crashed', message, retryable: true),
      );
    }
    final active = _activeCompleter;
    if (active != null && !active.isCompleted) {
      active.completeError(
        ConverterException('worker_crashed', message, retryable: true),
      );
    }
    _clearProcessHandles();
  }

  Future<void> restart() async {
    ++_generation;
    final process = _process;
    _clearProcessHandles();
    process?.kill();
    if (process != null) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on Object {
        // The next request starts a fresh worker even if the old process lingers.
      }
    }
  }

  void _clearProcessHandles() {
    _process = null;
    _readyCompleter = null;
    unawaited(_stdoutSubscription?.cancel());
    unawaited(_stderrSubscription?.cancel());
    _stdoutSubscription = null;
    _stderrSubscription = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancelCurrent();
  }

  static ConverterLaunchSpec _resolveLaunchSpec() {
    final override = Platform.environment['ANY2MD_CONVERTER_PATH'];
    if (override != null && override.isNotEmpty) {
      return ConverterLaunchSpec(override, const []);
    }

    final executableDirectory = path.dirname(Platform.resolvedExecutable);
    final packagedPath = Platform.isMacOS
        ? path.normalize(
            path.join(
              executableDirectory,
              '..',
              'Resources',
              'converter',
              'any2md_converter',
            ),
          )
        : path.join(executableDirectory, 'converter', 'any2md_converter.exe');
    if (File(packagedPath).existsSync()) {
      return ConverterLaunchSpec(packagedPath, const []);
    }

    final workerScript = path.absolute('converter', 'worker.py');
    if (File(workerScript).existsSync()) {
      final converterDirectory = path.dirname(workerScript);
      final localPython = Platform.isWindows
          ? path.join(converterDirectory, '.venv', 'Scripts', 'python.exe')
          : path.join(converterDirectory, '.venv', 'bin', 'python');
      final pythonOverride = Platform.environment['ANY2MD_PYTHON'];
      final python = pythonOverride != null && pythonOverride.isNotEmpty
          ? pythonOverride
          : File(localPython).existsSync()
          ? localPython
          : 'python';
      return ConverterLaunchSpec(python, [
        '-X',
        'utf8',
        workerScript,
      ], workingDirectory: converterDirectory);
    }
    throw const ConverterException(
      'worker_crashed',
      '未找到转换服务，请重新安装 Any2MD',
      retryable: false,
    );
  }

  static Future<Process> _defaultLauncher(ConverterLaunchSpec spec) {
    return Process.start(
      spec.executable,
      spec.arguments,
      workingDirectory: spec.workingDirectory,
      runInShell: false,
    );
  }

  static void _discardLog(String _) {}
}
