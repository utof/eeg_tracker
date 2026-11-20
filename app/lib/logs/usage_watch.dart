// The screen engine's eyes for the usage log (DECISIONS 713) and the frame timings (DECISIONS 715), all inside the
// app's own window: no accessibility service, no other app.
//
//   UsageNavigatorObserver  the page on top after every push and pop (its widget's name: `MeditationScreen`)
//   UsageGestures           around the navigator: taps (which control, found by a hit test of the app's own widgets),
//                           drags that scrolled nothing, and every scroll by finger (the scroll notifications)
//   FrameWatch              Flutter's frame timings, a line per screen each minute: frames, slow, janky, the worst
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'metrics.dart';
import 'usage.dart';

/// The name of the page [route] shows: its settings' name when it has one, else the page widget's own type
/// (`MeditationScreen`); `dialog`, `sheet` or `popup` for the rest. Read-only: walks the route's built subtree.
String routeName(Route<dynamic> route) {
  final named = route.settings.name;
  if (named != null && named.isNotEmpty && named != Navigator.defaultRouteName) return named; // not the home's '/'
  if (route is PopupRoute) {
    return switch (route) {
      DialogRoute<dynamic>() => 'dialog',
      ModalBottomSheetRoute<dynamic>() => 'sheet',
      _ => 'popup',
    };
  }
  if (route is ModalRoute) {
    final ctx = route.subtreeContext;
    if (ctx is Element) {
      final page = _pageWidget(ctx);
      if (page != null) return page;
    }
  }
  return route.runtimeType.toString().replaceAll(RegExp(r'<.*>'), '');
}

/// Wrappers a route puts around its page, skipped on the way down.
const Set<String> _wrappers = {'RepaintBoundary', 'Builder', 'Semantics', 'PopScope', 'Material', 'Theme', 'KeyedSubtree'};

String? _pageWidget(Element top) {
  Element? at = top;
  for (var depth = 0; depth < 12 && at != null; depth++) {
    final name = at.widget.runtimeType.toString().replaceAll(RegExp(r'<.*>'), '');
    if (!_wrappers.contains(name)) return name.startsWith('_') ? name.substring(1) : name;
    Element? only;
    var n = 0;
    at.visitChildElements((c) {
      only = c;
      n++;
    });
    if (n != 1) return null;
    at = only;
  }
  return null;
}

/// Tells [Usage] the screen on top after every change of the navigator's pages. [rename] maps a page's name (the
/// home page, whose tabs say where you are: `tab:Signal`).
class UsageNavigatorObserver extends NavigatorObserver {
  UsageNavigatorObserver({this.rename});
  final String Function(String name)? rename;

