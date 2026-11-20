import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'streaming.dart';

/// Options for one request.
class RequestOptions {
  const RequestOptions({this.signal, this.timeout});

  /// Aborts the request when it completes: before the response, [create](Responses.create) throws an
  /// [APIUserAbortError]; after, the event stream ends quietly.
  final Future<void>? signal;

  /// How long to wait for the response headers; ten minutes when not set.
  final Duration? timeout;
}

/// A streamed response: its [data] events, and the [response] whose status and headers they came with. The events
/// read the response's body, so it must not be read otherwise.
typedef ResponseStream = ({Stream<Map<String, Object?>> data, http.BaseResponse response});

/// The client for the OpenAI API, like the TypeScript SDK's `OpenAI`, with only what chorus uses.
///
/// [apiKey] is sent as `Authorization: Bearer`; a header in [defaultHeaders] overrides it. Nothing is read from the
/// environment, and requests are never retried: the caller retries, reading the [APIError]'s status and headers.
class OpenAI {
  factory OpenAI({
    required String apiKey,
    required String baseURL,
    Map<String, String> defaultHeaders = const {},
    http.Client? httpClient,
  }) {
    if (apiKey.isEmpty) {
      throw OpenAIError('Missing credentials. Please pass an `apiKey`.');
    }

    return OpenAI._(
      apiKey,
      baseURL.replaceFirst(RegExp(r'/+$'), ''),
      defaultHeaders,
      httpClient ?? http.Client(),
      httpClient == null,
    );
  }

  OpenAI._(this._key, this._base, this._headers, this._http, this._owns);

  final String _key;
  final String _base;
  final Map<String, String> _headers;
  final http.Client _http;
  final bool _owns;

  late final responses = Responses(this);

  /// Closes the HTTP client when this client created it.
  void close() {
    if (_owns) {
      _http.close();
    }
  }

  Future<ResponseStream> _stream(String path, Map<String, Object?> body, RequestOptions options) async {
    final abort = Completer<void>();
    var timedOut = false;
    var aborted = false;

    void fire() {
      if (!abort.isCompleted) {
        abort.complete();
      }
    }

    final timer = Timer(options.timeout ?? const Duration(minutes: 10), () {
      timedOut = true;
      fire();
    });
    options.signal?.then((_) {
      aborted = true;
      fire();
    });

    // Later headers override earlier ones, ignoring case.
    final request = http.AbortableRequest('POST', Uri.parse('$_base$path'), abortTrigger: abort.future)
      ..headers['accept'] = 'application/json'
      ..headers['authorization'] = 'Bearer $_key'
      ..headers.addAll(_headers)
      ..headers['content-type'] = 'application/json'
      ..bodyBytes = utf8.encode(jsonEncode(body));
    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } on http.RequestAbortedException {
      if (timedOut) {
        throw APIConnectionTimeoutError();
      }

      throw APIUserAbortError();
    } on http.ClientException catch (error) {
      throw APIConnectionError(cause: error);
    } finally {
      timer.cancel();
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return (data: responseEvents(response, aborted: () => aborted), response: response);
    }

    final text = await response.stream.bytesToString();
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      json = null;
    }

    throw APIError.generate(response.statusCode, json, json == null ? text : null, response.headers);
  }
}

/// The Responses API.
class Responses {
  Responses(this._client);

  final OpenAI _client;

  /// Sends a streamed response request with [params] as its JSON body, in the API's own snake_case shape, and returns
  /// its events once the response headers arrive, as the TypeScript SDK's `create(...).withResponse()` does.
  ///
  /// Only streamed requests are supported: `stream` must be true. A failed response throws an [APIError].
  Future<ResponseStream> create(Map<String, Object?> params, [RequestOptions options = const RequestOptions()]) {
    if (params['stream'] != true) {
      throw ArgumentError.value(
        params['stream'],
        "params['stream']",
        'must be true; only streamed requests are supported',
      );
    }

    return _client._stream('/responses', params, options);
  }
}
