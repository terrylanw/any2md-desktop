import 'dart:async';

import 'package:any2md_desktop/features/about/about_dialog.dart';
import 'package:any2md_desktop/services/app_info_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const info = AppInfo(
  version: '0.1.2',
  buildNumber: '1',
  platformLabel: 'Windows',
);

Finder get copyButton => find.ancestor(
  of: find.text('复制信息'),
  matching: find.byWidgetPredicate((widget) => widget is TextButton),
);

Future<void> openDialog(
  WidgetTester tester, {
  required Future<AppInfo> Function() load,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appInfoProvider.overrideWith((ref) => load())],
      child: MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff087f68),
            brightness: brightness,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => const AppAboutDialog(),
              ),
              child: const Text('打开关于'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开关于'));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('loads metadata asynchronously and enables copy on success', (
    tester,
  ) async {
    final pending = Completer<AppInfo>();
    await openDialog(tester, load: () => pending.future);

    expect(find.text('正在读取版本信息…'), findsOneWidget);
    expect(tester.widget<TextButton>(copyButton).onPressed, isNull);
    expect(find.text('关闭'), findsOneWidget);

    pending.complete(info);
    await tester.pumpAndSettle();

    expect(find.text('0.1.2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Windows'), findsOneWidget);
    expect(tester.widget<TextButton>(copyButton).onPressed, isNotNull);
    expect(find.byType(SelectableText), findsNWidgets(3));
  });

  testWidgets('shows missing field placeholders', (tester) async {
    await openDialog(
      tester,
      load: () async =>
          const AppInfo(version: '', buildNumber: '  ', platformLabel: 'macOS'),
    );

    expect(find.text('未知'), findsOneWidget);
    expect(find.text('未提供'), findsOneWidget);
    expect(find.text('macOS'), findsOneWidget);
  });

  testWidgets('shows a stable error and retries metadata loading', (
    tester,
  ) async {
    var reads = 0;
    await openDialog(
      tester,
      load: () async {
        reads++;
        if (reads == 1) throw StateError('metadata unavailable');
        return info;
      },
    );

    expect(find.text('暂时无法读取版本信息'), findsOneWidget);
    expect(tester.widget<TextButton>(copyButton).onPressed, isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(reads, 1);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(reads, 2);
    expect(find.text('0.1.2'), findsOneWidget);
    expect(tester.widget<TextButton>(copyButton).onPressed, isNotNull);
  });

  testWidgets('copies the exact support information and announces success', (
    tester,
  ) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    await openDialog(tester, load: () async => info);

    await tester.tap(find.text('复制信息'));
    await tester.pumpAndSettle();

    expect(copied, '应用：Any2MD\n版本：0.1.2\n构建号：1\n操作系统：Windows');
    expect(find.text('应用信息已复制'), findsOneWidget);
  });

  testWidgets('clipboard failure leaves selectable metadata and allows retry', (
    tester,
  ) async {
    var fail = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData' && fail) {
            throw PlatformException(code: 'clipboard_unavailable');
          }
          return null;
        });
    await openDialog(tester, load: () async => info);

    await tester.tap(find.text('复制信息'));
    await tester.pumpAndSettle();
    expect(find.text('复制失败，请重试'), findsOneWidget);
    expect(find.byType(SelectableText), findsNWidgets(3));
    expect(tester.widget<TextButton>(copyButton).onPressed, isNotNull);

    fail = false;
    await tester.tap(find.text('复制信息'));
    await tester.pumpAndSettle();
    expect(find.text('应用信息已复制'), findsOneWidget);
  });

  testWidgets('can close before metadata finishes loading', (tester) async {
    final pending = Completer<AppInfo>();
    await openDialog(tester, load: () => pending.future);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    pending.complete(info);
    await tester.pumpAndSettle();

    expect(find.byType(AppAboutDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('can close during a pending clipboard operation', (tester) async {
    final pending = Completer<void>();
    var copies = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copies++;
            await pending.future;
          }
          return null;
        });
    await openDialog(tester, load: () async => info);

    await tester.tap(find.text('复制信息'));
    await tester.pump();
    expect(tester.widget<TextButton>(copyButton).onPressed, isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    pending.complete();
    await tester.pumpAndSettle();

    expect(copies, 1);
    expect(find.byType(AppAboutDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(960, 640), const Size(1280, 760)]) {
    for (final brightness in Brightness.values) {
      testWidgets('fits $size with $brightness and enlarged text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final longVersion =
            '0.2.0-beta.${List.filled(12, 'long-prerelease').join('.')}';

        await openDialog(
          tester,
          load: () async => AppInfo(
            version: longVersion,
            buildNumber: '1234567890',
            platformLabel: 'Windows',
          ),
          brightness: brightness,
          textScale: 2,
        );

        expect(find.text(longVersion), findsOneWidget);
        expect(find.text('关闭').hitTestable(), findsOneWidget);
        expect(find.text('复制信息').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(AppAboutDialog), findsNothing);
      });
    }
  }
}
