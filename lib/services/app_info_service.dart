import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

@immutable
class AppInfo {
  const AppInfo({
    required this.version,
    required this.buildNumber,
    required this.platformLabel,
  });

  static const appName = 'Any2MD';

  final String version;
  final String buildNumber;
  final String platformLabel;

  String get displayVersion => version.trim().isEmpty ? '未知' : version.trim();
  String get displayBuildNumber =>
      buildNumber.trim().isEmpty ? '未提供' : buildNumber.trim();

  String toClipboardText() => [
    '应用：$appName',
    '版本：$displayVersion',
    '构建号：$displayBuildNumber',
    '操作系统：$platformLabel',
  ].join('\n');
}

class AppInfoService {
  AppInfoService({
    Future<PackageInfo> Function()? packageInfoLoader,
    String? operatingSystem,
  }) : _packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform,
       _operatingSystem = operatingSystem ?? Platform.operatingSystem;

  final Future<PackageInfo> Function() _packageInfoLoader;
  final String _operatingSystem;

  Future<AppInfo> load() async {
    final package = await _packageInfoLoader();
    return AppInfo(
      version: package.version,
      buildNumber: package.buildNumber,
      platformLabel: switch (_operatingSystem) {
        'windows' => 'Windows',
        'macos' => 'macOS',
        _ => _operatingSystem,
      },
    );
  }
}

final appInfoServiceProvider = Provider<AppInfoService>(
  (ref) => AppInfoService(),
);

final appInfoProvider = FutureProvider<AppInfo>(
  (ref) => ref.watch(appInfoServiceProvider).load(),
  retry: (retryCount, error) => null,
);
