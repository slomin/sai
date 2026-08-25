import 'dart:io';

/// What an endpoint URL is reduced to wherever it is compared or written
/// down: `scheme://host[:port]`. A key is bound to this (ADR 0009), and a
/// failure line names this — never a path, userinfo, query or fragment.
String endpointOrigin(Uri endpoint) => Uri(
  scheme: endpoint.scheme,
  host: endpoint.host,
  port: endpoint.hasPort ? endpoint.port : null,
).toString();

/// Whether [host] can only be this machine: `localhost` or a loopback
/// address.
bool isLoopbackHost(String host) =>
    host == 'localhost' ||
    (InternetAddress.tryParse(host)?.isLoopback ?? false);

/// Whether [host] is on this machine or the local network, as far as a
/// name or address can say: loopback, a private (RFC 1918), link-local,
/// CGNAT or unique-local address, a `.local`/`.lan`/`.home`/`.internal`
/// name, or a name without a dot. Plaintext HTTP is allowed to these and
/// nothing else (ADR 0012). What this says nothing about is where the
/// inference happens — a tunnel can hide a cloud behind a LAN name — so
/// for the privacy tag it is a default, and `privacy` in the
/// configuration overrides it (ADR 0010).
bool isPrivateHost(String host) {
  if (isLoopbackHost(host)) return true;
  final address = InternetAddress.tryParse(host);
  if (address != null) return _isPrivateAddress(address);
  final name = host.toLowerCase();
  if (!name.contains('.')) return true;
  return _privateSuffixes.any(name.endsWith);
}

const _privateSuffixes = ['.local', '.lan', '.home', '.internal', '.home.arpa'];

bool _isPrivateAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }
  // fc00::/7 (unique local), fe80::/10 (link local).
  return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80);
}

/// The one line every client shows for a plaintext endpoint that is
/// neither this machine nor the LAN.
const plaintextRefused =
    'plaintext http is allowed only on this machine or the LAN';
