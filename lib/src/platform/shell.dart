import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../app/watcher_service.dart';

enum ShellMode { overlay, settings }

/// The single native window (overlay, or temporarily the settings form) and
/// the notification-area icon.
///
/// The app has no main window: closing the window only hides it, and the
/// process ends through the tray menu's *Quit*.
class Shell with WindowListener, TrayListener {
  Shell(this.service);

  final WatcherService service;
  final mode = ValueNotifier(ShellMode.overlay);

  static const overlayDefaultSize = Size(260, 180);
  static const overlayMinSize = Size(160, 40);
  static const settingsSize = Size(480, 680);

  bool _visible = false;
  bool? _alertIcon;
  String? _tooltip;
  Timer? _saveBounds;

  bool get visible => _visible;

  Future<void> init() async {
    await windowManager.ensureInitialized();
    final s = service.settings;
    final bounds = s.overlayBounds;
    final options = WindowOptions(
      title: 'mlwatcher',
      size: bounds?.size ?? overlayDefaultSize,
      minimumSize: overlayMinSize,
      skipTaskbar: true,
      alwaysOnTop: s.alwaysOnTop,
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      await windowManager.setPreventClose(true);
      if (bounds != null) await windowManager.setPosition(bounds.topLeft);
      await windowManager.setOpacity(s.opacityPercent / 100);
      await windowManager.setAlwaysOnTop(s.alwaysOnTop);
      if (s.overlayVisible) {
        await windowManager.show();
        _visible = true;
      } else {
        await windowManager.hide();
      }
    });
    windowManager.addListener(this);
    await _initTray();
    service.addListener(_updateTray);
  }

  // ---------------------------------------------------------------- overlay

  Future<void> showOverlay() async {
    if (mode.value == ShellMode.settings) return windowManager.focus();
    await windowManager.show();
    // Raise above other windows even when "always on top" is off.
    if (!service.settings.alwaysOnTop) {
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setAlwaysOnTop(false);
    }
    _visible = true;
    await _rememberVisible(true);
  }

  Future<void> hideOverlay() async {
    if (mode.value == ShellMode.settings) return;
    await windowManager.hide();
    _visible = false;
    await _rememberVisible(false);
  }

  /// Shrinks the overlay to [height] (what its content needs) when it is
  /// taller, keeping the top edge and the width. Called when the content
  /// changes; the overlay never grows by itself, only by hand.
  Future<void> shrinkOverlayToFit(double height) async {
    if (mode.value != ShellMode.overlay) return;
    final h = max(height.ceilToDouble(), overlayMinSize.height);
    final b = await windowManager.getBounds();
    if (h >= b.height - 1) return;
    await windowManager.setBounds(Rect.fromLTWH(b.left, b.top, b.width, h));
  }

  Future<void> toggleOverlay() => _visible && mode.value == ShellMode.overlay ? hideOverlay() : showOverlay();

  Future<void> toggleAlwaysOnTop() async {
    final onTop = !service.settings.alwaysOnTop;
    await windowManager.setAlwaysOnTop(onTop);
    await service.updateDisplay(service.settings.copyWith(alwaysOnTop: onTop));
  }

  Future<void> _rememberVisible(bool v) async {
    if (service.settings.overlayVisible != v) {
      await service.updateDisplay(service.settings.copyWith(overlayVisible: v));
    }
  }

  /// Re-applies display settings after the settings form was saved.
  Future<void> applyDisplaySettings() async {
    if (mode.value != ShellMode.overlay) return;
    await windowManager.setOpacity(service.settings.opacityPercent / 100);
    await windowManager.setAlwaysOnTop(service.settings.alwaysOnTop);
  }

  // --------------------------------------------------------------- settings

  Future<void> openSettings() async {
    if (mode.value == ShellMode.settings) {
      await windowManager.show();
      await windowManager.focus();
      return;
    }
    _saveBounds?.cancel();
    if (_visible) await _storeBounds();
    mode.value = ShellMode.settings;
    await windowManager.setOpacity(1);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setMinimumSize(const Size(400, 480));
    await windowManager.setSize(settingsSize);
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> closeSettings() async {
    if (mode.value != ShellMode.settings) return;
    final s = service.settings;
    await windowManager.hide();
    await windowManager.setMinimumSize(overlayMinSize);
    final b = s.overlayBounds;
    if (b != null) {
      await windowManager.setBounds(b);
    } else {
      await windowManager.setSize(overlayDefaultSize);
    }
    await windowManager.setOpacity(s.opacityPercent / 100);
    await windowManager.setAlwaysOnTop(s.alwaysOnTop);
    mode.value = ShellMode.overlay;
    _visible = s.overlayVisible;
    if (_visible) await windowManager.show();
  }

  Future<void> quit() async {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    service.removeListener(_updateTray);
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  // ----------------------------------------------------------------- window

  @override
  void onWindowClose() {
    // Alt+F4 & co. never end the app: they hide the window.
    unawaited(mode.value == ShellMode.settings ? closeSettings() : hideOverlay());
  }

  @override
  void onWindowMoved() => _persistBounds();

  @override
  void onWindowResized() => _persistBounds();

  void _persistBounds() {
    if (mode.value != ShellMode.overlay) return;
    _saveBounds?.cancel();
    _saveBounds = Timer(const Duration(milliseconds: 400), _storeBounds);
  }

  Future<void> _storeBounds() async {
    if (mode.value != ShellMode.overlay) return;
    final b = await windowManager.getBounds();
    await service.updateDisplay(service.settings.copyWith(overlayBounds: b));
  }

  // ------------------------------------------------------------------- tray

  Future<void> _initTray() async {
    trayManager.addListener(this);
    await _updateTrayIcon();
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'toggle', label: 'Show / hide overlay'),
          MenuItem(key: 'settings', label: 'Settings…'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit mlwatcher'),
        ],
      ),
    );
  }

  void _updateTray() => unawaited(_updateTrayIcon());

  Future<void> _updateTrayIcon() async {
    try {
      final alert = service.error != null || service.hasUndismissedFailure;
      if (alert != _alertIcon) {
        _alertIcon = alert;
        final name = alert ? 'tray_icon_alert' : 'tray_icon';
        await trayManager.setIcon('assets/tray/$name.${Platform.isWindows ? 'ico' : 'png'}');
      }
      final tip = _trayTooltip();
      // Linux app indicators have no tooltip.
      if (!Platform.isLinux && tip != _tooltip) {
        _tooltip = tip;
        await trayManager.setToolTip(tip);
      }
    } catch (e) {
      debugPrint('Tray update failed: $e');
    }
  }

  String _trayTooltip() {
    if (!service.settings.isConfigured) return 'mlwatcher – not configured';
    if (service.error != null) return 'mlwatcher – ${service.error}';
    final runs = service.runs;
    final running = runs.where((r) => r.status.isActive).length;
    final failed = runs.where((r) => r.status.isFailure).length;
    return 'mlwatcher – $running running${failed > 0 ? ', $failed failed' : ''}';
  }

  @override
  void onTrayIconMouseDown() => unawaited(toggleOverlay());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'toggle':
        unawaited(toggleOverlay());
      case 'settings':
        unawaited(openSettings());
      case 'quit':
        unawaited(quit());
    }
  }
}
