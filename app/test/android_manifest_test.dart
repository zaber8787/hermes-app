import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

/// NOTIF2 B2: the AndroidManifest deep-link filters are DEPLOYMENT CONFIG,
/// not a baked-in tailnet host. The manifest must carry namespace-correct
/// VIEW/DEFAULT/BROWSABLE HTTPS filters whose host/path come from build-time
/// placeholders; a missing filter, a wrong literal host or the forgotten
/// flutter_deeplinking_enabled opt-out is a RED build.

const _androidNs = 'http://schemas.android.com/apk/res/android';

XmlDocument _manifest() {
  final file = File('android/app/src/main/AndroidManifest.xml');
  expect(file.existsSync(), isTrue,
      reason: 'the AndroidManifest must exist to be judged');
  return XmlDocument.parse(file.readAsStringSync());
}

String? _attr(XmlElement e, String name) =>
    e.getAttribute(name, namespaceUri: _androidNs);

List<XmlElement> _filters(XmlDocument doc) =>
    doc.findAllElements('intent-filter').toList();

bool _isHttpsFilter(XmlElement f) => f
    .findAllElements('data')
    .any((d) => _attr(d, 'scheme') == 'https');

void main() {
  group('AndroidManifest deep-link filters (NOTIF2 B2)', () {
    test('MAIN/LAUNCHER survives', () {
      final mainFilters = _filters(_manifest()).where(
        (f) => f
            .findAllElements('action')
            .any((a) => _attr(a, 'name') == 'android.intent.action.MAIN'),
      );
      expect(mainFilters, isNotEmpty);
    });

    test('HTTPS App Link filters exist with the full VIEW contract', () {
      final doc = _manifest();
      final https = _filters(doc).where(_isHttpsFilter).toList();
      expect(https.length, greaterThanOrEqualTo(2),
          reason: 'one autoVerify filter plus the manual-association '
              'fallback filter');
      for (final f in https) {
        final actions =
            f.findAllElements('action').map((a) => _attr(a, 'name')).toList();
        final cats =
            f.findAllElements('category').map((c) => _attr(c, 'name')).toList();
        expect(actions, contains('android.intent.action.VIEW'));
        expect(cats, containsAll(['android.intent.category.DEFAULT',
            'android.intent.category.BROWSABLE']));
        for (final d in f.findAllElements('data')) {
          expect(_attr(d, 'scheme'), 'https');
          expect(_attr(d, 'host'), isNotNull);
        }
      }
      final verified = https
          .where((f) => _attr(f, 'autoVerify') == 'true')
          .toList();
      expect(verified.length, 1,
          reason: 'exactly one verified App Link filter; the fallback filter '
              'must NOT claim verification it cannot guarantee');
    });

    test('host/path are placeholders — no tailnet host is baked in', () {
      final doc = _manifest();
      final raw = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(raw, isNot(contains('tail592d86')));
      expect(raw, isNot(contains('.ts.net')));
      for (final d in _filters(doc).where(_isHttpsFilter).fold<List<XmlElement>>(
          [], (out, f) => out..addAll(f.findAllElements('data')))) {
        expect(_attr(d, 'host'), r'${deepLinkHost}');
        expect(_attr(d, 'pathPrefix'), r'${deepLinkPath}');
      }
    });

    test('hermes:// scheme filter is BROWSABLE and accepts every host/path',
        () {
      // TASK-DEEPLINKFIX R1: ntfy clicks use hermes://link/... because a
      // tailnet host never passes App Link verification.
      final scheme = _filters(_manifest())
          .where((f) => f
              .findAllElements('data')
              .any((d) => _attr(d, 'scheme') == 'hermes'))
          .toList();
      expect(scheme, hasLength(1));
      final f = scheme.single;
      expect(f.findAllElements('action').map((a) => _attr(a, 'name')),
          contains('android.intent.action.VIEW'));
      expect(
          f.findAllElements('category').map((c) => _attr(c, 'name')),
          containsAll(['android.intent.category.DEFAULT',
              'android.intent.category.BROWSABLE']));
      expect(_attr(f, 'autoVerify'), isNull,
          reason: 'a custom scheme has nothing to verify');
      final data = f.findAllElements('data').single;
      expect(_attr(data, 'host'), isNull, reason: 'host is eaten whole');
      expect(_attr(data, 'pathPrefix'), isNull, reason: 'path is eaten whole');
      expect(_attr(data, 'path'), isNull);
      expect(_attr(data, 'pathPattern'), isNull);
    });

    test('Flutter engine deep-linking is opted out (plugin owns the intent)',
        () {
      final meta = _manifest()
          .findAllElements('meta-data')
          .where((m) =>
              _attr(m, 'name') == 'flutter_deeplinking_enabled');
      expect(meta, isNotEmpty,
          reason: 'flutter_deeplinking_enabled=false keeps the engine and '
              'app_links from double-consuming the launch intent');
      expect(_attr(meta.single, 'value'), 'false');
    });
  });

  group('build-time wiring is REAL, not documented fiction', () {
    test('gradle consumes the placeholder keys from -P properties', () {
      final gradle =
          File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('deepLinkHost'));
      expect(gradle, contains('deepLinkPath'));
      expect(gradle, contains('deeplink.host'));
      expect(gradle, contains('deeplink.path'));
    });

    test('build_app.py actually passes the properties to the APK build', () {
      final py = File('../scripts/build_app.py').readAsStringSync();
      expect(py, contains('-Pdeeplink.host'));
      expect(py, contains('-Pdeeplink.path'));
      expect(py, contains('HERMES_APP_DEEPLINK_URL'));
    });
  });
}
