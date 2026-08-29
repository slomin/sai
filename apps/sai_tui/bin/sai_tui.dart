import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/bootstrap.dart';

/// The stable terminal client: `~/.local/bin/sai_tui`, the daily copy's
/// archive, settings and Keychain service (ADR 0019).
Future<void> main(List<String> args) =>
    runSaiTui(args, identity: SaiIdentity.stable);
