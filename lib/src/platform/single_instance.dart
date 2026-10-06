import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Keeps a single mlwatcher process per user, without sockets.
///
/// The running instance holds an exclusive OS file lock (released by the OS
/// when the process exits or crashes). A second launch drops a request file
/// into the inbox and quits; the running instance then shows its overlay.
class SingleInstance {
  SingleInstance(this.dir);

  final Directory dir;
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _poll;
  final _showRequests = StreamController<void>.broadcast();

  /// Kept strongly reachable: a collected RandomAccessFile closes its
  /// descriptor, which silently drops the lock.
  static final List<RandomAccessFile> _held = [];

  File get _lockFile => File(p.join(dir.path, 'instance.lock'));
  Directory get _inbox => Directory(p.join(dir.path, 'inbox'));

  /// Requests from later launches to show the overlay.
  Stream<void> get showRequests => _showRequests.stream;

  /// Whether this process became the single instance.
  Future<bool> tryAcquire() async {
    await dir.create(recursive: true);
    final raf = await _lockFile.open(mode: FileMode.append);
    try {
      await raf.lock(FileLock.exclusive);
      _held.add(raf);
      return true;
    } on FileSystemException {
      await raf.close();
      return false;
    }
  }

  /// Asks the running instance to show itself.
  Future<void> signalRunningInstance() async {
    await _inbox.create(recursive: true);
    final name = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    final tmp = File(p.join(_inbox.path, '$name.tmp'));
    await tmp.writeAsString('show', flush: true);
    await tmp.rename(p.join(_inbox.path, '$name.req')); // Atomic publish.
  }

  Future<void> listen() async {
    await _inbox.create(recursive: true);
    try {
      _watch = _inbox.watch(events: FileSystemEvent.create | FileSystemEvent.move).listen((_) => _drain());
    } catch (_) {
      // Watching unsupported: the polling below still works.
    }
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _drain());
    await _drain();
  }

  Future<void> _drain() async {
    try {
      final requests = await _inbox.list().where((e) => e is File && e.path.endsWith('.req')).toList();
      for (final f in requests) {
        try {
          await f.delete();
        } catch (_) {}
      }
      if (requests.isNotEmpty) _showRequests.add(null);
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _watch?.cancel();
    _poll?.cancel();
    await _showRequests.close();
  }
}
