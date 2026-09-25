import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart';
import 'package:hermes_app/features/attachments/attachment.dart';
import 'package:hermes_app/features/attachments/attachment_controller.dart';
import 'package:hermes_app/features/attachments/draft_store.dart';
import 'package:hermes_app/features/attachments/gallery_picker_web.dart'
    as web_gallery;
import 'package:hermes_app/features/attachments/picker_session.dart';
import 'package:hermes_app/features/chat/chat_page.dart';
import 'package:hermes_app/features/settings/local_store.dart';
import 'package:hermes_app/l10n/catalog.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/localized_app.dart';

/// Controller integration for the iOS picker fix (IOS-PICKER-PLAN C1).
/// FakeSession mirrors the production session contract: one outcome, abort
/// discards later events, focus forwards only the wake-up hint.

class FakeSession implements PickerSession {
  final Completer<PickerOutcome> _out = Completer();
  int aborts = 0;
  bool aborted = false;
  void Function()? hint;

  @override
  Future<PickerOutcome> get outcome => _out.future;

  @override
  void abort() {
    aborts++;
    aborted = true;
  }

  @override
  set onFocusHint(void Function()? h) => hint = h;

  void focus() => hint?.call();

  void deliver(PickerOutcome o) {
    if (aborted || _out.isCompleted) return;
    _out.complete(o);
  }
}

/// Memory DraftStore; the bytes map is the "blob" copy under test.
class MemBlobs implements DraftStore {
  final blobs = <String, List<int>>{};
  final failStage = <String>{};
  bool failAll = false;
  @override
  Future<String> stage(Stream<List<int>> source, String key) async {
    final bytes = <int>[];
    await for (final chunk in source) {
      bytes.addAll(chunk);
    }
    if (failAll || failStage.contains(key)) throw StateError('stage broken');
    blobs[key] = bytes;
    return 'blob:$key';
  }

  @override
  Future<void> discard(String ref) async =>
      blobs.remove(ref.replaceFirst('blob:', ''));

  @override
  Future<AttachmentSource> open(String ref) async {
    final bytes = blobs[ref.replaceFirst('blob:', '')]!;
    return StreamAttachmentSource(() => Stream.value(bytes), bytes.length);
  }
}

class CountedItem {
  CountedItem(this.name, this.bytes, {this.errorAfter, this.knownSize});
  final String name;
  final List<int> bytes;
  final Object? errorAfter;
  final int? knownSize;
  int opens = 0;

  PickedAttachment get attachment => PickedAttachment(
    name: name,
    knownSize: knownSize,
    openStream: () {
      opens++;
      if (errorAfter == null) return Stream.value(bytes);
      final c = StreamController<List<int>>();
      c.add(bytes);
      c.addError(errorAfter!);
      unawaited(c.close());
      return c.stream;
    },
  );
}

/// A picked file whose read never ends until its subscription is cancelled
/// (the slow iCloud provider of PLAN B3/H5).
class HangingItem {
  HangingItem(this.name);
  final String name;
  bool cancelled = false;
  int opens = 0;
  late final StreamController<List<int>> ctrl = StreamController<List<int>>(
    onCancel: () => cancelled = true,
  );

  PickedAttachment get attachment {
    return PickedAttachment(
      name: name,
      openStream: () {
        opens++;
        return ctrl.stream;
      },
    );
  }
}

/// DraftStore whose stage pauses after draining, on the way into the
/// atomic commit zone (PLAN B3 tail).
class GatedBlobs extends MemBlobs {
  final gate = Completer<void>();
  @override
  Future<String> stage(Stream<List<int>> source, String key) async {
    final bytes = <int>[];
    await for (final chunk in source) {
      bytes.addAll(chunk);
    }
    await gate.future;
    blobs[key] = bytes;
    return 'blob:$key';
  }
}

/// LocalStore whose prefs write pauses, so a test can end the pick WHILE
/// the commit is in flight.
class SlowSaveStore extends LocalStore {
  SlowSaveStore(super.prefs);
  final gate = Completer<void>();
  int saveCalls = 0;
  @override
  Future<void> saveAttachments(
    String server,
    String sid,
    List<AttachmentDraft> values,
  ) async {
    saveCalls++;
    await gate.future;
    await super.saveAttachments(server, sid, values);
  }
}

