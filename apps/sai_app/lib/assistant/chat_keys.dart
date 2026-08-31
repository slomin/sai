/// The assistant band's widget keys — one place, so the band, the
/// composer (#39) and the tests find the same widgets.
/// `assistant_band.dart` re-exports them.
library;

import 'package:flutter/widgets.dart';

/// The chat pane's input, so tests and Cmd+J can find it.
const chatFieldKey = Key('chat-field');

/// The transcript list.
const chatTranscriptKey = Key('chat-transcript');

/// The waiting dots, between the question and the first delta (#99).
const chatWaitingKey = Key('chat-waiting');

/// A reasoning block, when shown.
const chatReasoningKey = Key('chat-reasoning');

/// The button that sends the draft, and the one that stops an answer.
const chatSendKey = Key('chat-send');
const chatStopKey = Key('chat-stop');

/// The band's header, which also toggles it.
const assistantHeaderKey = Key('assistant-header');

/// The connection light and its word (#40).
const connectionDotKey = Key('connection-dot');
const connectionTextKey = Key('connection-text');

/// The composer's propose button (#35).
const chatProposeKey = Key('chat-propose');

/// The suggestion lane (#35) and its per-card controls.
const suggestionLaneKey = Key('suggestion-lane');

Key suggestionCardKey(int index) => Key('suggestion-card-$index');
Key suggestionAcceptKey(int index) => Key('suggestion-accept-$index');
Key suggestionRejectKey(int index) => Key('suggestion-reject-$index');
