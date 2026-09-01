import 'package:flutter/services.dart';

/// The Runner's browser channel (#26): opens a public `https:` URL in the
/// person's default browser through `NSWorkspace`. The app never spawns
/// `open`; the Runner owns the hand-off, as it owns the Finder panels.
const browserChannel = MethodChannel('sai/browser');

/// Opens [url] in the default browser. Only `https:` is passed on — the
/// ChatGPT sign-in URL the App Server answers is one, and nothing else
/// asks. Answers false without a Runner behind the channel (tests, other
/// hosts), so a caller can show the URL instead.
Future<bool> openInBrowser(Uri url) async {
  if (url.scheme != 'https') return false;
  try {
    return await browserChannel.invokeMethod<bool>('openUrl', '$url') ?? false;
  } on MissingPluginException {
    return false;
  }
}
