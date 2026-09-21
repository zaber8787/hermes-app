/// Bare URLs in prose don't autolink in gpt_markdown's inline path (verified by
/// test — 0 recognizers for a pasted http URL), so wrap them in CommonMark
/// angle autolinks before rendering. Code fences / inline code / existing
/// markdown links are stashed first so nothing inside them gets touched.
String linkifyBareUrls(String text) {
  final parts = text.split('```');
  for (var i = 0; i < parts.length; i += 2) {
    parts[i] = _linkifySegment(parts[i]);
  }
  return parts.join('```');
}

final _markdownLink = RegExp(r'\[[^\]\n]*\]\([^)\n]*\)');
final _angleUrl = RegExp(r'<https?://[^\s<>]*>');
final _inlineCode = RegExp(r'`[^`\n]+`');

/// A url starts after anything that can't be part of one: any non-word,
/// non-url char (so CJK punctuation like 「：」、 and even 中文 directly
/// glued to the url counts as a boundary). CJK punctuation is also excluded
/// from the url charset itself; ASCII sentence tails are peeled by [_trimTail].
final _bareUrl = RegExp(
  r'''(^|[^\w:/])(https?://[^\s<>"' ，。、；：（）【】《》「」『』“”‘’？！…—]+)''',
);


/// Peel sentence punctuation off the url tail. A trailing '.' is dropped too —
/// "…/index.html" never ends in '.' so extension urls are unaffected, and
/// "https://b.com." loses exactly the sentence dot.
String _trimTail(String url) {
  var u = url;
  while (true) {
    final m = RegExp(r'([)\]},;:!?]+|\.)$').firstMatch(u);
    if (m == null) break;
    final candidate = u.substring(0, m.start);
    if (candidate.length < 9) break; // keep at least a host after "http://"
    u = candidate;
  }
  return u;
}

String _linkifySegment(String s) {
  final stashed = <String>[];
  String stash(String match) {
    stashed.add(match);
    return '\u0000${stashed.length - 1}\u0001';
  }

  s = s.replaceAllMapped(_markdownLink, (m) => stash(m[0]!));
  s = s.replaceAllMapped(_angleUrl, (m) => stash(m[0]!));
  s = s.replaceAllMapped(_inlineCode, (m) => stash(m[0]!));
  s = s.replaceAllMapped(_bareUrl, (m) {
    final url = _trimTail(m[2]!);
    return '${m[1]}<$url>${m[2]!.substring(url.length)}';
  });
  s = s.replaceAllMapped(
    RegExp('\u0000(\\d+)\u0001'),
    (m) => stashed[int.parse(m[1]!)],
  );
  return s;
}
