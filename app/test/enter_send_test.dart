import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/features/chat/client_commands.dart';
import 'package:hermes_app/platform/chat_input_platform.dart';

KeyEvent _enterDown() => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.enter,
  logicalKey: LogicalKeyboardKey.enter,
  timeStamp: Duration.zero,
);

void main() {
  test('Enter sends, Shift+Enter and IME-composing Enter do not', () {
    var sent = 0;
    KeyEventResult run({bool shift = false, bool composing = false}) =>
        decideChatInputKey(
          _enterDown(),
          shiftDown: shift,
          composing: composing,
          sendAllowed: true,
          platform: TargetPlatform.macOS,
          send: () => sent++,
          insertNewline: () {},
        );

    expect(run(shift: false), KeyEventResult.handled);
    expect(sent, 1);
    expect(run(shift: true), KeyEventResult.ignored); // 換行
    expect(run(composing: true), KeyEventResult.ignored); // 選字中
    expect(sent, 1, reason: '只有純 Enter 送出過一次');

    // busy/preparing 時不重複送出，但事件仍被吃掉
    expect(
      decideChatInputKey(
        _enterDown(),
        shiftDown: false,
        composing: false,
        sendAllowed: false,
        platform: TargetPlatform.macOS,
        send: () => sent++,
        insertNewline: () {},
      ),
      KeyEventResult.handled,
    );
    expect(sent, 1);

    // 非 Enter 鍵一律放回
    expect(
      decideChatInputKey(
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration.zero,
        ),
        shiftDown: false,
        composing: false,
        sendAllowed: true,
        platform: TargetPlatform.macOS,
        send: () => sent++,
        insertNewline: () {},
      ),
      KeyEventResult.ignored,
    );
    expect(sent, 1);

    // key up 不觸發
    expect(
      decideChatInputKey(
        KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        ),
        shiftDown: false,
        composing: false,
        sendAllowed: true,
        platform: TargetPlatform.macOS,
        send: () => sent++,
        insertNewline: () {},
      ),
      KeyEventResult.ignored,
    );
    expect(sent, 1);
  });


KeyEvent enterKey(LogicalKeyboardKey logical) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.keyX,
  logicalKey: logical,
  timeStamp: Duration.zero,
);

for (final (platform, label) in const [
  (TargetPlatform.macOS, 'macOS'),
  (TargetPlatform.windows, 'Windows'),
  (TargetPlatform.linux, 'Linux'),
]) {
  test('desktop ($label): plain Enter sends, numpad too, Shift/composing not',
      () {
    var sent = 0;
    KeyEventResult run(
      LogicalKeyboardKey key, {
      bool shift = false,
      bool composing = false,
    }) => decideChatInputKey(
      enterKey(key),
      shiftDown: shift,
      composing: composing,
      sendAllowed: true,
      platform: platform,
      send: () => sent++,
      insertNewline: () {},
    );

    expect(run(LogicalKeyboardKey.enter), KeyEventResult.handled);
    expect(run(LogicalKeyboardKey.numpadEnter), KeyEventResult.handled);
    expect(sent, 2);
    expect(
      run(LogicalKeyboardKey.enter, shift: true),
      KeyEventResult.ignored,
    ); // 換行交給 TextField
    expect(run(LogicalKeyboardKey.enter, composing: true), KeyEventResult.ignored);
    expect(sent, 2);
  });
}

for (final platform in const [TargetPlatform.android, TargetPlatform.iOS]) {
  test('$platform: Enter inserts a newline (never sends) in any combo', () {
    var sent = 0, newlines = 0;
    KeyEventResult run(
      LogicalKeyboardKey key, {
      bool shift = false,
      bool composing = false,
      bool sendAllowed = true,
    }) => decideChatInputKey(
      enterKey(key),
      shiftDown: shift,
      composing: composing,
      sendAllowed: sendAllowed,
      platform: platform,
      send: () => sent++,
      insertNewline: () => newlines++,
    );

    expect(run(LogicalKeyboardKey.enter), KeyEventResult.handled);
    expect(run(LogicalKeyboardKey.numpadEnter), KeyEventResult.handled);
    expect(run(LogicalKeyboardKey.enter, shift: true), KeyEventResult.handled);
    expect(run(LogicalKeyboardKey.enter, sendAllowed: false), KeyEventResult.handled);
    expect(newlines, 4);
    expect(sent, 0, reason: '行動端 Enter 只能換行，任何組合都不能觸發送出');
    // 選字中的 Enter 屬 IME：不換行、不送出
    expect(
      run(LogicalKeyboardKey.enter, composing: true),
      KeyEventResult.ignored,
    );
    expect(newlines, 4);
    expect(sent, 0);
  });
}

test('chatInputPlatform resolves on the native side of the split', () {
  // VM tests run the native getter; web builds compile to the fixed-desktop
  // implementation (verified by `flutter test --platform chrome` of the
  // chat input widget test).
  expect(debugChatInputPlatform, isNull);
  expect(
    chatInputPlatform,
    // Web builds compile to the fixed-desktop side of the split; every other
    // target reports the real platform. (Chrome run covers the web branch.)
    kIsWeb ? TargetPlatform.macOS : defaultTargetPlatform,
  );
  debugChatInputPlatform = TargetPlatform.macOS;
  expect(chatInputPlatform, TargetPlatform.macOS);
  debugChatInputPlatform = null;
});
}
