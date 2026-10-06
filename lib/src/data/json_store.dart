import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/watched_run.dart';
import 'settings.dart';

/// Small JSON files in the per-user application data directory.
class JsonStore {
  JsonStore(this.dir);

  final Directory dir;

  File get _settingsFile => File(p.join(dir.path, 'settings.json'));
  File get _stateFile => File(p.join(dir.path, 'state.json'));

  Future<Settings> loadSettings() async {
    final j = await _read(_settingsFile);
    return j == null ? const Settings() : Settings.fromJson(j);
  }

  Future<void> saveSettings(Settings s) => _write(_settingsFile, s.toJson());

  /// Shown runs and dismissed ids, so they survive a restart.
  Future<(List<WatchedRun>, Map<String, int>)> loadState() async {
    final j = await _read(_stateFile);
    if (j == null) return (const <WatchedRun>[], const <String, int>{});
    final runs = [for (final r in (j['runs'] as List?) ?? const []) ?WatchedRun.fromJson(r)];
    final dismissed = <String, int>{
      for (final MapEntry(:key, :value) in ((j['dismissed'] as Map?) ?? const {}).entries)
        if (key is String && value is num) key: value.toInt(),
    };
    return (runs, dismissed);
  }

  Future<void> saveState(List<WatchedRun> runs, Map<String, int> dismissed) => _write(_stateFile, {
    'runs': [for (final r in runs) r.toJson()],
    'dismissed': dismissed,
  });

  Future<Map<String, Object?>?> _read(File f) async {
    try {
      final j = jsonDecode(await f.readAsString());
      return j is Map ? j.cast<String, Object?>() : null;
    } catch (_) {
      return null; // Missing or corrupt: start from defaults.
    }
  }

  /// Write-then-rename so a crash never leaves a truncated file.
  Future<void> _write(File f, Object json) async {
    await dir.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(json), flush: true);
    await tmp.rename(f.path);
  }
}
