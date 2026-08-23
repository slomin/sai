/// Version of the sai workspace. Bumped by hand until a release process exists.
const String saiVersion = '2.0.0-dev';

/// Static facts about the running application, shared by every client.
class AppInfo {
  const AppInfo({required this.name, required this.version});

  final String name;
  final String version;

  @override
  String toString() => '$name $version';
}
