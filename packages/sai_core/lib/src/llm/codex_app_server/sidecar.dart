import 'dart:io';

import 'package:path/path.dart' as p;

/// The bundled App Server executable (#26): never discovered on the
/// machine, never downloaded at run time — the release puts one exact,
/// checksum-verified, signed copy beside each client, and this is where
/// each client finds its own. The app carries a universal binary under
/// `Contents/Helpers/`; the terminal client's bundle carries the host
/// slice under `libexec/`, found the way its SQLite library is: beside
/// the resolved executable. Tests hand in a path of their own.
final class SidecarLocator {
  const SidecarLocator(this.executable);

  /// The absolute path of the `codex-app-server` binary.
  final String executable;

  /// The file name the release tooling places, in both bundles.
  static const fileName = 'codex-app-server';

  /// The locations relative to the running executable's directory:
  /// `Contents/MacOS/<app>` → `Contents/Helpers/`, and
  /// `bundle/bin/<tui>` → `bundle/libexec/`.
  static const relativeDirs = ['../Helpers', '../libexec'];

  /// The sidecar beside [resolvedExecutable] (`Platform.resolvedExecutable`
  /// in production), or null when neither place holds one — a dev build,
  /// a `dart run`, a tree the release never prepared.
  static SidecarLocator? beside(String resolvedExecutable) {
    final dir = p.dirname(resolvedExecutable);
    for (final rel in relativeDirs) {
      final candidate = p.normalize(p.join(dir, rel, fileName));
      if (File(candidate).existsSync()) return SidecarLocator(candidate);
    }
    return null;
  }

  /// Whether the binary is there to be started. Its integrity is the
  /// release's: sealed in the manifest and covered by the code signature
  /// the installer verifies; nothing here executes it to ask.
  bool get exists => File(executable).existsSync();
}
