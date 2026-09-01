/// Every word the ChatGPT route can put in a failure or a status (#26).
/// Fixed text only, like `TransportText`: a failure line is permanent,
/// and the App Server's own messages, its stderr, a URL or an email must
/// never be quoted into it. Tests check that nothing else is written.
abstract final class CodexText {
  static const sidecarMissing =
      'the ChatGPT runtime is not in this build; install a stable release';
  static const inUse = 'ChatGPT is in use by another sai client';
  static const signedOut = 'not signed in to ChatGPT; sign in first';
  static const wrongAuth =
      'the ChatGPT runtime is signed in with something other than a '
      'ChatGPT account; sign out and sign in with ChatGPT';
  static const loginCancelled = 'the ChatGPT sign-in was cancelled';
  static const loginFailed = 'the ChatGPT sign-in did not complete';
  static const loginBusy = 'a ChatGPT sign-in is already in progress';
  static const chooseModel = 'choose a ChatGPT model first';
  static const modelUnavailable =
      'the chosen model is not in the ChatGPT model list; choose another';
  static const effortUnavailable =
      'the chosen model does not take this reasoning effort; choose '
      'another, or Model default';
  static const planLimit = 'the ChatGPT plan limit is reached for now';
  static const unauthorized = 'ChatGPT refused the request; sign in again';
  static const unsafe =
      'the ChatGPT runtime tried to act beyond answering; the turn was '
      'stopped';
  static const badLine =
      'the ChatGPT runtime sent a line that could not be read';
  static const lineTooLong =
      'the ChatGPT runtime sent a line that was too long';
  static const tooManyPending =
      'too many requests to the ChatGPT runtime at once';
  static const timeout = 'the ChatGPT runtime did not answer in time';
  static const childExited = 'the ChatGPT runtime stopped';
  static const startFailed = 'the ChatGPT runtime could not be started';
  static const overloaded = 'the ChatGPT runtime is overloaded; try again';
  static const devRefused =
      'the dev copy runs no ChatGPT runtime; use the stable copy';
  static const homeUnsafe =
      'the ChatGPT credential home could not be prepared safely';
  static const temperatureUnsupported =
      'ChatGPT takes no temperature; the request must not set one';
  static const errorPayload = 'ChatGPT answered with an error';
  static const rejected = 'ChatGPT refused the request';
  static const closed = 'the ChatGPT provider is closed';
  static const wrongHome =
      'the ChatGPT runtime opened another credential home than the one '
      'it was given';

  /// Everything above, for the tests that assert a message is one of
  /// these.
  static const all = {
    sidecarMissing,
    inUse,
    signedOut,
    wrongAuth,
    loginCancelled,
    loginFailed,
    loginBusy,
    chooseModel,
    modelUnavailable,
    effortUnavailable,
    planLimit,
    unauthorized,
    unsafe,
    badLine,
    lineTooLong,
    tooManyPending,
    timeout,
    childExited,
    startFailed,
    overloaded,
    devRefused,
    homeUnsafe,
    temperatureUnsupported,
    errorPayload,
    rejected,
    closed,
    wrongHome,
  };
}
