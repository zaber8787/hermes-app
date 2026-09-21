// Dart twin of scripts/runtime_config.py for the live tools (ENVHYGIENE §3.1).
// Same selector chain, same strict parsing, same "never print values".
// ignore_for_file: avoid_print
import 'dart:io';

class ConfigException implements Exception {
  final String message;
  ConfigException(this.message);
  @override
  String toString() => 'ConfigException: $message';
}

class RuntimeConfig {
  RuntimeConfig({Map<String, String>? environ, Directory? home})
    : env = environ ?? Platform.environment,
      homeDir = home?.path ?? (Platform.environment['HOME'] ?? '') {
    path = _select(env, homeDir);
    if (File(path).existsSync()) {
      _values = _parse(File(path).readAsStringSync());
    } else if (_selectorSet(env)) {
      throw ConfigException('selected env file is missing');
    }
  }

  final Map<String, String> env;
  final String homeDir;
  late final String path;
  Map<String, String> _values = const {};

  static bool _selectorSet(Map<String, String> e) =>
      (e['HERMES_ENV_FILE'] ?? '').trim().isNotEmpty ||
      (e['HERMES_WEB_ENV'] ?? '').trim().isNotEmpty;

  static String _select(Map<String, String> e, String home) {
    final picks = <String>[];
    for (final name in ['HERMES_ENV_FILE', 'HERMES_WEB_ENV']) {
      final raw = (e[name] ?? '').trim();
      if (raw.isEmpty) continue;
      final expanded = raw.startsWith('~/')
          ? '$home/${raw.substring(2)}'
          : raw;
      picks.add(File(expanded).absolute.path);
    }
    if (picks.length == 2 && picks[0] != picks[1]) {
      throw ConfigException(
        'HERMES_ENV_FILE and HERMES_WEB_ENV resolve to different files',
      );
    }
    if (picks.isNotEmpty) return picks.first;
    return '$home/.hermes/.env';
  }

  static final _assign = RegExp(r'^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$');

  /// Strict single-line dotenv: comments, export prefix, paired quotes,
  /// `#` after unquoted values; duplicates/unbalanced quotes are errors.
  static Map<String, String> _parse(String text) {
    final out = <String, String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      var value = '';
      final quote = _strip(line);
      if (quote == null) continue; // not an assignment line
      final name = quote.$1, tail = quote.$2;
      value = tail.trim();
      if (value.isNotEmpty && (value[0] == '"' || value[0] == "'")) {
        if (value.length < 2 || value[value.length - 1] != value[0]) {
          throw ConfigException('unbalanced quotes for $name');
        }
        value = value.substring(1, value.length - 1);
      }
      if (out.containsKey(name)) {
        throw ConfigException('variable $name defined more than once');
      }
      out[name] = value;
    }
    return out;
  }

  static (String, String)? _strip(String line) {
    final m = _assign.firstMatch(line);
    if (m == null) return null;
    // cut an end-of-line comment that sits OUTSIDE quotes
    final tail = m.group(2)!;
    String? q;
    final buf = StringBuffer();
    for (final ch in tail.split('')) {
      if (q != null) {
        buf.write(ch);
        if (ch == q) q = null;
      } else if (ch == '"' || ch == "'") {
        q = ch;
        buf.write(ch);
      } else if (ch == '#') {
        break;
      } else {
        buf.write(ch);
      }
    }
    if (q != null) throw ConfigException('unbalanced quotes');
    return (m.group(1)!, buf.toString());
  }

  String resolve(String name, {String? def, bool required = false}) {
    final fromEnv = (env[name] ?? '').trim();
    if (name == 'API_SERVER_KEY') {
      final value = (_values[name] ?? '').trim();
      if (value.isEmpty) {
        if (required) throw ConfigException('$name is not configured');
        return def ?? '';
      }
      return value;
    }
    if (fromEnv.isNotEmpty) return fromEnv;
    final value = (_values[name] ?? '').trim();
    if (value.isNotEmpty) return value;
    if (required || def == null) {
      throw ConfigException('$name is not configured');
    }
    return def;
  }

  /// http(s), host, no userinfo/query/fragment, port in range, no path;
  /// trailing '/' removed.
  static String validateUrl(String value, {required String name}) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw ConfigException('$name: needs an http(s) origin URL');
    }
    return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  }

  String liveBaseUrl() =>
      validateUrl(resolve('HERMES_LIVE_BASE_URL', required: true),
          name: 'HERMES_LIVE_BASE_URL');

  String apiKey() => resolve('API_SERVER_KEY', required: true);
}
