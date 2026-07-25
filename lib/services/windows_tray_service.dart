import 'dart:async';

import 'package:tray_manager/tray_manager.dart';

typedef TrayAction = Future<void> Function();
typedef TrayLogSink = Future<void> Function(String message);

class WindowsTrayService with TrayListener {
  WindowsTrayService(this._logSink);

  static const iconAsset = 'windows/runner/resources/app_icon.ico';
  static const showWindowKey = 'show_window';
  static const exitAppKey = 'exit_app';

  final TrayLogSink _logSink;
  TrayAction? _onShowRequested;
  TrayAction? _onExitRequested;
  bool _listenerRegistered = false;
  bool _ready = false;
  bool _shuttingDown = false;

  bool get isReady => _ready;

  Future<bool> initialize({
    required TrayAction onShowRequested,
    required TrayAction onExitRequested,
  }) async {
    if (_ready) return true;

    _onShowRequested = onShowRequested;
    _onExitRequested = onExitRequested;
    if (!_listenerRegistered) {
      trayManager.addListener(this);
      _listenerRegistered = true;
    }

    try {
      await trayManager.setIcon(iconAsset);
      await trayManager.setToolTip('Any2MD');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: showWindowKey, label: '打开 Any2MD'),
            MenuItem.separator(),
            MenuItem(key: exitAppKey, label: '退出'),
          ],
        ),
      );
      _ready = true;
      return true;
    } catch (error, stackTrace) {
      _ready = false;
      _removeListener();
      await _destroyAfterFailedInitialization();
      await _log('Windows tray initialization failed: $error', stackTrace);
      return false;
    }
  }

  Future<void> shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    final shouldDestroy = _ready;
    _ready = false;
    _removeListener();
    _onShowRequested = null;
    _onExitRequested = null;
    try {
      if (shouldDestroy) await trayManager.destroy();
    } catch (error, stackTrace) {
      await _log('Windows tray shutdown failed: $error', stackTrace);
    } finally {
      _shuttingDown = false;
    }
  }

  void dispose() {
    _ready = false;
    _removeListener();
    _onShowRequested = null;
    _onExitRequested = null;
  }

  @override
  void onTrayIconMouseDown() {
    _runAction('show window', _onShowRequested);
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_showContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case showWindowKey:
        _runAction('show window', _onShowRequested);
      case exitAppKey:
        _runAction('exit application', _onExitRequested);
    }
  }

  void _runAction(String name, TrayAction? action) {
    if (!_ready || action == null) return;
    unawaited(_runGuarded(name, action));
  }

  Future<void> _runGuarded(String name, TrayAction action) async {
    try {
      await action();
    } catch (error, stackTrace) {
      await _log('Windows tray action "$name" failed: $error', stackTrace);
    }
  }

  Future<void> _showContextMenu() async {
    if (!_ready) return;
    try {
      await trayManager.popUpContextMenu();
    } catch (error, stackTrace) {
      await _log('Windows tray context menu failed: $error', stackTrace);
    }
  }

  Future<void> _destroyAfterFailedInitialization() async {
    try {
      await trayManager.destroy();
    } catch (_) {
      // The native icon may not have been created yet.
    }
  }

  void _removeListener() {
    if (!_listenerRegistered) return;
    trayManager.removeListener(this);
    _listenerRegistered = false;
  }

  Future<void> _log(String message, StackTrace stackTrace) async {
    try {
      await _logSink('$message ${stackTrace.toString().split('\n').first}');
    } catch (_) {
      // Logging must not break window or tray lifecycle handling.
    }
  }
}
