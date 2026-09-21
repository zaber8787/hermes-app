import '../l10n/app_strings.dart';
import '../l10n/message_key.dart';
import '../l10n/ui_message.dart';
import 'message.dart';

/// Display-only untitled fallback (I18N-PLAN §4.4). Titles themselves stay
/// RAW in storage/models: a server title literally equal to an old fallback
/// is server data and is never rewritten here.
String displaySessionTitle(AppStrings strings, String raw) =>
    raw.isEmpty ? strings.resolve(MessageKey.sessionsUntitled) : raw;

class Session {
  const Session({
    required this.id,
    required this.title,
    required this.count,
    required this.startedAt,
    required this.activity,
    required this.source,
    this.pinned = false,
  });
  final String id, title, source;
  final int count;
  final double startedAt, activity;
  final bool pinned;
  factory Session.fromJson(Json json) {
    final start = (json['started_at'] as num?)?.toDouble() ?? 0;
    return Session(
      id: textOf(json['id']),
      title: textOf(json['title']),
      count: (json['message_count'] as num?)?.toInt() ?? 0,
      startedAt: start,
      activity:
          (json['last_activity'] as num?)?.toDouble() ??
          (json['updated_at'] as num?)?.toDouble() ??
          start,
      source: textOf(json['source']),
      pinned: json['pinned'] == true || json['pinned'] == 1,
    );
  }
  Session withActivity(double timestamp) => Session(
    id: id,
    title: title,
    count: count,
    startedAt: startedAt,
    activity: timestamp,
    source: source,
    pinned: pinned,
  );
  Session withTitle(String newTitle) => Session(
    id: id,
    title: newTitle,
    count: count,
    startedAt: startedAt,
    activity: activity,
    source: source,
    pinned: pinned,
  );
  Session withPinned(bool value) => Session(
    id: id,
    title: title,
    count: count,
    startedAt: startedAt,
    activity: activity,
    source: source,
    pinned: value,
  );
  String get readFingerprint => '$count:$activity';
}

class Skill {
  const Skill(this.name, this.description, this.category, {this.enabled = true});
  final String name, description, category;

  /// R3b: /v1/skills elements carry no switch semantics — absent means on.
  final bool enabled;
  factory Skill.fromJson(Json json) => Skill(
    textOf(json['name']),
    textOf(json['description']),
    textOf(json['category']),
    enabled: json['enabled'] != false,
  );
}

/// Mirror of the server's ESSENTIAL_SKILLS for the lock icon ONLY; the
/// reverse proxy stays the authority (its PATCH answers 400 regardless).
const essentialSkillNames = {'hermes-agent'};

/// gateway 內建、app 沒實作的指令：原文直通給模型（api_server 不做 slash
/// 攔截，模型看得到 slash 語意會解釋/代辦）。列進清單與放行，避免指令
/// 「看不到也不能用」。Descriptions are catalog keys (I18N-PLAN §4.4): the
/// slash names stay literal; each description resolves at render time.
const gatewayPassthroughCommands = <(String, MessageKey)>[
  ('help', MessageKey.sessionM001),
  ('sessions', MessageKey.sessionM002),
  ('resume', MessageKey.sessionM003),
  ('title', MessageKey.sessionM004),
  ('compress', MessageKey.sessionM005),
  ('retry', MessageKey.sessionM006),
  ('usage', MessageKey.sessionM007),
  ('memory', MessageKey.sessionM008),
  ('skills', MessageKey.sessionM009),
  ('approvals', MessageKey.sessionM010),
  ('verbose', MessageKey.sessionM011),
  ('version', MessageKey.sessionM012),
];

/// app 端攔下執行的指令名（chat_page 先行處理；若落到 rewrite 代表用法
/// 不對，例如被堆疊——必須擋掉而不是把原文送進對話）。
const appHandledCommands = {
  'stop',
  'steer',
  'model',
  'approve',
  'reset',
  'new',
  // /status 已改由 client 落地（clientCommandsProvider）；再進 rewrite
  // 就是繞過本地 handler，必須擋掉。
  'status',
};

/// Contract §5. Core commands are handled by the UI and must NEVER become prompts.
String rewriteSkills(String input, List<Skill> skills) {
  final trimmed = input.trim();
  if (!trimmed.startsWith('/')) return input;
  final tokens = trimmed.split(RegExp(r'\s+'));
  final names = <String>[];
  var i = 0;
  while (i < tokens.length && tokens[i].startsWith('/')) {
    final name = tokens[i].substring(1);
    if (appHandledCommands.contains(name)) {
      throw const AppFormatException(
        UiMessage.local(MessageKey.sessionM013),
      );
    }
    // 不是 skill 名稱：gateway 內建指令原文直通（api_server 不做 slash 攔截，
    // 模型看得到 slash 語意會解釋/代辦）；對不上的當錯字擋掉。
    if (!skills.any((s) => s.name == name)) {
      if (names.isEmpty && i == 0 &&
          gatewayPassthroughCommands.any((c) => c.$1 == name)) {
        return trimmed;
      }
      throw AppFormatException(
        UiMessage.local(MessageKey.sessionM014, args: {'name': name}),
      );
    }
    names.add(name);
    if (names.length > 5) {
      throw const AppFormatException(
        UiMessage.local(MessageKey.sessionM015),
      );
    }
    i++;
  }
  final args = tokens.skip(i).join(' ');
  return names
      .map(
        // i18n-exempt: protocol prompt (model-facing bytes, identical in
        // both locales) — see I18N-PLAN §5.
        // i18n-exempt
        (name) =>
            '[用戶明確 invoke skill：$name。請用 skill_view 載入該 skill 並遵循其指示。使用者指令：$args]',
      )
      .join('\n');
}