/// Controllable clock + manual timers: the deadline is an ABSOLUTE clock
/// question; timer callbacks only model the environment waking up (which
/// may be late or early — PLAN B3.7).
class FakeTime {
  DateTime now = DateTime(2026);
  final created = <FakeTimer>[];
  final live = <FakeTimer>{};

  Timer timer(Duration d, void Function() cb) {
    final t = FakeTimer._(cb, this);
    created.add(t);
    live.add(t);
    return t;
  }

  void advance(Duration d) => now = now.add(d);

  /// The environment delivers the most recent PENDING timer.
  void fireLatest() {
    live.lastWhere((x) => x.isActive).fire();
  }
}

class FakeTimer implements Timer {
  FakeTimer._(this._cb, this._owner);
  final void Function() _cb;
  final FakeTime _owner;
  bool _done = false;

  @override
  bool get isActive => !_done;

  @override
  int get tick => 0;

  @override
  void cancel() => _done = true;

  void fire() {
    if (!_done) {
      _done = true;
      _owner.live.remove(this);
      _cb();
    }
  }
}

void main() {
  late LocalStore store;
  late MemBlobs blobs;
  late AttachmentController controller;
  late FakeSession session;

  AttachmentController make() => AttachmentController(
    HermesRepository('http://fake.invalid', 'k'),
    store,
    's1',
    blobs: blobs,
    pickFactory: () => session,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    blobs = MemBlobs();
    session = FakeSession();
    controller = make();
  });

  Future<void> startPick() async {
    unawaited(controller.pick());
    await pumpEventQueue();
  }

  Future<void> finish() => pumpEventQueue();

  group('H1 controller: focus before a late change still lands the file', () {
    test('no draft before the change; exactly one draft after', () async {
      await startPick();
      session.focus();
      session.focus();
      expect(controller.busy, isTrue);
      expect(
        controller.drafts,
        isEmpty,
        reason: 'focus must not finish pick()',
      );
      expect(controller.error, isNull);
      final file = CountedItem('report.pdf', const [1, 2, 3, 4]);
      session.deliver(PickerPicked([file.attachment]));
      await finish();
      expect(controller.error, isNull);
      expect(controller.drafts.map((d) => d.filename), ['report.pdf']);
      expect(controller.busy, isFalse);
      expect(file.opens, 1, reason: 'stream read exactly once');
      // Prefs copy survives a controller rebuild.
      final reloaded = AttachmentController(
        HermesRepository('http://fake.invalid', 'k'),
        store,
        's1',
        blobs: blobs,
      );
      expect(reloaded.drafts.single.filename, 'report.pdf');
      reloaded.dispose();
    });
  });

  group('H2 controller: session lifecycle', () {
    test(
      'session untouched while waiting, cleaned up once at terminal',
      () async {
        await startPick();
        expect(session.aborts, 0, reason: 'input stays alive during the wait');
        session.deliver(
          PickerPicked([
            CountedItem('a.bin', const [7]).attachment,
          ]),
        );
        await finish();
        expect(session.aborts, 1, reason: 'terminal cleanup ran once');
        expect(controller.drafts, hasLength(1));
      },
    );
  });

  group('H3 controller: real cancel is a silent no-op', () {
    test('cancelled keeps drafts, error and busy clean', () async {
      await startPick();
      session.deliver(const PickerCancelled());
      await finish();
      expect(controller.error, isNull);
      expect(controller.drafts, isEmpty);
      expect(controller.busy, isFalse);
      expect(blobs.blobs, isEmpty);
      expect(session.aborts, 1);
      // Late events on a completed session change nothing.
      session.deliver(
        PickerPicked([
          CountedItem('late.bin', const [1]).attachment,
        ]),
      );
      await finish();
      expect(controller.drafts, isEmpty);
      expect(controller.error, isNull);
    });
  });

  group('H4 controller: anomalous outcomes surface typed errors', () {
    test(
      'emptyUnexpected maps to attachmentPickerEmpty, never cancel silence',
      () async {
        await startPick();
        session.deliver(const PickerEmptyUnexpected());
        await finish();
        expect(
          (controller.error! as UiLocal).key,
          MessageKey.attachmentPickerEmpty,
        );
        expect(controller.drafts, isEmpty);
        expect(blobs.blobs, isEmpty);
        expect(controller.busy, isFalse);
      },
    );

    test('failed passes its typed message through untouched', () async {
      await startPick();
      session.deliver(
        const PickerFailed(UiMessage.local(MessageKey.attachmentPickerFailed)),
      );
      await finish();
      expect(
        (controller.error! as UiLocal).key,
        MessageKey.attachmentPickerFailed,
      );
      expect(controller.busy, isFalse);
    });

    test('first file kept when a later file fails mid-read', () async {
      await startPick();
      final good = CountedItem('good.bin', const [9, 9]);
      final bad = CountedItem('bad.bin', const [
        1,
      ], errorAfter: StateError('gone'));
      session.deliver(PickerPicked([good.attachment, bad.attachment]));
      await finish();
      expect(controller.drafts.map((d) => d.filename), ['good.bin']);
      expect(controller.error, isNotNull);
      expect(controller.busy, isFalse);
    });
  });

  AttachmentController makeBounded(
    FakeTime t, {
    DraftStore? blobStore,
    LocalStore? local,
    Duration? timeout,
  }) => AttachmentController(
    HermesRepository('http://fake.invalid', 'k'),
    local ?? store,
    's1',
    blobs: blobStore ?? blobs,
    pickFactory: () => session,
    clock: () => t.now,
    timer: t.timer,
    pickTimeout: timeout ?? const Duration(minutes: 5),
  );

  group('H5 total budget (5 min, wait + staging)', () {
    test(
      '299s still busy; 300s times out, cleans up, re-picks clean',
      () async {
        final t = FakeTime();
        controller = makeBounded(t);
        unawaited(controller.pick());
        await pumpEventQueue();
        expect(controller.busy, isTrue);
        t.advance(const Duration(seconds: 299));
        t.fireLatest(); // an early/paused wake before the deadline
        await pumpEventQueue();
        expect(controller.busy, isTrue, reason: 'not expired yet');
        expect(controller.error, isNull);
        t.advance(const Duration(seconds: 1));
        t.fireLatest();
        await pumpEventQueue();
        expect(controller.busy, isFalse);
        expect(
          (controller.error! as UiLocal).key,
          MessageKey.attachmentPickerTimeout,
        );
        expect(controller.drafts, isEmpty);
        expect(
          session.aborts,
          1,
          reason: 'session aborted/cleaned exactly once',
        );
        // Late change on the dead session stays inert.
        session.deliver(
          PickerPicked([
            CountedItem('ghost.bin', const [1]).attachment,
          ]),
        );
        await pumpEventQueue();
        expect(controller.drafts, isEmpty);
        expect(blobs.blobs, isEmpty);
        // A fresh pick works and lands.
        session = FakeSession();
        unawaited(controller.pick());
        await pumpEventQueue();
        session.deliver(
          PickerPicked([
            CountedItem('ok.bin', const [5]).attachment,
          ]),
        );
        await pumpEventQueue();
        expect(controller.drafts.map((d) => d.filename), ['ok.bin']);
        expect(controller.error, isNull);
        expect(controller.busy, isFalse);
      },
    );
  });

  group('H6 suspended timers / resume checks', () {
    test(
      'expired clock: a focus wake-up decides timeout, not cancel',
      () async {
        final t = FakeTime();
        controller = makeBounded(t);
        unawaited(controller.pick());
        await pumpEventQueue();
        t.advance(const Duration(minutes: 5, seconds: 1));
        session.focus();
        await pumpEventQueue();
        expect(
          (controller.error! as UiLocal).key,
          MessageKey.attachmentPickerTimeout,
        );
        expect(controller.busy, isFalse);
        expect(controller.drafts, isEmpty);
      },
    );

    test('focus BEFORE the deadline never cancels', () async {
      final t = FakeTime();
      controller = makeBounded(t);
      unawaited(controller.pick());
      await pumpEventQueue();
      t.advance(const Duration(seconds: 299));
      session.focus();
      await pumpEventQueue();
      expect(controller.busy, isTrue);
      expect(controller.error, isNull);
      session.deliver(
        PickerPicked([
          CountedItem('pdf.bin', const [1, 2]).attachment,
        ]),
      );
      await pumpEventQueue();
      expect(controller.drafts.map((d) => d.filename), ['pdf.bin']);
      expect(controller.error, isNull);
    });

    test(
      'expired clock: a late change maps to timeout and is NOT staged',
      () async {
        final t = FakeTime();
        controller = makeBounded(t);
        unawaited(controller.pick());
        await pumpEventQueue();
        t.advance(const Duration(minutes: 5, seconds: 1));
        final file = CountedItem('late.bin', const [1]);
        session.deliver(PickerPicked([file.attachment]));
        await pumpEventQueue();
        expect(
          (controller.error! as UiLocal).key,
          MessageKey.attachmentPickerTimeout,
        );
        expect(file.opens, 0, reason: 'an expired result is never read');
        expect(controller.drafts, isEmpty);
        expect(session.aborts, 1);
      },
    );
  });

  group('H7 staging budget and the atomic commit zone', () {
    test(
      'expiry mid-staging cancels the stream; first file kept, no ghost',
      () async {
        final t = FakeTime();
        controller = makeBounded(t);
        final good = CountedItem('good.bin', const [9, 9]);
        final slow = HangingItem('slow.bin');
        unawaited(controller.pick());
        await pumpEventQueue();
        session.deliver(PickerPicked([good.attachment, slow.attachment]));
        await pumpEventQueue();
        expect(controller.drafts.map((d) => d.filename), ['good.bin']);
        t.advance(const Duration(minutes: 5, seconds: 1));
        t.fireLatest();
        await pumpEventQueue();
        expect(slow.cancelled, isTrue, reason: 'upstream read cancelled');
        expect(slow.opens, 1);
        expect(controller.drafts.map((d) => d.filename), ['good.bin']);
        expect(
          (controller.error! as UiLocal).key,
          MessageKey.attachmentPickerTimeout,
        );
        expect(controller.busy, isFalse);
        expect(blobs.blobs.values, [
          const [9, 9],
        ]);
      },
    );

    test(
      'a stage result landing after the timeout is discarded, never a draft',
      () async {
        final t = FakeTime();
        final gated = GatedBlobs();
        controller = makeBounded(t, blobStore: gated);
        unawaited(controller.pick());
        await pumpEventQueue();
        final file = CountedItem('slow.bin', const [1, 2, 3]);
        session.deliver(PickerPicked([file.attachment]));
        await pumpEventQueue();
        // stage is parked before its commit; the budget expires meanwhile:
        t.advance(const Duration(minutes: 5, seconds: 1));
        t.fireLatest();
        await pumpEventQueue();
        gated.gate.complete();
        await pumpEventQueue();
        expect(controller.drafts, isEmpty, reason: 'late ref never commits');
        expect(gated.blobs, isEmpty, reason: 'the late ref was discarded');
        expect(
          (controller.error! as UiLocal).key,
          MessageKey.attachmentPickerTimeout,
        );
      },
    );

    test('a persist already in flight completes; the file is kept', () async {
      final t = FakeTime();
      final slowStore = SlowSaveStore(store.prefs);
      final gated = GatedBlobs();
      controller = makeBounded(t, blobStore: gated, local: slowStore);
      unawaited(controller.pick());
      await pumpEventQueue();
      final file = CountedItem('commit.bin', const [4, 5]);
      session.deliver(PickerPicked([file.attachment]));
      gated.gate.complete();
      await pumpEventQueue(); // commit zone entered, save parked on its gate
      expect(slowStore.saveCalls, 1);
      t.advance(const Duration(minutes: 5, seconds: 1));
      t.fireLatest(); // timeout DURING the atomic commit
      await pumpEventQueue();
      expect(
        controller.busy,
        isTrue,
        reason: 'busy held until the write settles',
      );
      expect(controller.error, isNull);
      slowStore.gate.complete();
      await pumpEventQueue();
      expect(controller.busy, isFalse);
      expect(controller.drafts.map((d) => d.filename), [
        'commit.bin',
      ], reason: 'the persisted file is kept, not un-appended');
      expect(
        (controller.error! as UiLocal).key,
        MessageKey.attachmentPickerTimeout,
        reason: 'the timeout is reported after the write settles',
      );
      final reloaded = makeBounded(t, blobStore: gated, local: slowStore);
      expect(reloaded.drafts.map((d) => d.filename), ['commit.bin']);
      reloaded.dispose();
    });
  });

  group('H8 faults and capacity on the pick path', () {
    test('a zero-byte file is a valid pick', () async {
      final t = FakeTime();
      controller = makeBounded(t);
      unawaited(controller.pick());
      await pumpEventQueue();
      final empty = CountedItem('empty.bin', const []);
      session.deliver(PickerPicked([empty.attachment]));
      await pumpEventQueue();
      expect(controller.error, isNull);
      expect(controller.drafts.map((d) => d.filename), ['empty.bin']);
      expect(empty.opens, 1);
    });

    test('a knownSize beyond 500 MiB is rejected before any read', () async {
      final t = FakeTime();
      controller = makeBounded(t);
      unawaited(controller.pick());
      await pumpEventQueue();
      final huge = CountedItem('huge.bin', const [
        1,
      ], knownSize: attachmentMaxBytes + 1);
      session.deliver(PickerPicked([huge.attachment]));
      await pumpEventQueue();
      expect(huge.opens, 0, reason: 'known-size gate runs before openStream');
      expect((controller.error! as UiLocal).key, MessageKey.attachmentTooLarge);
      expect(controller.drafts, isEmpty);
      expect(controller.busy, isFalse);
    });

    test('storage failure surfaces feedback and unlocks', () async {
      final t = FakeTime();
      blobs.failAll = true;
      controller = makeBounded(t);
      unawaited(controller.pick());
      await pumpEventQueue();
      session.deliver(
        PickerPicked([
          CountedItem('x.bin', const [1]).attachment,
        ]),
      );
      await pumpEventQueue();
      expect(controller.error, isNotNull);
      expect(controller.drafts, isEmpty);
      expect(controller.busy, isFalse);
    });

    test(
      'each one-shot stream opens exactly once across a multi-file pick',
      () async {
        final t = FakeTime();
        controller = makeBounded(t);
        final a = CountedItem('a.bin', const [1]);
        final b = CountedItem('b.bin', const [2]);
        unawaited(controller.pick());
        await pumpEventQueue();
        session.deliver(PickerPicked([a.attachment, b.attachment]));
        await pumpEventQueue();
        expect(a.opens, 1);
        expect(b.opens, 1);
        expect(controller.drafts, hasLength(2));
      },
    );
  });

  group('H9 dispose and re-entry', () {
    test('one picker per busy window', () async {
      var sessions = 0;
      controller = AttachmentController(
        HermesRepository('http://fake.invalid', 'k'),
        store,
        's1',
        blobs: blobs,
        pickFactory: () {
          sessions++;
          session = FakeSession();
          return session;
        },
      );
      unawaited(controller.pick());
      await pumpEventQueue();
      unawaited(controller.pick()); // busy re-entry ignored
      await pumpEventQueue();
      expect(sessions, 1);
      session.deliver(const PickerCancelled());
      await pumpEventQueue();
      expect(controller.busy, isFalse);
    });

    test(
      'dispose aborts the session, cancels the timer, late results inert',
      () async {
        final t = FakeTime();
        controller = makeBounded(t);
        unawaited(controller.pick());
        await pumpEventQueue();
        expect(t.live, hasLength(1));
        controller.dispose();
        expect(session.aborted, isTrue);
        expect(
          t.live.where((x) => x.isActive),
          isEmpty,
          reason: 'no timers survive dispose',
        );
        final file = CountedItem('ghost.bin', const [1]);
        session.deliver(PickerPicked([file.attachment]));
        await pumpEventQueue();
        expect(controller.drafts, isEmpty);
        expect(file.opens, 0);
        // prefs untouched, no notify-after-dispose crash, re-pick inert:
        final reloaded = AttachmentController(
          HermesRepository('http://fake.invalid', 'k'),
          store,
          's1',
          blobs: blobs,
        );
        expect(reloaded.drafts, isEmpty);
        reloaded.dispose();
        unawaited(controller.pick());
        await pumpEventQueue();
      },
    );
  });

  group('H10 entry points do not regress', () {
    test('addFiles / pickSource never start a picker session', () async {
      var made = 0;
      controller = AttachmentController(
        HermesRepository('http://fake.invalid', 'k'),
        store,
        's1',
        blobs: blobs,
        pickFactory: () {
          made++;
          return FakeSession();
        },
      );
      await controller.addFiles([
        (
          name: 'a.bin',
          source: StreamAttachmentSource(() => Stream.value(const [1]), 1),
        ),
      ]);
      await controller.pickSource(
        StreamAttachmentSource(() => Stream.value(const [2]), 1),
        'b.bin',
      );
      expect(made, 0);
      expect(controller.drafts, hasLength(2));
    });

    test(
      'the web gallery fires onPickOther exactly once and returns null',
      () async {
        var calls = 0;
        final result = await web_gallery.pickFromGallery(
          _NoOpContext(),
          onPickOther: () => calls++,
        );
        expect(calls, 1);
        expect(result, isNull);
      },
    );
  });

  group('H11 feedback catalog', () {
    test('new keys carry the reviewed literal strings (en + zh-TW)', () {
      expect(
        catalogEn[MessageKey.attachmentPickerEmpty],
        'No selected file was received. Please try again.',
      );
      expect(
        catalogZhHant[MessageKey.attachmentPickerEmpty],
        '未收到選取的檔案，請再試一次。',
      );
      expect(
        catalogEn[MessageKey.attachmentPickerTimeout],
        'File selection or reading timed out. Close the picker and try '
        'again. Attachments already added are kept.',
      );
      expect(
        catalogZhHant[MessageKey.attachmentPickerTimeout],
        '選檔或讀取已逾時。請關閉選檔視窗後再試一次；已加入的附件會保留。',
      );
      expect(
        catalogEn[MessageKey.attachmentPickerFailed],
        'File selection could not be completed. Please try again.',
      );
      expect(catalogZhHant[MessageKey.attachmentPickerFailed], '無法完成選檔，請再試一次。');
    });

    testWidgets('an unsuccessful pick shows exactly one SnackBar', (
      tester,
    ) async {
      final session = FakeSession();
      controller = AttachmentController(
        HermesRepository('http://fake.invalid', 'k'),
        store,
        's1',
        blobs: blobs,
        pickFactory: () => session,
      );
      await tester.pumpWidget(
        localizedApp(
          Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => pickWithFeedback(controller, ctx),
                child: const Text('pick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('pick'));
      await tester.pump();
      session.deliver(const PickerEmptyUnexpected());
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(
          SnackBar,
          'No selected file was received. Please try again.',
        ),
        findsOneWidget,
      );
      // Descriptors stay locale-free until render (no pretranslated state).
      expect(
        (controller.error! as UiLocal).key,
        MessageKey.attachmentPickerEmpty,
      );
    });

    testWidgets('a cancel toast is silent', (tester) async {
      final session = FakeSession();
      controller = AttachmentController(
        HermesRepository('http://fake.invalid', 'k'),
        store,
        's1',
        blobs: blobs,
        pickFactory: () => session,
      );
      await tester.pumpWidget(
        localizedApp(
          Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => pickWithFeedback(controller, ctx),
                child: const Text('pick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('pick'));
      await tester.pump();
      session.deliver(const PickerCancelled());
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(controller.error, isNull);
    });
  });

  tearDown(() {
    controller.dispose();
  });
}

class _NoOpContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('the web gallery must not touch BuildContext');
}
