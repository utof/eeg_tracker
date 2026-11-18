// The "i" notes (ROADMAP wish 14): docs/evidence/*.md, bundled as assets through the app/assets/evidence link,
// shown as simple text. Reads the small Markdown subset the notes are written in (docs/evidence/README.md):
// #, ## and ### headings, "- " bullets with indented continuation lines, paragraphs, **bold**, `code` and
// [text](https://...) links. Links show their text and the site's name; the app opens nothing by itself.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// A run of text in a block: plain, bold, code, or a link with its address.
typedef Span = ({String text, bool bold, String? url});

sealed class MdBlock {
  const MdBlock(this.spans);
  final List<Span> spans;
  String get plain => spans.map((s) => s.text).join();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, super.spans);
  final int level;
}

class MdBullet extends MdBlock {
  const MdBullet(super.spans);
}

class MdParagraph extends MdBlock {
  const MdParagraph(super.spans);
}

final RegExp _inline = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\((https?://[^)\s]+)\)');

List<Span> parseInline(String s) {
  final out = <Span>[];
  var at = 0;
  for (final m in _inline.allMatches(s)) {
    if (m.start > at) out.add((text: s.substring(at, m.start), bold: false, url: null));
    if (m.group(1) != null) {
      out.add((text: m.group(1)!, bold: true, url: null));
    } else if (m.group(2) != null) {
      out.add((text: m.group(2)!, bold: false, url: null));
    } else {
      out.add((text: m.group(3)!, bold: false, url: m.group(4)));
    }
    at = m.end;
  }
  if (at < s.length) out.add((text: s.substring(at), bold: false, url: null));
  return out;
}

List<MdBlock> parseMarkdown(String src) {
  final blocks = <MdBlock>[];
  final para = <String>[];
  String? bullet;
  void flush() {
    if (bullet != null) blocks.add(MdBullet(parseInline(bullet!)));
    if (para.isNotEmpty) blocks.add(MdParagraph(parseInline(para.join(' '))));
    bullet = null;
    para.clear();
  }

  for (final raw in src.split('\n')) {
    final line = raw.trimRight();
    final h = RegExp(r'^(#{1,3})\s+(.*)$').firstMatch(line);
    if (line.trim().isEmpty) {
      flush();
    } else if (h != null) {
      flush();
      blocks.add(MdHeading(h.group(1)!.length, parseInline(h.group(2)!)));
    } else if (line.startsWith('- ')) {
      flush();
      bullet = line.substring(2).trim();
    } else if (bullet != null && line.startsWith('  ')) {
      bullet = '${bullet!} ${line.trim()}';
    } else {
      if (bullet != null) flush();
      para.add(line.trim());
    }
  }
  flush();
  return blocks;
}

/// `jmir.org` for `https://www.jmir.org/2025/1/e68204`.
String siteOf(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// The note [name] (e.g. `meditation-feedback`) from the bundled assets.
Future<String> loadEvidence(String name, {AssetBundle? bundle}) =>
    (bundle ?? rootBundle).loadString('assets/evidence/$name.md');

/// Opens the note [name] in a bottom sheet over the current screen.
Future<void> showEvidence(BuildContext context, String name) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: Night.surfaceHigh,
  builder: (c) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.85,
    minChildSize: 0.4,
    maxChildSize: 0.95,
    builder: (c, scroll) => FutureBuilder<String>(
      future: loadEvidence(name),
      builder: (c, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text('This note is missing from the app ($name).', style: Theme.of(c).textTheme.bodyLarge),
          );
        }
        if (!snap.hasData) return const SizedBox.shrink();
        return EvidenceText(markdown: snap.data!, controller: scroll);
      },
    ),
  ),
);

/// A note as plain, selectable text in the night palette.
class EvidenceText extends StatelessWidget {
  const EvidenceText({super.key, required this.markdown, this.controller});
  final String markdown;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final body = text.bodyLarge?.copyWith(height: 1.45, color: Night.ink);
    TextSpan spans(List<Span> ss, TextStyle? style) => TextSpan(
      style: style,
      children: [
        for (final s in ss) ...[
          TextSpan(text: s.text, style: s.bold ? const TextStyle(fontWeight: FontWeight.w600) : null),
          if (s.url != null)
            TextSpan(text: ' (${siteOf(s.url!)})', style: const TextStyle(color: Night.inkMuted)),
        ],
      ],
    );
    final blocks = parseMarkdown(markdown);
    return SelectionArea(
      child: ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          for (final b in blocks)
            switch (b) {
              MdHeading(level: 1) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text.rich(spans(b.spans, text.headlineSmall?.copyWith(color: Night.ink))),
              ),
              MdHeading() => Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 8),
                child: Text.rich(spans(b.spans, text.titleMedium?.copyWith(fontWeight: FontWeight.w500))),
              ),
              MdBullet() => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 10, right: 12),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: const BoxDecoration(color: Night.inkMuted, shape: BoxShape.circle),
                      ),
                    ),
                    Expanded(child: Text.rich(spans(b.spans, body))),
                  ],
                ),
              ),
              MdParagraph() => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text.rich(spans(b.spans, body)),
              ),
            },
        ],
      ),
    );
  }
}
