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
/// address. Plaintext HTTP is allowed to nothing else.
bool isLoopbackHost(String host) =>
    host == 'localhost' ||
    (InternetAddress.tryParse(host)?.isLoopback ?? false);

/// The one line every client shows for a plaintext endpoint that is not
/// local.
const plaintextRefused = 'plaintext http is allowed only for localhost';
