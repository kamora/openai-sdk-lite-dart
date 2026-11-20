import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';

/// A server-sent event before its data is parsed.
class ServerSentEvent {
  const ServerSentEvent(this.event, this.data, this.raw);

  /// The `event:` field, or `null` when the event has none.
  final String? event;

  /// The `data:` fields, joined with newlines.
  final String data;

  /// The event's lines, kept for diagnostics.
  final List<String> raw;
}

/// The server-sent events in [bytes]. Lines end with `\n`, `\r\n` or `\r`; malformed UTF-8 is replaced, as a browser's
/// decoder does; an event the stream ends without a blank line after is still delivered.
Stream<ServerSentEvent> decodeServerSentEvents(Stream<List<int>> bytes) async* {
  final decoder = _Decoder();
  await for (final line in bytes.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter())) {
    if (decoder.decode(line) case final ServerSentEvent event) {
      yield event;
    }
  }

  if (decoder.decode('') case final ServerSentEvent event) {
    yield event;
  }
}

/// The JSON events of a streamed [response], as the TypeScript SDK's `Stream.fromSSEResponse` gives them.
///
/// The stream ends at a `[DONE]` event, ignoring the rest. An `error` event, or one whose data has an `error`, throws
/// an [APIError]; data that is not JSON throws a [FormatException]. Events named `thread.*` (the Assistants API) come
/// as `{'event': name, 'data': data}`. Once [aborted] says the caller aborted the request, the stream ends quietly, as
/// the SDK's does, even with events already received. Cancelling the subscription ends the request.
Stream<Map<String, Object?>> responseEvents(http.StreamedResponse response, {required bool Function() aborted}) async* {
  try {
    await for (final sse in decodeServerSentEvents(response.stream)) {
      if (aborted()) {
        return;
      }

      if (sse.data == '[DONE]') {
        return;
      }

      final data = _parse(sse);
      if (sse.event?.startsWith('thread.') ?? false) {
        yield {'event': sse.event, 'data': data};
        continue;
      }

      if (sse.event == 'error') {
        throw APIError(null, (data is Map ? data['error'] : null) ?? data, null, response.headers);
      }

      if (data is Map && _truthy(data['error'])) {
        throw APIError(null, data['error'], null, response.headers);
      }

      yield (data as Map).cast<String, Object?>();
    }
  } on http.RequestAbortedException {
    if (!aborted()) {
      rethrow;
    }
  }
}

Object? _parse(ServerSentEvent sse) {
  try {
    return jsonDecode(sse.data);
  } on FormatException {
    throw const FormatException('Error reading response: malformed server-sent event JSON.');
  }
}

// JavaScript's truthiness, for the SDK's `data.error` test.
bool _truthy(Object? value) {
  return switch (value) {
    null || false || '' => false,
    final num n => n != 0 && !n.isNaN,
    _ => true,
  };
}

class _Decoder {
  String? _event;
  var _data = <String>[];
  var _raw = <String>[];

  ServerSentEvent? decode(String line) {
    if (line.isEmpty) {
      // A blank line ends an event, unless none was started.
      if ((_event?.isEmpty ?? true) && _data.isEmpty) {
        return null;
      }

      final event = ServerSentEvent(_event, _data.join('\n'), _raw);
      _event = null;
      _data = [];
      _raw = [];
      return event;
    }

    // A comment line (`: ...`) has an empty field name, so it sets nothing.
    _raw.add(line);
    final colon = line.indexOf(':');
    final rest = colon == -1 ? '' : line.substring(colon + 1);
    final value = rest.startsWith(' ') ? rest.substring(1) : rest;
    switch (colon == -1 ? line : line.substring(0, colon)) {
      case 'event':
        _event = value;
      case 'data':
        _data.add(value);
    }

    return null;
  }
}
