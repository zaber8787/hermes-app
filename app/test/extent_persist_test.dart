// EXTENT-PERSIST contract: measured row heights round-trip through the
// store; corrupt or absurd values read back as "no memory", never garbage.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_app/features/settings/local_store.dart';

void main() {
  test('extents round-trip per session and stay separated', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    await store.saveRowExtents(
      'https://a.example',
      's1',
      {'entry:user:m1': 240.5, 'entry:tool:t1': 88.0},
    );
    final got = store.rowExtents('https://a.example', 's1');
    expect(got['entry:user:m1'], 240.5);
    expect(store.rowExtents('https://a.example', 's2'), isEmpty);
    expect(store.rowExtents('https://b.example', 's1'), isEmpty);
  });

  test('absurd heights are dropped, corrupt json reads empty', () async {
    SharedPreferences.setMockInitialValues({
      'extents.https://a.example|sX': '{bad json',
      'extents.https://a.example|sY': '{"k1": -5, "k2": 90000, "k3": 300}',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(store.rowExtents('https://a.example', 'sX'), isEmpty);
    final y = store.rowExtents('https://a.example', 'sY');
    expect(y.keys, ['k3']);
  });
}
