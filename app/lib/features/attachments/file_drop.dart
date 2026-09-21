import 'attachment.dart';
import 'file_drop_io.dart' if (dart.library.js_interop) 'file_drop_web.dart'
    as impl;

/// 拖進視窗的檔案：name + 可重複開啟的位元組來源（與檔案選取器同一條 staging
/// 管線）。
typedef DroppedFile = ({String name, AttachmentSource source});

/// 一個拖放接收方（通常是開著的 ChatPage）。
class DropTarget {
  const DropTarget({
    required this.onFiles,
    required this.onEnter,
    required this.onLeave,
  });
  final void Function(List<DroppedFile> files) onFiles;
  final void Function() onEnter;
  final void Function() onLeave;
}

/// window 層拖放監聽（僅 web）。不攔的话瀏覽器會直接丟掉拖入的檔案，甚至放棄
/// 當前分頁改開檔案；因此 dragover 必須 preventDefault。io 端 all no-op。
/// 多個 target 可共存，drop 交給最近註冊的那個（最上層頁面）。
bool get fileDropSupported => impl.fileDropSupported;

void attachFileDrop(DropTarget target) => impl.attachFileDrop(target);

void detachFileDrop(DropTarget target) => impl.detachFileDrop(target);
