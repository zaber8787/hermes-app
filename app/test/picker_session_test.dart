import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/api/hermes_repository.dart' show ApiException;
import 'package:hermes_app/features/attachments/picker_session.dart';
import 'package:hermes_app/features/attachments/picker_session_state.dart';
import 'package:hermes_app/l10n/message_key.dart';
import 'package:hermes_app/l10n/ui_message.dart';

/// Fake driver replaying events through the SAME production core the DOM
/// driver uses (IOS-PICKER-PLAN C1: never a test-only reducer). The legacy
/// file_picker_web 3.1.0 rule — window focus then 500 ms without change
/// completes the session empty — is replayed here to prove focus is no
/// longer a terminal state. This fixture guards the timing class of bug;
/// it does NOT claim to reproduce a real-device WebKit trace.
class FakeDriver {
  FakeDriver() {
    core = PickerSessionCore(
      emit: (o) => outcome = o,
      releaseDriver: () => releases++,
    );
    core.focusHint = () => focusHints++;
    starts++;
  }

  late final PickerSessionCore core;
  PickerOutcome? outcome;
  int starts = 0;
  int releases = 0;
  int focusHints = 0;
}

PickedAttachment item(String name, {List<int>? bytes}) => PickedAttachment(
  name: name,
  openStream: () => Stream.value(bytes ?? const <int>[1]),
);

void main() {
  group('H1 focus is never terminal (legacy 500ms focus-cancel replay)', () {
    test('focus storms before a late change still end in picked, once', () {
      final d = FakeDriver();
      expect(d.starts, 1);
      d.core.focus();
      d.core.focus();
      expect(d.outcome, isNull, reason: 'focus must not complete the session');
      expect(d.releases, 0, reason: 'input must stay attached while waiting');
      // Where the old rule would fire: focus + 500 ms without change.
      d.core.focus();
      expect(d.outcome, isNull);
      expect(d.focusHints, 3, reason: 'focus only forwards the wake-up');
      // The change finally arrives, seconds later.
      d.core.files([item('report.pdf')]);
      expect(d.outcome, isA<PickerPicked>());
      expect((d.outcome! as PickerPicked).items.single.name, 'report.pdf');
      expect(d.releases, 1, reason: 'terminal releases the driver once');
      // One terminal decision only: later events are ignored.
      d.core.cancel();
      d.core.files([item('late.bin')]);
      d.core.focus();
      expect(d.outcome, isA<PickerPicked>());
      expect(d.releases, 1);
      expect(d.focusHints, 3, reason: 'no hints after terminal either');
    });
  });

  group('H2 lifecycle', () {
    test(
      'no release while waiting, exactly one at terminal, abandon is idempotent',
      () {
        final d = FakeDriver();
        expect(d.releases, 0);
        d.core.files([item('a.bin')]);
        expect(d.releases, 1);
        d.core.abandon();
        expect(d.releases, 1, reason: 'cleanup is idempotent');

        final e = FakeDriver();
        e.core.abandon();
        expect(e.releases, 1, reason: 'abandon releases even without events');
        expect(e.outcome, isNull, reason: 'abandoned sessions never complete');
        e.core.files([item('ghost.bin')]);
        e.core.cancel();
        expect(e.outcome, isNull, reason: 'events after abandon are dropped');
      },
    );

    test('each driver instance is independent (fresh input per pick)', () {
      final a = FakeDriver();
      final b = FakeDriver();
      a.core.cancel();
      expect(
        b.outcome,
        isNull,
        reason: 'a terminal in one session cannot settle another',
      );
      expect(b.releases, 0);
    });
  });

  group('H3 real cancel', () {
    test('cancel event wins, late change after cancel adds nothing', () {
      final d = FakeDriver();
      d.core.cancel();
      expect(d.outcome, isA<PickerCancelled>());
      d.core.cancel();
      d.core.files([item('late.bin')]);
      expect(d.outcome, isA<PickerCancelled>());
      expect(d.releases, 1);
    });
  });

  group('H4 anomalous empty is not a cancel', () {
    test('change with an empty FileList maps to emptyUnexpected', () {
      final d = FakeDriver();
      d.core.files(const []);
      expect(d.outcome, isA<PickerEmptyUnexpected>());
      expect(d.outcome, isNot(isA<PickerCancelled>()));
    });

    test('null FileList change maps to emptyUnexpected', () {
      final d = FakeDriver();
      d.core.emptyChange();
      expect(d.outcome, isA<PickerEmptyUnexpected>());
    });

    test('DOM faults settle as typed failures', () {
      final d = FakeDriver();
      d.core.fault(StateError('click refused'));
      final failed = d.outcome! as PickerFailed;
      expect(
        (failed.message as UiLocal).key,
        MessageKey.attachmentPickerFailed,
      );

      final e = FakeDriver();
      e.core.fault(const ApiException.local(MessageKey.attachmentTooLarge));
      final typed = e.outcome! as PickerFailed;
      expect(
        (typed.message as UiLocal).key,
        MessageKey.attachmentTooLarge,
        reason: 'typed errors keep their catalog key',
      );
    });
  });
}
