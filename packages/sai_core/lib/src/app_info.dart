/// Version of the sai workspace. Bumped by hand before a release
/// (`tool/release.sh` reads the pubspecs, which must agree).
const String saiVersion = '0.0.1-dev.1';

/// Static facts about the running application, shared by every client.
class AppInfo {
  const AppInfo({required this.name, required this.version});

  final String name;
  final String version;

  @override
  String toString() => '$name $version';
}
