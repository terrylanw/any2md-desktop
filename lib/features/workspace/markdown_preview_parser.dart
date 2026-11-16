import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;

final markdownPreviewParserProvider = Provider<MarkdownPreviewParser>(
  (ref) => MarkdownPreviewParser(),
);

class MarkdownPreviewKey {
  const MarkdownPreviewKey(
    this.taskId,
    this.revision, {
    this.enableTableLineBreaks = false,
  });

  final String taskId;
  final int revision;
  final bool enableTableLineBreaks;

  @override
  bool operator ==(Object other) =>
      other is MarkdownPreviewKey &&
      other.taskId == taskId &&
      other.revision == revision &&
      other.enableTableLineBreaks == enableTableLineBreaks;

  @override
  int get hashCode => Object.hash(taskId, revision, enableTableLineBreaks);
}

class ParsedMarkdownDocument {
  const ParsedMarkdownDocument({
    required this.key,
    required this.source,
    required this.nodes,
    required this.enableTableLineBreaks,
  });

  final MarkdownPreviewKey key;
  final String source;
  final List<md.Node> nodes;
  final bool enableTableLineBreaks;

  int get sourceLength => source.length;
}

class MarkdownPreviewParser {
  MarkdownPreviewParser({
    this.maxEntries = 4,
    this.maxSourceCharacters = 4 * 1024 * 1024,
  }) : assert(maxEntries > 0),
       assert(maxSourceCharacters >= 0);

  final int maxEntries;
  final int maxSourceCharacters;
  final LinkedHashMap<MarkdownPreviewKey, ParsedMarkdownDocument> _cache =
      LinkedHashMap();
  final Map<MarkdownPreviewKey, _PendingMarkdownParse> _pending = {};
  int _cachedSourceCharacters = 0;

  int get cachedEntryCount => _cache.length;
  int get cachedSourceCharacters => _cachedSourceCharacters;

  Future<ParsedMarkdownDocument> parse({
    required String taskId,
    required int revision,
    required String source,
    bool enableTableLineBreaks = false,
  }) {
    final key = MarkdownPreviewKey(
      taskId,
      revision,
      enableTableLineBreaks: enableTableLineBreaks,
    );
    final cached = _cache.remove(key);
    if (cached != null && cached.source == source) {
      _cache[key] = cached;
      return Future.value(cached);
    }
    if (cached != null) {
      _cachedSourceCharacters -= cached.sourceLength;
    }

    final pending = _pending[key];
    if (pending != null && pending.source == source) return pending.future;

    final future = _parseUncached(
      key,
      source,
      enableTableLineBreaks: enableTableLineBreaks,
    );
    final entry = _PendingMarkdownParse(source, future);
    _pending[key] = entry;
    unawaited(
      future.then<void>(
        (parsed) {
          if (!identical(_pending[key], entry)) return;
          _pending.remove(key);
          _store(parsed);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_pending[key], entry)) _pending.remove(key);
        },
      ),
    );
    return future;
  }

  Future<ParsedMarkdownDocument> _parseUncached(
    MarkdownPreviewKey key,
    String source, {
    required bool enableTableLineBreaks,
  }) async {
    final nodes = source.trim().isEmpty
        ? <md.Node>[]
        : await Isolate.run(() {
            final document = md.Document(
              extensionSet: enableTableLineBreaks
                  ? tableMarkdownPreviewExtensionSet()
                  : md.ExtensionSet.gitHubFlavored,
              encodeHtml: false,
            );
            return document.parse(source);
          });
    return ParsedMarkdownDocument(
      key: key,
      source: source,
      nodes: List.unmodifiable(nodes),
      enableTableLineBreaks: enableTableLineBreaks,
    );
  }

  void _store(ParsedMarkdownDocument parsed) {
    final previous = _cache.remove(parsed.key);
    if (previous != null) {
      _cachedSourceCharacters -= previous.sourceLength;
    }
    final key = parsed.key;
    _cache[key] = parsed;
    _cachedSourceCharacters += parsed.sourceLength;
    _trimCache(protectedKey: key);
  }

  void _trimCache({required MarkdownPreviewKey protectedKey}) {
    while (_cache.length > maxEntries ||
        (_cachedSourceCharacters > maxSourceCharacters && _cache.length > 1)) {
      final oldestKey = _cache.keys.first;
      if (oldestKey == protectedKey && _cache.length > 1) {
        final protected = _cache.remove(oldestKey)!;
        _cache[oldestKey] = protected;
        continue;
      }
      final removed = _cache.remove(oldestKey)!;
      _cachedSourceCharacters -= removed.sourceLength;
    }
  }
}

md.ExtensionSet tableMarkdownPreviewExtensionSet() {
  final gfm = md.ExtensionSet.gitHubFlavored;
  return md.ExtensionSet(gfm.blockSyntaxes, [
    _TableCellLineBreakSyntax(),
    ...gfm.inlineSyntaxes,
  ]);
}

class _TableCellLineBreakSyntax extends md.InlineSyntax {
  _TableCellLineBreakSyntax()
    : super(r'<br\s*/?>', startCharacter: 60, caseSensitive: false);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.empty('br'));
    return true;
  }
}

class _PendingMarkdownParse {
  const _PendingMarkdownParse(this.source, this.future);

  final String source;
  final Future<ParsedMarkdownDocument> future;
}
