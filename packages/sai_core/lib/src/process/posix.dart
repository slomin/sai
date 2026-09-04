import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _ChmodC = Int32 Function(Pointer<Utf8> path, Uint32 mode);
typedef _ChmodDart = int Function(Pointer<Utf8> path, int mode);

/// POSIX `chmod`, for the credential home's 0700/0600 (#26): `dart:io`
/// creates files under the umask and offers no way to tighten them, so
/// the C library is asked directly. Only where there is one: on another
/// platform the call is a no-op and the caller checks the mode it got.
bool posixChmod(String path, int mode) {
  if (!Platform.isMacOS && !Platform.isLinux) return false;
  final chmod = DynamicLibrary.process().lookupFunction<_ChmodC, _ChmodDart>(
    'chmod',
  );
  final native = path.toNativeUtf8();
  try {
    return chmod(native, mode) == 0;
  } finally {
    malloc.free(native);
  }
}
