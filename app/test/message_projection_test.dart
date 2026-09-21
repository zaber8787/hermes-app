import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_app/models/message.dart';

List<Message> fixture(String name) {
  final data = jsonDecode(File('test/fixtures/$name.json').readAsStringSync());
  return (data['data'] as List)
      .map((m) => Message.fromJson(Map<String, dynamic>.from(m)))
      .toList();
}

void main() {
  test('three synthetic transcript shapes: final IDs and tool/result pairing',
      () {
    for (final pair in {
      'tool_round': '104',
      'hidden_narration': '304',
      'tool_result': '204',
    }.entries) {
      final entries = projectMessages(fixture(pair.key));
      expect(
        entries
            .where((e) => e.kind == EntryKind.finalReply)
            .map((e) => e.message.id),
        [pair.value],
      );
      final tool = entries.singleWhere((e) => e.kind == EntryKind.tool);
      expect(tool.result, isNotNull);
      expect(tool.result!.toolCallId, tool.call!.id);
    }
  });
  test('narration with tool_calls survives; hidden row never renders', () {
    final entries = projectMessages(fixture('hidden_narration'));
    expect(entries.any((e) => e.message.id == '301'), isFalse);
    expect(
      entries.singleWhere((e) => e.kind == EntryKind.narration).message.id,
      '302',
    );
    expect(
      entries.singleWhere((e) => e.kind == EntryKind.tool).message.id,
      '302',
    );
  });
  test('only last contentful tool-free assistant per turn is final', () {
    final entries = projectMessages(const [
      Message(id: '1', role: 'user', content: 'first'),
      Message(id: '2', role: 'assistant', content: 'draft'),
      Message(id: '3', role: 'assistant', content: 'answer'),
      Message(id: '4', role: 'user', content: 'next'),
      Message(id: '5', role: 'assistant', content: 'second'),
      Message(id: '6', role: 'assistant', content: ''),
    ]);
    expect(
      entries
          .where((e) => e.kind == EntryKind.finalReply)
          .map((e) => e.message.id),
      ['3', '5'],
    );
  });
  test('whitelisted and future display kinds are collapsed system events', () {
    for (final kind in [...systemLabels.keys, 'future_new_kind']) {
      final entry = projectMessages([
        Message(
          id: 'a',
          role: 'assistant',
          content: 'event',
          displayKind: kind,
        ),
      ]).single;
      expect(entry.kind, EntryKind.system);
    }
    expect(
      projectMessages(const [
        Message(
          id: 'a',
          role: 'tool',
          content: 'secret',
          displayKind: 'hidden',
        ),
      ]),
      isEmpty,
    );
  });
  test(
    'oldest/latest overlapping pages deduplicate by id, preserve equal texts',
    () {
      final original = fixture('tool_round');
      final latest = original.skip(2).toList();
      final older = original.take(3).toList();
      final merged = mergeMessages(latest, older);
      expect(merged.map((m) => m.id), ['101', '102', '103', '104']);
      expect(mergeMessages(merged, original).length, 4);
      expect(
        mergeMessages([], const [
          Message(id: '10', role: 'user', content: 'same'),
          Message(id: '9', role: 'user', content: 'same'),
        ]).map((m) => m.id),
        ['9', '10'],
      );
    },
  );
}
