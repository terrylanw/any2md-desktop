import 'package:any2md_desktop/features/workspace/markdown_preview_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

void main() {
  test('parses a complete GFM document in the isolate', () async {
    final parser = MarkdownPreviewParser();
    final parsed = await parser.parse(
      taskId: 'task-1',
      revision: 1,
      source: '''# Title

[Open reference][docs]

[docs]: https://example.com/docs

- one
- two

```dart
final value = 1;
```

| A | B |
| - | - |
| 1 | 2 |
''',
    );

    final elements = _allElements(parsed.nodes).toList();
    expect(
      elements.map((element) => element.tag),
      containsAll(['h1', 'ul', 'pre', 'table', 'a']),
    );
    expect(
      elements.singleWhere((element) => element.tag == 'a').attributes['href'],
      'https://example.com/docs',
    );
  });

  test('reuses the same revision and invalidates changed source', () async {
    final parser = MarkdownPreviewParser();
    final first = await parser.parse(
      taskId: 'task-1',
      revision: 1,
      source: '# First',
    );
    final cached = await parser.parse(
      taskId: 'task-1',
      revision: 1,
      source: '# First',
    );
    final changed = await parser.parse(
      taskId: 'task-1',
      revision: 1,
      source: '# Changed',
    );

    expect(identical(cached, first), isTrue);
    expect(identical(changed, first), isFalse);
    expect(changed.source, '# Changed');
  });

  test('does not let an older in-flight parse replace newer source', () async {
    final parser = MarkdownPreviewParser();
    final oldSource = List.filled(10000, 'Old paragraph').join('\n\n');
    final oldRequest = parser.parse(
      taskId: 'task-1',
      revision: 1,
      source: oldSource,
    );
    final newRequest = parser.parse(
      taskId: 'task-1',
      revision: 1,
      source: '# New source',
    );

    await Future.wait([oldRequest, newRequest]);
    final cached = await parser.parse(
      taskId: 'task-1',
      revision: 1,
      source: '# New source',
    );

    expect(identical(cached, await newRequest), isTrue);
    expect(cached.source, '# New source');
  });

  test('bounds the LRU cache while retaining one oversized document', () async {
    final parser = MarkdownPreviewParser(maxEntries: 2, maxSourceCharacters: 8);
    await parser.parse(taskId: 'a', revision: 1, source: '1234');
    await parser.parse(taskId: 'b', revision: 1, source: '5678');
    await parser.parse(taskId: 'c', revision: 1, source: 'abcd');

    expect(parser.cachedEntryCount, 2);
    expect(parser.cachedSourceCharacters, 8);

    await parser.parse(taskId: 'large', revision: 1, source: 'x' * 20);
    expect(parser.cachedEntryCount, 1);
    expect(parser.cachedSourceCharacters, 20);
  });

  test('returns an empty AST for blank markdown', () async {
    final parsed = await MarkdownPreviewParser().parse(
      taskId: 'empty',
      revision: 0,
      source: '  \n',
    );

    expect(parsed.nodes, isEmpty);
  });
}

Iterable<md.Element> _allElements(Iterable<md.Node> nodes) sync* {
  for (final node in nodes) {
    if (node is! md.Element) continue;
    yield node;
    yield* _allElements(node.children ?? const []);
  }
}
