import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/workspace_state.dart';
import 'features/workspace/workspace_controller.dart';
import 'features/workspace/workspace_page.dart';

class Any2MdApp extends ConsumerWidget {
  const Any2MdApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(
      workspaceControllerProvider.select((state) => state.themePreference),
    );
    return MaterialApp(
      title: 'Any2MD',
      debugShowCheckedModeBanner: false,
      themeMode: switch (preference) {
        AppThemePreference.system => ThemeMode.system,
        AppThemePreference.light => ThemeMode.light,
        AppThemePreference.dark => ThemeMode.dark,
      },
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: const WorkspacePage(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff087f68),
      secondary: const Color(0xff9b6b00),
      brightness: brightness,
      surface: dark ? const Color(0xff171a19) : const Color(0xfff8faf9),
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'Microsoft YaHei',
      fontFamilyFallback: const [
        'Microsoft YaHei UI',
        'PingFang SC',
        'Noto Sans CJK SC',
      ],
      scaffoldBackgroundColor: dark
          ? const Color(0xff111413)
          : const Color(0xfff4f6f5),
      dividerColor: dark ? const Color(0xff343936) : const Color(0xffd9dedb),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
    );
    return base.copyWith(textTheme: _zeroLetterSpacing(base.textTheme));
  }

  TextTheme _zeroLetterSpacing(TextTheme theme) => theme.copyWith(
    displayLarge: theme.displayLarge?.copyWith(letterSpacing: 0),
    displayMedium: theme.displayMedium?.copyWith(letterSpacing: 0),
    displaySmall: theme.displaySmall?.copyWith(letterSpacing: 0),
    headlineLarge: theme.headlineLarge?.copyWith(letterSpacing: 0),
    headlineMedium: theme.headlineMedium?.copyWith(letterSpacing: 0),
    headlineSmall: theme.headlineSmall?.copyWith(letterSpacing: 0),
    titleLarge: theme.titleLarge?.copyWith(letterSpacing: 0),
    titleMedium: theme.titleMedium?.copyWith(letterSpacing: 0),
    titleSmall: theme.titleSmall?.copyWith(letterSpacing: 0),
    bodyLarge: theme.bodyLarge?.copyWith(letterSpacing: 0),
    bodyMedium: theme.bodyMedium?.copyWith(letterSpacing: 0),
    bodySmall: theme.bodySmall?.copyWith(letterSpacing: 0),
    labelLarge: theme.labelLarge?.copyWith(letterSpacing: 0),
    labelMedium: theme.labelMedium?.copyWith(letterSpacing: 0),
    labelSmall: theme.labelSmall?.copyWith(letterSpacing: 0),
  );
}
