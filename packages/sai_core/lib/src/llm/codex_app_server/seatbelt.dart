/// The Seatbelt profile the App Server runs under (#26): the outer,
/// enforced boundary around a vendor agent runtime sai uses only as a
/// text-inference bridge. Closed by default; open for what login and
/// inference need and nothing else — its own binary, the system runtime,
/// its dedicated credential home, the per-call scratch directory, a
/// private temp root, the network, and the Keychain and trust services
/// its ChatGPT credential lives behind. The repository, sai's archive and
/// settings, and everything else in the home directory are dark to it,
/// and it may start no other program: a shell a model asks for fails at
/// exec, before sai's own fail-closed interrupt even lands.
///
/// Honest boundary (ADR 0013): the child must reach the Keychain for its
/// own `Codex Auth` item, and a process running as the user can in
/// principle reach other user-granted items through that service. What
/// this profile enforces is the file system and process boundary; the
/// credential boundary is that sai holds no token and the child inherits
/// no key.
///
/// Parameters (`sandbox-exec -D`): `SIDECAR`, `CODEX_HOME`, `SCRATCH`,
/// `TMP`, `KEYCHAINS` (the user's `~/Library/Keychains`).
const seatbeltProfile = '''
(version 1)
(deny default)

; The runtime itself, and only it.
(allow process-exec (literal (param "SIDECAR")))
(allow process-fork)
(allow signal (target same-sandbox))
(allow process-info* (target same-sandbox))

; The system runtime, read-only.
(allow file-read*
  (subpath "/usr/lib")
  (subpath "/usr/share")
  (subpath "/System")
  (subpath "/Library/Frameworks")
  (subpath "/Library/Preferences")
  (subpath "/Library/Keychains")
  (subpath "/private/var/db/mds")
  (subpath "/private/var/db/dyld")
  (subpath "/private/var/db/timezone")
  (subpath "/private/etc")
  (literal "/etc")
  (literal "/private")
  (literal "/private/var")
  (literal "/var")
  (literal "/dev/urandom")
  (literal "/dev/random")
  (literal "/dev/null")
  (literal (param "SIDECAR")))
(allow file-read-metadata)
(allow file-write-data (literal "/dev/null"))
(allow file-read* file-write* (literal "/dev/dtracehelper"))

; Its own places: the credential home, this call's scratch, a private
; temp root — and the login keychain its credential is filed in.
(allow file-read* file-write*
  (subpath (param "CODEX_HOME"))
  (subpath (param "SCRATCH"))
  (subpath (param "TMP"))
  (subpath (param "KEYCHAINS")))

; What a process needs to know about the machine.
(allow sysctl-read)
(allow mach-lookup
  (global-name "com.apple.system.opendirectoryd.libinfo")
  (global-name "com.apple.system.opendirectoryd.membership")
  (global-name "com.apple.bsd.dirhelper")
  (global-name "com.apple.system.notification_center")
  (global-name "com.apple.system.logger")
  (global-name "com.apple.diagnosticd")
  (global-name "com.apple.logd")
  (global-name "com.apple.SystemConfiguration.configd")
  (global-name "com.apple.SystemConfiguration.DNSConfiguration")
  (global-name "com.apple.networkd")
  (global-name "com.apple.nesessionmanager.content-filter")
  (global-name "com.apple.ocspd")
  (global-name "com.apple.trustd")
  (global-name "com.apple.trustd.agent")
  (global-name "com.apple.SecurityServer")
  (global-name "com.apple.securityd.xpc")
  (global-name "com.apple.securityd")
  (global-name "com.apple.security.cloudkeychainproxy3")
  (global-name "com.apple.cfprefsd.daemon")
  (global-name "com.apple.cfprefsd.agent"))
(allow ipc-posix-shm-read* (ipc-posix-name-prefix "apple.cfprefs."))
(allow user-preference-read)

; Login and inference go out; the browser sign-in comes back on the
; loopback callback the runtime hosts.
(allow network-outbound)
(allow network-inbound (local ip "localhost:*"))
(allow system-socket
  (require-all (socket-domain AF_SYSTEM) (socket-protocol 2)))
''';

/// The `sandbox-exec` argument vector that runs [sidecar] under the
/// profile with the given roots. The profile is passed inline (`-p`),
/// so no file on disk decides what the child may do; the roots are
/// parameters, so the profile text never varies per machine.
List<String> seatbeltArguments({
  required String sidecar,
  required String codexHome,
  required String scratch,
  required String tmp,
  required String keychains,
  required List<String> sidecarArguments,
}) => [
  '-p',
  seatbeltProfile,
  '-D',
  'SIDECAR=$sidecar',
  '-D',
  'CODEX_HOME=$codexHome',
  '-D',
  'SCRATCH=$scratch',
  '-D',
  'TMP=$tmp',
  '-D',
  'KEYCHAINS=$keychains',
  sidecar,
  ...sidecarArguments,
];

/// Where `sandbox-exec` lives on every macOS.
const sandboxExec = '/usr/bin/sandbox-exec';
