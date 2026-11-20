# openai_sdk_lite_dart

The part of the OpenAI API client that chorus uses, and nothing else. It follows the official TypeScript SDK
([openai-node](https://github.com/openai/openai-node) v7.19.0), cut down to exactly what pi's OpenAI Responses provider
(`packages/ai/src/api/openai-responses.ts`) calls in that SDK.

## What it has

- `OpenAI(apiKey, baseURL, defaultHeaders, httpClient)`. The key is sent as `Authorization: Bearer`; a default header
  overrides it.
- `client.responses.create(params, RequestOptions(signal:, timeout:))`: `params` is the JSON body as a map, and must
  stream (`'stream': true`). Once the response headers arrive it returns `(data:, response:)`, like the TypeScript
  SDK's `create(...).withResponse()`: `data` is the stream of JSON events, decoded from the server-sent events as the
  SDK's `Stream` decodes them. It ends at `[DONE]`, throws an `APIError` for an `error` event or an event whose data
  has an `error`, and ends quietly once the request is aborted. Cancelling its subscription ends the request.
- The TypeScript SDK's error classes: an error response throws an `APIError` subclass for its status
  (`BadRequestError`, `RateLimitError`, `InternalServerError`...) with `status`, `headers`, `requestID`, the body's
  `error` object, its `code`, `param` and `type`, and `message`. A connection failure throws `APIConnectionError`, a
  timeout `APIConnectionTimeoutError`, and an abort before the response `APIUserAbortError`.

Requests are never retried, as pi passes `maxRetries: 0` and retries itself, and nothing is read from the environment.

## Use

```dart
import 'package:openai_sdk_lite_dart/openai_sdk_lite_dart.dart';

final client = OpenAI(apiKey: key, baseURL: 'https://api.openai.com/v1');
final (:data, :response) = await client.responses.create({
  'model': 'gpt-5.5',
  'input': 'Hello',
  'stream': true,
});
await for (final event in data) {
  print(event['type']);
}
```

## Tests

`dart test` runs against a mock HTTP client and a local socket; nothing in it calls the real API. The server-sent event
decoding tests are ported from the TypeScript SDK's.

## License

Apache-2.0, like the TypeScript SDK it is derived from. See `LICENSE` and `NOTICE`.
