import 'dart:io';

/// An exclusive, advisory, per-process file lock (#26): what keeps the
/// macOS app and the terminal client from running two App Servers on
/// one credential home at once — one refresh token family, one owner.
/// Never blocking: a lock that is held answers null at once, and the
/// caller says so in fixed words. A crashed holder leaves the file, not
/// the lock — POSIX locks die with their process.
final class ExclusiveLock {
  ExclusiveLock._(this.file, this._handle);

  /// The lock file, kept where the credential home is.
  final File file;
  final RandomAccessFile _handle;
  var _released = false;

  /// Takes the lock on [file], creating it, or answers null when another
  /// process holds it (or the file cannot be opened at all).
  static Future<ExclusiveLock?> tryAcquire(File file) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      return ExclusiveLock._(file, handle);
    } on FileSystemException {
      await handle?.close();
      return null;
    }
  }

  bool get isHeld => !_released;

  /// Lets the lock go; idempotent.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _handle.unlock();
    } on FileSystemException {
      // Closing releases it regardless.
    }
    await _handle.close();
  }
}
