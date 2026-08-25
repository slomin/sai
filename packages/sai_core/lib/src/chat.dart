/// The conversation (#34): one transcript per client process, held as
/// riverpod state so both clients render the same thing, and every turn
/// written to the archive as `chat.message` beside the call's own lines.
library;

export 'chat/chat.dart';
