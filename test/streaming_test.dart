// The SDK's streaming decoding tests (tests/streaming.test.ts) and the line endings of its line decoder tests
// (tests/internal/decoders/line.test.ts), through the server-sent event decoder.

import 'dart:convert';

import 'package:openai_sdk_lite_dart/openai_sdk_lite_dart.dart';
import 'package:test/test.dart';

Future<List<ServerSentEvent>> decode(List<Object> chunks) {
  return decodeServerSentEvents(
    Stream.fromIterable([for (final c in chunks) c is String ? utf8.encode(c) : c as List<int>]),
  ).toList();
}

void main() {
  test('basic', () async {
    final events = await decode(['event: completion\n', 'data: {"foo":true}\n', '\n']);
    expect(events, hasLength(1));
    expect(jsonDecode(events.single.data), {'foo': true});
  });

  test('data without event', () async {
    final events = await decode(['data: {"foo":true}\n', '\n']);
    expect(events.single.event, isNull);
    expect(jsonDecode(events.single.data), {'foo': true});
  });

  test('event without data', () async {
    final events = await decode(['event: foo\n', '\n']);
    expect((events.single.event, events.single.data), ('foo', ''));
  });

  test('multiple events', () async {
    final events = await decode(['event: foo\n', '\n', 'event: ping\n', '\n']);
    expect([for (final e in events) (e.event, e.data)], [('foo', ''), ('ping', '')]);
  });

  test('multiple events with data', () async {
    final events = await decode([
      'event: foo\n',
      'data: {"foo":true}\n',
      '\n',
      'event: ping\n',
      'data: {"bar":false}\n',
      '\n',
    ]);
    expect([for (final e in events) e.event], ['foo', 'ping']);
    expect(
      [for (final e in events) jsonDecode(e.data)],
      [
        {'foo': true},
        {'bar': false},
      ],
    );
  });

  test('multiple data lines with empty line', () async {
    final events = await decode([
      'event: ping\n',
      'data: {\n',
      'data: "foo":\n',
      'data: \n',
      'data:\n',
      'data: true}\n',
      '\n\n',
    ]);
    expect(events.single.event, 'ping');
    expect(jsonDecode(events.single.data), {'foo': true});
    expect(events.single.data, '{\n"foo":\n\n\ntrue}');
  });

  test('data json escaped double new line', () async {
    final events = await decode(['event: ping\n', r'data: {"foo": "my long\n\ncontent"}', '\n\n']);
    expect(jsonDecode(events.single.data), {'foo': 'my long\n\ncontent'});
  });

  test('special new line characters', () async {
    final events = await decode([
      'data: {"content": "culpa "}\n',
      '\n',
      'data: {"content": "',
      [0xe2, 0x80, 0xa8],
      '"}\n',
      '\n',
      'data: {"content": "foo"}\n',
      '\n',
    ]);
    expect(
      [for (final e in events) jsonDecode(e.data)],
      [
        {'content': 'culpa '},
        {'content': ' '},
        {'content': 'foo'},
      ],
    );
  });

  test('multi-byte characters across chunks', () async {
    final events = await decode([
      'event: completion\n',
      'data: {"content": "',
      [0xd0],
      [0xb8, 0xd0, 0xb7, 0xd0],
      [0xb2, 0xd0, 0xb5, 0xd1, 0x81, 0xd1, 0x82, 0xd0, 0xbd, 0xd0, 0xb8],
      '"}\n',
      '\n',
    ]);
    expect(events.single.event, 'completion');
    expect(jsonDecode(events.single.data), {'content': 'известни'});
  });

  group('line endings', () {
    test('\\r, \\r\\n and \\n end lines, also split across chunks', () async {
      final events = await decode(['event: a\rdata: 1\r', '\r', 'event: b\r\ndata: 2\r', '\n\r\n', 'data: 3\n\n']);
      expect([for (final e in events) (e.event, e.data)], [('a', '1'), ('b', '2'), (null, '3')]);
    });

    test('a final event without a blank line is still delivered, once', () async {
      expect(
        [
          for (final e in await decode(['data: 1\n\ndata: 2'])) e.data,
        ],
        ['1', '2'],
      );
      expect(
        [
          for (final e in await decode(['data: 1\n\n'])) e.data,
        ],
        ['1'],
      );
    });
  });

  test('comments are skipped and kept in raw; a field without a colon has an empty value', () async {
    final events = await decode([': keep-alive\n', 'data\n', 'data:x\n', '\n']);
    expect(events.single.data, '\nx');
    expect(events.single.raw, [': keep-alive', 'data', 'data:x']);
  });

  test('malformed UTF-8 is replaced, not thrown', () async {
    final events = await decode([
      'data: a',
      [0xff],
      'b\n\n',
    ]);
    expect(events.single.data, 'a\ufffdb');
  });

  test('a blank event name with no data starts no event', () async {
    expect(await decode(['event:\n', '\n']), isEmpty);
  });
}
