import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/models/session.dart';

void main() {
  const skills = [Skill('grill-me', '', ''), Skill('officecli', '', '')];
  test('exact contract skill rewrite and stacked skills', () {
    expect(
      rewriteSkills('/grill-me test', skills),
      '[用戶明確 invoke skill：grill-me。請用 skill_view 載入該 skill 並遵循其指示。使用者指令：test]',
    );
    expect(
      rewriteSkills('/grill-me /officecli test', skills).split('\n').length,
      2,
    );
    expect(rewriteSkills('plain text', skills), 'plain text');
  });
  test('gateway passthrough commands reach the model verbatim', () {
    // api_server 不做 slash 攔截：app 沒實作的 gateway 指令原文直通，
    // 由模型解釋/代辦，不能再當「未知 skill」擋死。
    expect(rewriteSkills('/help', skills), '/help');
  });
  test('core and unknown commands never go to the model', () {
    for (final input in [
      '/stop',
      '/steer test',
      '/model a',
      '/approve',
      '/unknown',
      // /status 改由 client 落地（v0.13.x 缺陷 3）：不再直通模型；堆疊時
      // 同樣必須擋掉。
      '/status',
      '/status /grill-me x',
      '/grill-me /status x',
      // app 端攔下執行的指令若落到 rewrite（如被堆疊），也不能當訊息送出
      '/reset',
      '/reset /grill-me x',
    ]) {
      expect(() => rewriteSkills(input, skills), throwsFormatException);
    }
    expect(
      () => rewriteSkills(
        '/grill-me /grill-me /grill-me /grill-me /grill-me /grill-me x',
        skills,
      ),
      throwsFormatException,
    );
  });
}
