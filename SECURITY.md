# Security Policy

## Reporting a vulnerability

Please report security issues **privately** rather than opening a public issue.

- Use GitHub's [private vulnerability reporting](https://github.com/JonathanRReed/Waves/security/advisories/new) for this repository, or
- Email the maintainer listed on the GitHub profile.

Please include:

- A description of the issue and its impact.
- Steps to reproduce (a `Copy Diagnostics` export from Waves › Settings ›
  Diagnostics is helpful and contains no audio samples, but review it first
  because it may include app/device names or identifiers, route and permission
  states, persistence/cleanup status, and bounded error text).
- Affected version and macOS version.

You can expect an acknowledgement within a few days. Please give a reasonable
window to address the issue before any public disclosure.

## Scope notes

Waves is a non-sandboxed utility that uses Core Audio process taps (which require
audio-capture permission) and an opt-in `waves://` URL automation scheme that is
**off by default**. Security reports touching audio capture, the URL scheme, the
login item, or local file handling are especially welcome.
