import 'package:any2md_desktop/services/windows_tray_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tray_manager');
  late List<MethodCall> methodCalls;
  late List<String> logMessages;
  late WindowsTrayService service;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    methodCalls = [];
    logMessages = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methodCalls.add(call);
          return null;
        });
    service = WindowsTrayService((message) async => logMessages.add(message));
  });

  tearDown(() async {
    await service.shutdown();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('initializes the Windows tray icon, tooltip, and menu', () async {
    final ready = await service.initialize(
      onShowRequested: () async {},
      onExitRequested: () async {},
    );

    expect(ready, isTrue);
    expect(service.isReady, isTrue);
    expect(
      methodCalls.map((call) => call.method),
      containsAllInOrder(['setIcon', 'setToolTip', 'setContextMenu']),
    );

    final iconCall = methodCalls.firstWhere((call) => call.method == 'setIcon');
    final iconArguments = iconCall.arguments as Map<Object?, Object?>;
    expect(
      (iconArguments['iconPath'] as String).replaceAll('\\', '/'),
      endsWith('/data/flutter_assets/${WindowsTrayService.iconAsset}'),
    );

    final tooltipCall = methodCalls.firstWhere(
      (call) => call.method == 'setToolTip',
    );
    expect(
      (tooltipCall.arguments as Map<Object?, Object?>)['toolTip'],
      'Any2MD',
    );

    final menuCall = methodCalls.firstWhere(
      (call) => call.method == 'setContextMenu',
    );
    final menuJson = menuCall.arguments.toString();
    expect(menuJson, contains(WindowsTrayService.showWindowKey));
    expect(menuJson, contains('打开 Any2MD'));
    expect(menuJson, contains(WindowsTrayService.exitAppKey));
    expect(menuJson, contains('退出'));

    await service.shutdown();
    await service.shutdown();
    expect(
      methodCalls.where((call) => call.method == 'destroy'),
      hasLength(1),
    );
  });

  test('dispatches tray icon and menu actions', () async {
    var showRequests = 0;
    var exitRequests = 0;
    await service.initialize(
      onShowRequested: () async => showRequests++,
      onExitRequested: () async => exitRequests++,
    );
    methodCalls.clear();

    service.onTrayIconMouseDown();
    service.onTrayIconRightMouseDown();
    service.onTrayMenuItemClick(
      MenuItem(key: WindowsTrayService.showWindowKey),
    );
    service.onTrayMenuItemClick(MenuItem(key: WindowsTrayService.exitAppKey));
    await Future<void>.delayed(Duration.zero);

    expect(showRequests, 2);
    expect(exitRequests, 1);
    expect(
      methodCalls.where((call) => call.method == 'popUpContextMenu'),
      hasLength(1),
    );
    expect(logMessages, isEmpty);
  });

  test('fails safely when tray initialization throws', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methodCalls.add(call);
          if (call.method == 'setIcon') {
            throw PlatformException(code: 'icon_failed');
          }
          return null;
        });

    final ready = await service.initialize(
      onShowRequested: () async {},
      onExitRequested: () async {},
    );

    expect(ready, isFalse);
    expect(service.isReady, isFalse);
    expect(methodCalls.where((call) => call.method == 'destroy'), hasLength(1));
    expect(logMessages.single, contains('tray initialization failed'));

    await service.shutdown();
    expect(methodCalls.where((call) => call.method == 'destroy'), hasLength(1));
  });
}
