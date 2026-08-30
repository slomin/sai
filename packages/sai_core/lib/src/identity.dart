/// Which installed sai this process is (ADR 0019). Two flavors exist and
/// no third: `stable` is the daily-use copy, `dev` the isolated
/// development and QA copy. Everything that names a location — the data
/// directory, the Keychain service, the bundle, the terminal command —
/// derives from the identity, so the two never share a byte of state.
///
/// Stable's values are exactly what sai used before flavors existed, so
/// an existing installation needs no migration.
enum SaiIdentity {
  stable(
    displayName: 'sai',
    slug: 'sai',
    bundleId: 'me.slominski.sai',
    tuiCommand: 'sai_tui',
  ),
  dev(
    displayName: 'sai dev',
    slug: 'sai-dev',
    bundleId: 'me.slominski.sai.dev',
    tuiCommand: 'sai_tui-dev',
  );

  const SaiIdentity({
    required this.displayName,
    required this.slug,
    required this.bundleId,
    required this.tuiCommand,
  });

  /// What a person sees: the window title, the app menu, the greeting.
  /// (The enum's own [name] — `stable`, `dev` — is the flavor.)
  final String displayName;

  /// What the file system sees: the data directory, the app bundle
  /// (`<slug>.app`), the local bundle directory, kept-release names.
  final String slug;

  /// The macOS bundle identifier; stable's Keychain service too (ADR 0008).
  final String bundleId;

  /// The terminal client's command name and its executable.
  final String tuiCommand;

  /// The Flutter flavor / Xcode scheme name, and what the release tooling
  /// writes into a staged artifact's `flavor` seal: the enum's own name.
  String get flavor => name;

  /// The Keychain `service` this flavor's credentials are filed under —
  /// stable's bundle id. Dev has none (#95, ADR 0019): its builds carry
  /// no stable signing authority, so they hold no persistent credentials
  /// either; a credentialed provider is unavailable there.
  String? get keychainService => isDev ? null : bundleId;

  /// The directory under `Application Support` (or `$XDG_DATA_HOME`).
  String get dataDirName => slug;

  /// The app bundle's file name and its executable's name.
  String get appBundle => '$slug.app';
  String get appExecutable => slug;

  bool get isDev => this == dev;

  /// The identity a Flutter build reports through `appFlavor`. A build
  /// with no flavor is deliberately dev: nothing accidental may look like
  /// the daily-use copy. Any other name is an error, not a third flavor.
  static SaiIdentity fromFlavor(String? flavor) {
    switch (flavor) {
      case null:
      case '':
      case 'dev':
        return dev;
      case 'stable':
        return stable;
      default:
        throw StateError('unknown sai flavor "$flavor" (stable or dev)');
    }
  }
}