  void _top(Route<dynamic>? route) {
    if (route == null) return;
    // the page is built at the next frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!route.isCurrent) return;
      final name = routeName(route);
      Usage.view(rename?.call(name) ?? name);
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _top(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _top(previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _top(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _top(newRoute);
}

/// What a tap hit: the control's kind, its own words and its key.
typedef TapTarget = ({String control, String? label, String? id});

/// Controls a person taps, most specific first in a hit's path.
bool _isControl(Widget w) =>
    w is ButtonStyleButton ||
    w is IconButton ||
    w is FloatingActionButton ||
    w is ListTile ||
    w is SwitchListTile ||
    w is CheckboxListTile ||
    w is Switch ||
    w is Checkbox ||
    w is Slider ||
    w is NavigationDestination ||
    w is SegmentedButton ||
    w is RawChip ||
    w is ActionChip ||
    w is FilterChip ||
    w is ChoiceChip ||
    w is InputChip ||
    w is PopupMenuItem ||
    w is MenuItemButton ||
    w is ExpansionTile ||
    w is DropdownButton;

bool _isTappable(Widget w) => w is InkResponse || (w is GestureDetector && (w.onTap != null || w.onLongPress != null));

/// The control at [position] of view [viewId] and its words: a hit test of the app's render tree, the element of the
/// deepest render object hit, and the widgets above it. Typed text (EditableText) is never read; digits in words
/// become `#`. A walk of the element tree per tap (a few thousand elements, well under a millisecond).
TapTarget? tapTarget(Offset position, int viewId) {
  final binding = WidgetsBinding.instance;
  final root = binding.rootElement;
  if (root == null) return null;
  final result = HitTestResult();
  binding.hitTestInView(result, position, viewId);
  // the hit's depth of each render object: 0 is the deepest
  final rank = <RenderObject, int>{};
  var i = 0;
  for (final e in result.path) {
    if (e.target is RenderObject) rank.putIfAbsent(e.target as RenderObject, () => i);
    i++;
  }
  if (rank.isEmpty) return null;
  Element? deepest;
  var deepestRank = 1 << 30;
  void visit(Element el) {
    if (el is RenderObjectElement) {
      final r = rank[el.renderObject];
      if (r != null && r < deepestRank) {
        deepestRank = r;
        deepest = el;
      }
    }
    el.visitChildElements(visit);
  }

  visit(root);
  final leaf = deepest;
  if (leaf == null) return null;
  final best = <Element>[leaf];
  leaf.visitAncestorElements((a) {
    best.add(a);
    return true;
  });
  best.setAll(0, best.reversed.toList()); // from the root down to the leaf
  if (!best.any((e) => _isControl(e.widget) || _isTappable(e.widget))) return null;
  // the deepest control in the path (a plain InkWell or GestureDetector only when no control holds it), then the
  // controls right above it that make one (IconButton holds a private button of its own)
  var at = best.lastIndexWhere((e) => _isControl(e.widget));
  if (at < 0) at = best.lastIndexWhere((e) => _isTappable(e.widget));
  var top = at;
  for (var up = at - 1; up >= 0 && up >= at - 4; up--) {
    if (_isControl(best[up].widget)) top = up;
  }
  final w = best[top].widget;
  String? label;
  for (var k = top; k <= at && label == null; k++) {
    final c = best[k].widget;
    if (c is IconButton && c.tooltip != null) label = c.tooltip;
    if (c is Tooltip && c.message != null) label = c.message;
  }
  label ??= _words(best[top]);
  // a bare switch or icon: the words of what holds it (a row, a tile), up to three levels up
  for (var up = top - 1; label == null && up >= 0 && up >= top - 3; up--) {
    label = _words(best[up]);
  }
  label ??= _icon(best[top]);
  final key = [for (var k = top; k <= at; k++) best[k].widget.key].whereType<ValueKey<String>>().firstOrNull;
  return (control: _kind(w), label: label == null ? null : usageLabel(label), id: key?.value);
}

String _kind(Widget w) => switch (w) {
  FilledButton() => 'FilledButton',
  OutlinedButton() => 'OutlinedButton',
  TextButton() => 'TextButton',
  ElevatedButton() => 'ElevatedButton',
  _ => w.runtimeType.toString().replaceAll(RegExp(r'<.*>'), '').replaceFirst(RegExp(r'^_'), ''),
};

/// The first two pieces of text under [el], joined; null when there are none. Never inside a text field.
String? _words(Element el) {
  final out = <String>[];
  void visit(Element e) {
    if (out.length >= 2) return;
    final w = e.widget;
    if (w is EditableText) return;
    if (w is RichText) {
      final t = w.text.toPlainText().trim();
      if (t.isNotEmpty) out.add(t);
      return;
    }
    e.visitChildElements(visit);
  }

  visit(el);
  return out.isEmpty ? null : out.join(' · ');
}

String? _icon(Element el) {
  String? found;
  void visit(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is Icon && w.icon != null) {
      found = w.semanticLabel ?? 'icon ${w.icon!.codePoint.toRadixString(16)}';
      return;
    }
    e.visitChildElements(visit);
  }

  visit(el);
  return found;
}

/// Around the navigator (MaterialApp's builder): taps, drags and scrolls of the app's own screens into [Usage]. Adds
/// no gesture of its own: it only listens to pointers and scroll notifications passing by.
class UsageGestures extends StatefulWidget {
  const UsageGestures({super.key, required this.child, this.onTap});
  final Widget child;

  /// Tests: what each tap found.
  final void Function(TapTarget? target)? onTap;

  @override
  State<UsageGestures> createState() => _UsageGesturesState();
}

class _UsageGesturesState extends State<UsageGestures> {
  final Map<int, (Offset, Offset, Duration)> _down = {};
  int _fingers = 0;
  bool _scrolled = false;
  final Map<String, (double, Duration)> _scrolls = {};
  final Stopwatch _clock = Stopwatch()..start();

  void _onDown(PointerDownEvent e) {
    if (_down.isEmpty) {
      _scrolled = false;
      _fingers = 0;
    }
    _down[e.pointer] = (e.position, e.position, _clock.elapsed);
    _fingers = math.max(_fingers, _down.length);
  }

  void _onMove(PointerMoveEvent e) {
    final d = _down[e.pointer];
    if (d != null) _down[e.pointer] = (d.$1, e.position, d.$3);
  }

  void _onUp(PointerUpEvent e) {
    final d = _down.remove(e.pointer);
    if (d == null) return;
    final moved = d.$2 - d.$1;
    final ms = (_clock.elapsed - d.$3).inMilliseconds;
    final last = _down.isEmpty;
    if (moved.distance < kTouchSlop && _fingers == 1) {
      TapTarget? t;
      try {
        t = tapTarget(e.position, View.of(context).viewId);
      } catch (_) {
        t = null;
      }
      widget.onTap?.call(t);
      Usage.tap(control: t?.control ?? 'nothing', label: t?.label, id: t?.id, long: ms >= 500);
    } else if (last && !_scrolled && moved.distance >= kTouchSlop) {
      final dir = moved.dx.abs() >= moved.dy.abs() ? (moved.dx > 0 ? 'right' : 'left') : (moved.dy > 0 ? 'down' : 'up');
      Usage.drag(dir: dir, px: moved.distance.round(), ms: ms, fingers: _fingers);
    }
  }

  void _onCancel(PointerCancelEvent e) => _down.remove(e.pointer);

  bool _onScroll(ScrollNotification n) {
    final key = '${n.depth}-${n.metrics.axis.name}';
    if (n is ScrollStartNotification) {
      if (n.dragDetails != null) _scrolls[key] = (n.metrics.pixels, _clock.elapsed);
    } else if (n is ScrollUpdateNotification) {
      if (n.dragDetails != null) _scrolled = true;
    } else if (n is ScrollEndNotification) {
      final s = _scrolls.remove(key);
      if (s != null) {
        final px = n.metrics.pixels - s.$1;
        if (px.abs() >= 8) {
          final vertical = n.metrics.axis == Axis.vertical;
          final max = n.metrics.maxScrollExtent;
          Usage.scroll(
            axis: vertical ? 'v' : 'h',
            dir: vertical ? (px > 0 ? 'down' : 'up') : (px > 0 ? 'right' : 'left'),
            px: px.abs().round(),
            ms: (_clock.elapsed - s.$2).inMilliseconds,
            reach: max > 0 ? (n.metrics.pixels / max).clamp(0.0, 1.0) : null,
          );
        }
      }
    }
    return false; // the notification goes on up
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _onDown,
    onPointerMove: _onMove,
    onPointerUp: _onUp,
    onPointerCancel: _onCancel,
    child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: widget.child),
  );
}

/// Flutter's frame timings per screen: a `frames` line each minute (and when the screen changes) with frames, slow
/// (build or raster over 16.7 ms), janky (over 33 ms), the worst and the mean, in ms.
class FrameWatch {
  FrameWatch({this.every = const Duration(minutes: 1), String? Function()? screen, void Function(Map<String, Object?>)? write})
    : _screen = screen ?? (() => Usage.screen),
      _write = write ?? Metrics.write;

  final Duration every;
  final String? Function() _screen;
  final void Function(Map<String, Object?>) _write;
  final Stopwatch _since = Stopwatch()..start();
  String? _at;
  int _n = 0, _slow = 0, _janky = 0, _worstUs = 0, _sumUs = 0;

  static const int _budgetUs = 16667, _jankUs = 33333;

  void start() => SchedulerBinding.instance.addTimingsCallback(add);
  void stop() {
    SchedulerBinding.instance.removeTimingsCallback(add);
    flush();
  }

  /// Frame timings as Flutter reports them (in batches).
  void add(List<FrameTiming> timings) {
    final screen = _screen();
    if (screen != _at) {
      flush();
      _at = screen;
    }
    for (final t in timings) {
      final us = math.max(t.buildDuration.inMicroseconds, t.rasterDuration.inMicroseconds);
      _n++;
      _sumUs += us;
      if (us > _budgetUs) _slow++;
      if (us > _jankUs) _janky++;
      if (us > _worstUs) _worstUs = us;
    }
    if (_since.elapsed >= every) flush();
  }

  void flush() {
    if (_n > 0) {
      _write({
        'kind': 'frames',
        'screen': _at ?? '?',
        'n': _n,
        'slow': _slow,
        'janky': _janky,
        'worst_ms': (_worstUs / 1000).round(),
        'mean_ms': double.parse((_sumUs / _n / 1000).toStringAsFixed(1)),
      });
    }
    _n = _slow = _janky = _worstUs = _sumUs = 0;
    _since.reset();
  }
}
