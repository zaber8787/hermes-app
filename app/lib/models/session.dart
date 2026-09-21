import 'message.dart';

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
      title: textOf(json['title']).isEmpty ? '未命名對話' : textOf(json['title']),
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
    title: newTitle.isEmpty ? '未命名對話' : newTitle,
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
/// 「看不到也不能用」。
const gatewayPassthroughCommands = <(String, String)>[
  ('help', '所有可用指令說明'),
  ('sessions', '列出對話'),
  ('resume', '接回某個對話'),
  ('title', '修改對話標題'),
  ('compress', '壓縮脈絡'),
  ('retry', '重跑最後一輪'),
  ('usage', 'token 用量'),
  ('memory', '記憶相關'),
  ('skills', '技能清單'),
  ('approvals', '審核模式'),
  ('verbose', '詳細輸出'),
  ('version', '伺服器版本'),
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
      throw const FormatException('此指令由介面端處理，不能與 skills 堆疊或當訊息送出。');
    }
    // 不是 skill 名稱：gateway 內建指令原文直通（api_server 不做 slash 攔截，
    // 模型看得到 slash 語意會解釋/代辦）；對不上的當錯字擋掉。
    if (!skills.any((s) => s.name == name)) {
      if (names.isEmpty && i == 0 &&
          gatewayPassthroughCommands.any((c) => c.$1 == name)) {
        return trimmed;
      }
      throw FormatException('未知指令：/$name');
    }
    names.add(name);
    if (names.length > 5) throw const FormatException('最多堆疊 5 個 skills。');
    i++;
  }
  final args = tokens.skip(i).join(' ');
  return names
      .map(
        (name) =>
            '[用戶明確 invoke skill：$name。請用 skill_view 載入該 skill 並遵循其指示。使用者指令：$args]',
      )
      .join('\n');
}
