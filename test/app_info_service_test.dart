import 'package:any2md_desktop/services/app_info_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

PackageInfo packageInfo({String version = '0.1.2', String build = '1'}) =>
    PackageInfo(
      appName: 'native app name',
      packageName: 'com.any2md.desktop',
      version: version,
      buildNumber: build,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in {'windows': 'Windows', 'macos': 'macOS'}.entries) {
    test('reads package metadata on ${platform.value}', () async {
      final service = AppInfoService(
        packageInfoLoader: () async => packageInfo(),
        operatingSystem: platform.key,
      );

      final info = await service.load();

      expect(info.version, '0.1.2');
      expect(info.buildNumber, '1');
      expect(info.platformLabel, platform.value);
    });
  }

  test('default loader reads the installed package metadata', () async {
    PackageInfo.setMockInitialValues(
      appName: 'Any2MD',
      packageName: 'com.any2md.desktop',
      version: '9.8.7',
      buildNumber: '42',
      buildSignature: '',
    );

    final info = await AppInfoService(operatingSystem: 'windows').load();

    expect(info.version, '9.8.7');
    expect(info.buildNumber, '42');
  });

  test(
    'preserves prerelease versions and copies separate build metadata',
    () async {
      final info = await AppInfoService(
        packageInfoLoader: () async =>
            packageInfo(version: '0.2.0-beta.1', build: '7'),
        operatingSystem: 'macos',
      ).load();

      expect(info.displayVersion, '0.2.0-beta.1');
      expect(
        info.toClipboardText(),
        '应用：Any2MD\n版本：0.2.0-beta.1\n构建号：7\n操作系统：macOS',
      );
    },
  );

  test('missing fields have honest display and clipboard placeholders', () {
    const info = AppInfo(
      version: '  ',
      buildNumber: '',
      platformLabel: 'Windows',
    );

    expect(info.displayVersion, '未知');
    expect(info.displayBuildNumber, '未提供');
    expect(info.toClipboardText(), '应用：Any2MD\n版本：未知\n构建号：未提供\n操作系统：Windows');
  });

  test('propagates package read failures for explicit retry', () async {
    final service = AppInfoService(
      packageInfoLoader: () async =>
          throw PlatformException(code: 'package_unavailable'),
    );

    await expectLater(service.load(), throwsA(isA<PlatformException>()));
  });

  test(
    'provider loads lazily, caches data, and reloads on invalidation',
    () async {
      var reads = 0;
      final service = AppInfoService(
        packageInfoLoader: () async {
          reads++;
          return packageInfo();
        },
      );
      final container = ProviderContainer(
        overrides: [appInfoServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      expect(reads, 0);
      final first = await container.read(appInfoProvider.future);
      expect(await container.read(appInfoProvider.future), same(first));
      expect(reads, 1);

      container.invalidate(appInfoProvider);
      await container.read(appInfoProvider.future);
      expect(reads, 2);
    },
  );
}
