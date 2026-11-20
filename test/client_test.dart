import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openai_sdk_lite_dart/openai_sdk_lite_dart.dart';
import 'package:test/test.dart';

const _params = {'model': 'gpt-5.5', 'input': 'hi', 'stream': true};

/// A client whose requests [handler] answers.
OpenAI client(Future<http.Response> Function(http.Request request) handler, {Map<String, String> headers = const {}}) {
  return OpenAI(
    apiKey: 'key',
    baseURL: 'https://example.test/v1/',
    defaultHeaders: headers,
    httpClient: MockClient(handler),
  );
}

http.Response sse(String body, [Map<String, String> headers = const {}]) {
  return http.Response(body, 200, headers: {'content-type': 'text/event-stream', ...headers});
}

http.Response json(int status, Object? body, [Map<String, String> headers = const {}]) {
  return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...headers});
}

/// The events of a request answered with [body].
Future<List<Map<String, Object?>>> events(String body) async {
  return (await client((_) async => sse(body)).responses.create(_params)).data.toList();
}

void main() {
  test('create posts the body with auth to /responses and decodes the events', () async {
    late http.Request sent;
    final (:data, :response) = await client((request) async {
      sent = request;
      return sse(
        'event: response.created\ndata: {"type":"response.created"}\n\ndata: {"type":"response.completed"}\n\n',
        {'x-request-id': 'req_1'},
      );
    }).responses.create(_params);
    expect(await data.toList(), [
      {'type': 'response.created'},
      {'type': 'response.completed'},
    ]);
    expect((response.statusCode, response.headers['x-request-id']), (200, 'req_1'));
    expect((sent.method, sent.url.toString()), ('POST', 'https://example.test/v1/responses'));
    expect(sent.headers['authorization'], 'Bearer key');
    expect(sent.headers['accept'], 'application/json');
    expect(sent.headers['content-type'], startsWith('application/json'));
    expect(jsonDecode(sent.body), _params);
  });

  test('default headers are sent and override auth, but not the content type', () async {
    late http.Request sent;
    await client(
      (request) async {
        sent = request;
        return sse('');
      },
      headers: {'Authorization': 'Bearer other', 'x-client-request-id': 'session', 'Content-Type': 'text/plain'},
    ).responses.create(_params);
    expect(sent.headers['authorization'], 'Bearer other');
    expect(sent.headers['x-client-request-id'], 'session');
    expect(sent.headers['content-type'], startsWith('application/json'));
  });

  test('an empty api key is refused, as are unstreamed requests', () {
    expect(() => OpenAI(apiKey: '', baseURL: 'https://example.test'), throwsA(isA<OpenAIError>()));
    expect(() => client((_) async => sse('')).responses.create({'model': 'm'}), throwsArgumentError);
  });

  group('error responses', () {
    for (final (status, type) in [
      (400, BadRequestError),
      (401, AuthenticationError),
      (403, PermissionDeniedError),
      (404, NotFoundError),
      (409, ConflictError),
      (422, UnprocessableEntityError),
      (429, RateLimitError),
      (500, InternalServerError),
      (503, InternalServerError),
      (418, APIError),
    ]) {
      test('$status throws $type', () async {
        final error = await client(
          (_) async => json(
            status,
            {
              'error': {'message': 'nope', 'type': 'invalid_request_error', 'code': 'bad', 'param': 'input'},
            },
            {'x-request-id': 'req_2'},
          ),
        ).responses.create(_params).then<APIError>((_) => fail('no error'), onError: (Object e) => e as APIError);
        expect(error.runtimeType, type);
        expect(error.name, '$type');
        expect((error.status, error.message, error.requestID), (status, '$status nope', 'req_2'));
        expect((error.type, error.code, error.param), ('invalid_request_error', 'bad', 'input'));
        expect(error.error, {'message': 'nope', 'type': 'invalid_request_error', 'code': 'bad', 'param': 'input'});
      });
    }

    test('a body without a message, a text body and no body', () async {
      Future<String?> message(http.Response response) {
        return client((_) async => response).responses
            .create(_params)
            .then((_) => null, onError: (Object e) => (e as APIError).message);
      }

      expect(
        await message(
          json(400, {
            'error': {'code': 'x'},
          }),
        ),
        '400 {"code":"x"}',
      );
      expect(await message(http.Response('Bad gateway', 502)), '502 Bad gateway');
      expect(await message(http.Response('', 500)), '500 status code (no body)');
    });

    test('a connection failure throws APIConnectionError with its cause', () async {
      final cause = http.ClientException('refused');
      await expectLater(
        client((_) async => throw cause).responses.create(_params),
        throwsA(
          isA<APIConnectionError>()
              .having((e) => e.cause, 'cause', same(cause))
              .having((e) => e.message, 'message', 'Connection error.'),
        ),
      );
    });
  });

  group('stream events', () {
    test('end at [DONE], ignoring the rest', () async {
      expect(await events('data: {"a":1}\n\ndata: [DONE]\n\ndata: {"b":2}\n\n'), [
        {'a': 1},
      ]);
    });

    test('an error event throws its error, or the whole event', () async {
      await expectLater(
        events('event: error\ndata: {"type":"error","code":"server_error","message":"Boom"}\n\n'),
        throwsA(isA<APIError>().having((e) => (e.status, e.message, e.code), 'error', (null, 'Boom', 'server_error'))),
      );
      await expectLater(
        events('event: error\ndata: {"error":{"message":"Inner"}}\n\n'),
        throwsA(isA<APIError>().having((e) => e.message, 'message', 'Inner')),
      );
    });

    test('data with an error throws it; a falsy error does not', () async {
      await expectLater(
        events('data: {"a":1}\n\ndata: {"error":{"message":"Bad"}}\n\n'),
        throwsA(isA<APIError>().having((e) => e.message, 'message', 'Bad')),
      );
      expect(await events('data: {"error":null}\n\ndata: {"error":""}\n\n'), hasLength(2));
    });

    test('malformed data throws', () async {
      await expectLater(events('data: {nope\n\n'), throwsFormatException);
    });

    test('an abort ends the stream quietly, even with events already received', () async {
      final signal = Completer<void>();
      final (:data, response: _) = await client(
        (_) async => sse([for (var i = 0; i < 20; i++) 'data: {"i":$i}\n\n'].join()),
      ).responses.create(_params, RequestOptions(signal: signal.future));
      final seen = <Object?>[];
      await for (final event in data) {
        seen.add(event['i']);
        signal.complete();
        await Future<void>.delayed(Duration.zero);
      }

      expect(seen, [0]);
    });

    test('thread events come with their name', () async {
      expect(await events('event: thread.created\ndata: {"id":"t"}\n\n'), [
        {
          'event': 'thread.created',
          'data': {'id': 't'},
        },
      ]);
    });
  });

  group('against a real server', () {
    late ServerSocket server;
    late OpenAI openai;
    late Completer<void> gone;
    var delay = Duration.zero;

    // A raw socket, since dart:io's HttpServer never notices a client that leaves mid-stream. After [delay] it streams
    // up to 500 events, 20 ms apart; [gone] completes when the client closes the connection.
    setUp(() async {
      gone = Completer<void>();
      delay = Duration.zero;
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) async {
        socket.listen(
          (_) {},
          onDone: () {
            if (!gone.isCompleted) {
              gone.complete();
            }
          },
          onError: (Object _) {},
        );
        await Future<void>.delayed(delay);
        socket.write('HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n');
        try {
          for (var i = 0; i < 500 && !gone.isCompleted; i++) {
            final data = utf8.encode('data: {"i":$i}\n\n');
            socket
              ..write('${data.length.toRadixString(16)}\r\n')
              ..add(data)
              ..write('\r\n');
            await socket.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        } on Object {
          // The client went away.
        }

        socket.destroy();
      });
      openai = OpenAI(apiKey: 'key', baseURL: 'http://127.0.0.1:${server.port}');
    });

    tearDown(() async {
      openai.close();
      await server.close();
    });

    test('an abort before the response throws APIUserAbortError', () async {
      final signal = Completer<void>();
      delay = const Duration(seconds: 2);
      final request = openai.responses.create(_params, RequestOptions(signal: signal.future));
      signal.complete();
      await expectLater(request, throwsA(isA<APIUserAbortError>()));
    });

    test('a timeout before the response throws APIConnectionTimeoutError', () async {
      delay = const Duration(seconds: 2);
      await expectLater(
        openai.responses.create(_params, const RequestOptions(timeout: Duration(milliseconds: 100))),
        throwsA(isA<APIConnectionTimeoutError>()),
      );
    });

    test('an abort during the stream ends it quietly', () async {
      final signal = Completer<void>();
      final (:data, response: _) = await openai.responses.create(_params, RequestOptions(signal: signal.future));
      final seen = <Object?>[];
      await for (final event in data) {
        seen.add(event['i']);
        if (seen.length == 3) {
          signal.complete();
        }
      }

      expect(seen.length, lessThan(10));
      await gone.future.timeout(const Duration(seconds: 5));
    });

    test('cancelling the subscription ends the request', () async {
      final (:data, response: _) = await openai.responses.create(_params);
      expect(await data.take(2).toList(), [
        {'i': 0},
        {'i': 1},
      ]);
      await gone.future.timeout(const Duration(seconds: 5));
    });
  });
}
