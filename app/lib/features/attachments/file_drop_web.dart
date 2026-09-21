import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'attachment.dart';
import 'file_drop.dart';

/// 瀏覽器拖放：window 層監聽。CanvasKit 只吃自己的指針事件，window 级
/// drop 事件是唯一入口；而且不 preventDefault 的話瀏覽器會放棄頁面直接
/// 打開拖入的檔案。
///
/// 回呼走註冊表：ChatPage 會叠航（列表→聊天→返回列表），先開的頁面
/// dispose 時不能把後開頁面剛掛的監聽一併拆掉。
final _targets = <DropTarget>{};
web.EventListener? _enter, _over, _leave, _drop, _paste;
int _depth = 0;

bool get fileDropSupported => true;

/// extension type 的 `is` 檢查不看底層型別，必須問 JS 建構子名。
bool _isDrag(web.Event e) => e.instanceOfString('DragEvent');
bool _isPaste(web.Event e) => e.instanceOfString('ClipboardEvent');

bool _hasFiles(web.DragEvent e) {
  final dt = e.dataTransfer;
  if (dt == null) return false;
  if (dt.files.length > 0) return true;
  return dt.types.toDart.contains('Files');
}

List<DroppedFile> _dropped(web.DragEvent e) {
  final dt = e.dataTransfer;
  if (dt == null) return const [];
  return [
    for (var i = 0; i < dt.files.length; i++)
      if (dt.files.item(i) case final f?)
        (
          name: f.name,
          // File.arrayBuffer() 每次呼叫重讀 → 符合可重複開啟 contract。
          source: StreamAttachmentSource(() async* {
            yield Uint8List.view((await f.arrayBuffer().toDart).toDart);
          }, f.size)
        ),
  ];
}

void _install() {
  _enter = ((web.Event e) {
    if (!_isDrag(e) || !_hasFiles(e as web.DragEvent)) return;
    e.preventDefault();
    _depth++;
    for (final t in _targets.toList()) {
      t.onEnter();
    }
  }).toJS;
  _over = ((web.Event e) {
    if (!_isDrag(e) || !_hasFiles(e as web.DragEvent)) return;
    // preventDefault 是 drop 能觸發的前置條件；顺便給游標 copy 樣式。
    e.preventDefault();
    e.dataTransfer?.dropEffect = 'copy';
  }).toJS;
  _leave = ((web.Event e) {
    if (!_isDrag(e) || !_hasFiles(e as web.DragEvent)) return;
    _depth = (_depth - 1).clamp(0, 1 << 30);
    if (_depth == 0) {
      for (final t in _targets.toList()) {
        t.onLeave();
      }
    }
  }).toJS;
  _drop = ((web.Event e) {
    if (!_isDrag(e) || !_hasFiles(e as web.DragEvent)) return;
    e.preventDefault();
    _depth = 0;
    // dragleave 在 drop 後不會可靠觸發，這裡統一收掉高亮。
    final files = _dropped(e);
    for (final t in _targets.toList()) {
      t.onLeave();
    }
    if (files.isEmpty) return;
    // 最上層的頁面吃掉（註冊順序尾＝最近掛載＝最上層導航頁）。
    _targets.last.onFiles(files);
  }).toJS;
  _paste = ((web.Event e) {
    if (!_isPaste(e)) return;
    final cd = (e as web.ClipboardEvent).clipboardData;
    if (cd == null) return;
    final files = <DroppedFile>[];
    for (var i = 0; i < cd.items.length; i++) {
      final item = cd.items[i];
      if (item.kind != 'file') continue;
      final f = item.getAsFile();
      if (f == null) continue;
      files.add((
        name: f.name,
        // File.arrayBuffer() 每次呼叫重讀 → 符合可重複開啟 contract。
        source: StreamAttachmentSource(() async* {
          yield Uint8List.view((await f.arrayBuffer().toDart).toDart);
        }, f.size),
      ));
    }
    if (files.isEmpty) return; // 純文字貼上：交給輸入框原行為
    // 截圖/圖片直接進附件列，順帶擋掉「檔名被當文字打進欄位」的預設。
    e.preventDefault();
    _targets.last.onFiles(files);
  }).toJS;
  web.window.addEventListener('dragenter', _enter);
  web.window.addEventListener('dragover', _over);
  web.window.addEventListener('dragleave', _leave);
  web.window.addEventListener('drop', _drop);
  web.window.addEventListener('paste', _paste);
}

void _uninstall() {
  final w = web.window;
  for (final (type, l) in [
    ('dragenter', _enter),
    ('dragover', _over),
    ('dragleave', _leave),
    ('drop', _drop),
    ('paste', _paste),
  ]) {
    if (l != null) w.removeEventListener(type, l);
  }
  _enter = _over = _leave = _drop = _paste = null;
  _depth = 0;
}

void attachFileDrop(DropTarget target) {
  _targets.add(target);
  if (_targets.length == 1) _install();
}

void detachFileDrop(DropTarget target) {
  if (!_targets.remove(target)) return;
  if (_targets.isEmpty) _uninstall();
}
