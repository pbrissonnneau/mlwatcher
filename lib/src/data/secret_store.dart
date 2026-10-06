import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Stores the MLflow password / token.
///
/// * Windows: encrypted with DPAPI for the current Windows user
///   (`CryptProtectData`); the file is useless on another account or machine.
/// * Linux: plain file readable only by the user (mode 600).
class SecretStore {
  SecretStore(this.dir);

  final Directory dir;

  File get _file => File(p.join(dir.path, Platform.isWindows ? 'secret.dpapi' : 'secret'));

  Future<String> read() async {
    try {
      final bytes = await _file.readAsBytes();
      if (bytes.isEmpty) return '';
      return utf8.decode(Platform.isWindows ? _Dpapi.unprotect(bytes) : bytes);
    } catch (_) {
      return '';
    }
  }

  Future<void> write(String secret) async {
    if (secret.isEmpty) {
      if (await _file.exists()) await _file.delete();
      return;
    }
    await dir.create(recursive: true);
    final raw = Uint8List.fromList(utf8.encode(secret));
    if (Platform.isWindows) {
      await _file.writeAsBytes(_Dpapi.protect(raw), flush: true);
    } else {
      // Create empty and restrict before writing the secret.
      await _file.writeAsBytes(const [], flush: true);
      await Process.run('chmod', ['600', _file.path]);
      await _file.writeAsBytes(raw, flush: true);
    }
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Void> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_DataBlob> dataOut,
);
typedef _CryptDart = int Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Void> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_DataBlob> dataOut,
);

/// Windows Data Protection API (current-user scope).
abstract final class _Dpapi {
  static const _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN

  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _protect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
  static final _unprotect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptUnprotectData');
  static final _localFree = _kernel32
      .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');

  static Uint8List protect(Uint8List data) => _run(_protect, data);
  static Uint8List unprotect(Uint8List data) => _run(_unprotect, data);

  static Uint8List _run(_CryptDart fn, Uint8List data) {
    return using((arena) {
      final input = arena<_DataBlob>();
      final output = arena<_DataBlob>();
      final buffer = arena<Uint8>(data.length);
      buffer.asTypedList(data.length).setAll(0, data);
      input.ref
        ..cbData = data.length
        ..pbData = buffer;
      final ok = fn(input, nullptr, nullptr, nullptr, nullptr, _uiForbidden, output);
      if (ok == 0) throw const FileSystemException('DPAPI call failed');
      try {
        return Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      } finally {
        _localFree(output.ref.pbData.cast());
      }
    });
  }
}
