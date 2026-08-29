// The file is named after the command it becomes (`dart build cli` names
// the binary after the entry point), and the dev command is `sai_tui-dev`.
// ignore_for_file: file_names

import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/bootstrap.dart';

/// The dev terminal client: `sai_tui-dev`, its own archive, settings and
/// Keychain service beside stable's, never touching them (ADR 0019).
Future<void> main(List<String> args) =>
    runSaiTui(args, identity: SaiIdentity.dev);
