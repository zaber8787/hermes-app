import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'package:hermes_app/features/attachments/media_picker_sheet.dart';

/// AUDIT-02 regression: the permission transitions must reach VISIBLE UI,
/// not an eternal spinner — denied shows the settings entry, recoveries
/// (denied/limited/error → authorized) replace stale state.
class FakeMediaSource implements MediaSource {
  FakeMediaSource(this.permission);
  MediaPermission permission;
  bool failRange = false;
  int permissionCalls = 0, settingOpens = 0;

  @override
  Future<MediaPermission> requestPermission() async {
    permissionCalls++;
    return permission;
  }

  @override
  Future<List<AssetEntity>> getRange(int start, int end) async {
    if (failRange) throw StateError('asset read failed');
    return const []; // < pageSize → grid fully loaded, no paging sentinel
  }

  @override
  Future<void> openSetting() async {
    settingOpens++;
    permission = const MediaPermission(hasAccess: true);
  }

  @override
  Future<void> presentLimited() async {
    settingOpens++;
    permission = const MediaPermission(hasAccess: true);
  }
}

Future<FakeMediaSource> openGrid(WidgetTester tester, FakeMediaSource src) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MediaPickerSheet.debugGrid(
        scrollController: ScrollController(),
        source: src,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return src;
}

void main() {
  testWidgets('denied: spinner closes and the 去開權限 entry is visible', (
    tester,
  ) async {
    await openGrid(tester, FakeMediaSource(const MediaPermission(hasAccess: false)));
    expect(find.text('去開權限'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('需要相簿權限才能顯示縮圖'), findsOneWidget);
  });

  testWidgets('denied → authorized via 去開權限 renders the grid', (tester) async {
    final src = FakeMediaSource(const MediaPermission(hasAccess: false));
    await openGrid(tester, src);
    expect(find.text('去開權限'), findsOneWidget);
    await tester.tap(find.text('去開權限')); // openSetting → permission granted
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('去開權限'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(src.settingOpens, 1);
  });

  testWidgets('limited → authorized removes the stale limited banner', (
    tester,
  ) async {
    final src = FakeMediaSource(
      const MediaPermission(hasAccess: true, isLimited: true),
    );
    await openGrid(tester, src);
    expect(find.text('選更多'), findsOneWidget);
    await tester.tap(find.text('選更多'));
    await tester.pumpAndSettle();
    expect(find.text('選更多'), findsNothing); // AUDIT-02: no stale _limited
    expect(find.byType(GridView), findsOneWidget);
  });

  testWidgets('read error → 重試 → success shows grid, not spinner', (
    tester,
  ) async {
    final src = FakeMediaSource(const MediaPermission(hasAccess: true))
      ..failRange = true;
    await openGrid(tester, src);
    expect(find.text('讀取相簿失敗'), findsOneWidget);
    expect(find.text('重試'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    src.failRange = false;
    await tester.tap(find.text('重試'));
    await tester.pumpAndSettle();
    expect(find.text('讀取相簿失敗'), findsNothing);
    expect(find.byType(GridView), findsOneWidget);
  });

  testWidgets('a retried load that comes back denied sheds the stale grant', (
    tester,
  ) async {
    // error state → permission revoked → 重試: the SAME _load() must land in
    // the denial UI with a closed spinner, not a stale grid or a spinner.
    final src = FakeMediaSource(const MediaPermission(hasAccess: true))
      ..failRange = true;
    await openGrid(tester, src);
    expect(find.text('重試'), findsOneWidget);
    src.permission = const MediaPermission(hasAccess: false);
    await tester.tap(find.text('重試'));
    await tester.pumpAndSettle();
    expect(find.text('去開權限'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('讀取相簿失敗'), findsNothing);
  });
}
