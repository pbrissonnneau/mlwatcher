import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-user "start at login" registration; never needs admin/root rights.
///
/// Windows: `HKCU\...\Run` value pointing at the current executable (moving
/// the folder requires enabling it again). Linux: XDG autostart entry.
abstract final class Autostart {
  static const _name = 'mlwatcher';
  static const _winRunKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  static bool get isSupported => Platform.isWindows || Platform.isLinux;

  static Future<bool> isEnabled() async {
    try {
      if (Platform.isLinux) return await File(_linuxDesktopFile).exists();
      if (Platform.isWindows) {
        final r = await Process.run('reg', ['query', _winRunKey, '/v', _name]);
        return r.exitCode == 0 && r.stdout.toString().contains(Platform.resolvedExecutable);
      }
    } catch (_) {}
    return false;
  }

  static Future<void> setEnabled(bool enabled) async {
    final exe = Platform.resolvedExecutable;
    if (Platform.isLinux) {
      final f = File(_linuxDesktopFile);
      if (enabled) {
        await f.parent.create(recursive: true);
        await f.writeAsString(
          '[Desktop Entry]\n'
          'Type=Application\n'
          'Name=mlwatcher\n'
          'Comment=MLflow run watcher overlay\n'
          'Exec="$exe"\n'
          'X-GNOME-Autostart-enabled=true\n'
          'NoDisplay=true\n',
        );
      } else if (await f.exists()) {
        await f.delete();
      }
    } else if (Platform.isWindows) {
      final r = enabled
          ? await Process.run('reg', ['add', _winRunKey, '/v', _name, '/t', 'REG_SZ', '/d', '"$exe"', '/f'])
          : await Process.run('reg', ['delete', _winRunKey, '/v', _name, '/f']);
      // Deleting a value that does not exist is fine.
      if (enabled && r.exitCode != 0) throw ProcessException('reg', const [], r.stderr.toString(), r.exitCode);
    }
  }

  static String get _linuxDesktopFile {
    final config = Platform.environment['XDG_CONFIG_HOME'] ?? p.join(Platform.environment['HOME'] ?? '.', '.config');
    return p.join(config, 'autostart', 'mlwatcher.desktop');
  }
}
