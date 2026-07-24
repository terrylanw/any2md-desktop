import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  if (const bool.fromEnvironment('ENABLE_FLUTTER_DRIVER')) {
    enableFlutterDriverExtension();
  } else {
    WidgetsFlutterBinding.ensureInitialized();
  }
  if (Platform.isWindows || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    final savedBounds = await SettingsService().loadWindowBounds();
    final options = WindowOptions(
      size: savedBounds?.size ?? const Size(1280, 760),
      minimumSize: const Size(960, 640),
      center: savedBounds == null,
      title: 'Any2MD',
      titleBarStyle: TitleBarStyle.normal,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (savedBounds != null) await windowManager.setBounds(savedBounds);
      await windowManager.show();
      await windowManager.focus();
    });
  }
  runApp(const ProviderScope(child: Any2MdApp()));
}
