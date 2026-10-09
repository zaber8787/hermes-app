import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web: back/forward or an edited fragment fire popstate/hashchange; each
/// emits the full current href for the SAME exact parser.
Stream<String> locationChanges() {
  final controller = StreamController<String>();
  void onChange(JSAny? _) => controller.add(web.window.location.href);
  web.window.addEventListener('popstate', onChange.toJS);
  web.window.addEventListener('hashchange', onChange.toJS);
  controller.onCancel = () {
    web.window.removeEventListener('popstate', onChange.toJS);
    web.window.removeEventListener('hashchange', onChange.toJS);
  };
  return controller.stream;
}

/// Web keeps the address bar as its live source (app_links only supplies
/// an initial link here, which the launch stash already captures in main).
Stream<String> incomingLinks() => locationChanges();
