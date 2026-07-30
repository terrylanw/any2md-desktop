import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:any2md_desktop/services/converter_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dispose asks an idle worker to shut down gracefully', () async {
    final process = _FakeConverterProcess(respondToConversion: true);
    final client = ConverterClient(launcher: (_) async => process);

    final output = await client.convert(
      inputPath: 'document.docx',
      inputType: 'docx',
    );
    await client.dispose();
    await client.dispose();

    expect(output.markdown, '# Converted\n');
    expect(process.methods, ['convert', 'shutdown']);
    expect(process.wasKilled, isFalse);
  });

  test(
    'dispose force stops a busy worker without waiting for its task',
    () async {
      final process = _FakeConverterProcess(respondToConversion: false);
      final client = ConverterClient(launcher: (_) async => process);
      final conversion = client.convert(
        inputPath: 'large-document.docx',
        inputType: 'docx',
      );
      await process.conversionStarted.future;
      final conversionExpectation = expectLater(
        conversion,
        throwsA(
          isA<ConverterException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );

      await client.dispose();
      await conversionExpectation;

      expect(process.methods, ['convert']);
      expect(process.wasKilled, isTrue);
    },
  );
}

class _FakeConverterProcess implements Process {
  _FakeConverterProcess({required this.respondToConversion}) {
    _inputController.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleInput);
    _emit({'v': 1, 'type': 'ready', 'capabilities': <String>[]});
  }

  final bool respondToConversion;
  final methods = <String>[];
  final conversionStarted = Completer<void>();
  final _inputController = StreamController<List<int>>();
  final _stdoutController = StreamController<List<int>>();
  final _stderrController = StreamController<List<int>>();
  final _exitCode = Completer<int>();
  late final IOSink _stdin = IOSink(_inputController.sink);
  bool wasKilled = false;

  void _handleInput(String line) {
    final request = (jsonDecode(line) as Map).cast<String, Object?>();
    final method = request['method']! as String;
    methods.add(method);
    if (method == 'convert') {
      if (!conversionStarted.isCompleted) conversionStarted.complete();
      if (respondToConversion) {
        _emit({
          'v': 1,
          'id': request['id'],
          'type': 'result',
          'ok': true,
          'data': {'markdown': '# Converted\n', 'warnings': <String>[]},
        });
      }
    } else if (method == 'shutdown') {
      _emit({
        'v': 1,
        'id': request['id'],
        'type': 'result',
        'ok': true,
        'data': <String, Object?>{},
      });
      _completeExit();
    }
  }

  void _emit(Map<String, Object?> message) {
    _stdoutController.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  void _completeExit() {
    if (_exitCode.isCompleted) return;
    _exitCode.complete(0);
    unawaited(_stdoutController.close());
    unawaited(_stderrController.close());
  }

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 42;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    wasKilled = true;
    _completeExit();
    return true;
  }
}
