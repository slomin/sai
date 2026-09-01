/// Test doubles for the process boundary (#26): a scripted
/// [ProcessRunner] that records every spawn and drives a fake child, and
/// a scripted App Server that answers the pinned protocol from state a
/// test sets. Nothing here starts a process; `no_spawn_test` pins that
/// nothing under `test/` could start the real binary against a real home.
library;

export 'src/llm/codex_app_server/testing/fake_app_server.dart';
export 'src/process/runner.dart';
export 'src/process/testing/scripted_runner.dart';
