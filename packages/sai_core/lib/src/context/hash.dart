import 'dart:convert';

import '../archive/blobref.dart';
import '../llm/call.dart';

/// The blobref of [messages] as sent: sha256 over the compact JSON of
/// `[{role, text}, …]`, in order. Recorded on every `provider.request`
/// line as `context_hash`, so a response can be traced to exactly what
/// the model saw — after the privacy policy, not before (ADR 0011).
BlobRef contextHash(List<LlmMessage> messages) => BlobRef.sha256OfBytes(
  utf8.encode(jsonEncode([for (final m in messages) m.toJson()])),
);
