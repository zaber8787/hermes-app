/// Shared server-URL validation (ENVHYGIENE §4.1.2): the settings form and
/// the app-wide `configured` gate MUST agree — a relative or junk URL may
/// never reach a repository, no matter which code path checks.
///
/// Returns the normalised URL (exactly one trailing '/' removed) or the
/// empty string when invalid. Rules match the historic SettingsPage form:
/// http(s) scheme, non-empty host, port (explicit or scheme default)
/// 1..65535, no userinfo, no query, no fragment.
String normalizeServerUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return '';
  }
  if (!(1 <= uri.port && uri.port <= 65535)) return '';
  return value.replaceFirst(RegExp(r'/$'), '');
}

bool isValidServerUrl(String raw) => normalizeServerUrl(raw).isNotEmpty;
