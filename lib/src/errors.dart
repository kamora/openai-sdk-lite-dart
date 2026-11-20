import 'dart:convert';

/// The base of every error the SDK throws.
class OpenAIError implements Exception {
  OpenAIError([this.message, this.cause]);

  final String? message;

  /// The error that caused this one, if any.
  final Object? cause;

  /// The error's class name, as the TypeScript SDK reports it in `error.name`.
  String get name => 'OpenAIError';

  @override
  String toString() => message == null ? name : '$name: $message';
}

/// An error returned by the API, or a failure to reach it.
class APIError extends OpenAIError {
  APIError(this.status, this.error, String? message, this.headers, [Object? cause])
    : requestID = headers?['x-request-id'],
      code = _field(error, 'code'),
      param = _field(error, 'param'),
      type = _field(error, 'type'),
      super(_message(status, error, message), cause);

  /// The HTTP status of the response, or `null` when there was no response.
  final int? status;

  /// The response headers, with lowercase names.
  final Map<String, String>? headers;

  /// The `error` object of the response body, or the error a stream event carried.
  final Object? error;

  /// The `x-request-id` header of the response.
  final String? requestID;

  /// The error's `code`, such as `rate_limit_exceeded`.
  final String? code;

  /// The error's `param`: the request field it is about.
  final String? param;

  /// The error's `type`, such as `invalid_request_error`.
  final String? type;

  @override
  String get name => 'APIError';

  static String? _field(Object? error, String key) {
    if (error is! Map) {
      return null;
    }

    final value = error[key];
    return value is String ? value : null;
  }

  static String _message(int? status, Object? error, String? message) {
    final String? text;
    if (error is Map && error['message'] != null && error['message'] != '') {
      final value = error['message'];
      text = value is String ? value : jsonEncode(value);
    } else if (error != null) {
      text = jsonEncode(error);
    } else {
      text = message;
    }

    if (status != null && (text?.isNotEmpty ?? false)) {
      return '$status $text';
    }

    if (status != null) {
      return '$status status code (no body)';
    }

    if (text?.isNotEmpty ?? false) {
      return text!;
    }

    return '(no status code or body)';
  }

  /// Builds the error class for a status code from the response [body], as the TypeScript SDK's `APIError.generate`
  /// does: the error gets the body's `error` object.
  static APIError generate(int? status, Object? body, String? message, Map<String, String>? headers) {
    if (status == null || headers == null) {
      return APIConnectionError(message: message, cause: body);
    }

    final error = body is Map ? body['error'] : null;
    return switch (status) {
      400 => BadRequestError(status, error, message, headers),
      401 => AuthenticationError(status, error, message, headers),
      403 => PermissionDeniedError(status, error, message, headers),
      404 => NotFoundError(status, error, message, headers),
      409 => ConflictError(status, error, message, headers),
      422 => UnprocessableEntityError(status, error, message, headers),
      429 => RateLimitError(status, error, message, headers),
      >= 500 => InternalServerError(status, error, message, headers),
      _ => APIError(status, error, message, headers),
    };
  }
}

/// The request was aborted by the caller before its response arrived.
class APIUserAbortError extends APIError {
  APIUserAbortError({String? message}) : super(null, null, message ?? 'Request was aborted.', null);

  @override
  String get name => 'APIUserAbortError';
}

/// The API could not be reached.
class APIConnectionError extends APIError {
  APIConnectionError({String? message, Object? cause}) : super(null, null, message ?? 'Connection error.', null, cause);

  @override
  String get name => 'APIConnectionError';
}

/// The response headers did not arrive in time.
class APIConnectionTimeoutError extends APIConnectionError {
  APIConnectionTimeoutError({String? message}) : super(message: message ?? 'Request timed out.');

  @override
  String get name => 'APIConnectionTimeoutError';
}

class BadRequestError extends APIError {
  BadRequestError(int super.status, super.error, super.message, Map<String, String> super.headers);

  @override
  String get name => 'BadRequestError';
}

class AuthenticationError extends APIError {
  AuthenticationError(int super.status, super.error, super.message, Map<String, String> super.headers);

  @override
  String get name => 'AuthenticationError';
}

class PermissionDeniedError extends APIError {
  PermissionDeniedError(int super.status, super.error, super.message, Map<String, String> super.headers);

  @override
  String get name => 'PermissionDeniedError';
}

class NotFoundError extends APIError {
  NotFoundError(int super.status, super.error, super.message, Map<String, String> super.headers);

  @override
  String get name => 'NotFoundError';
}

class ConflictError extends APIError {
  ConflictError(int super.status, super.error, super.message, Map<String, String> super.headers);

  @override
  String get name => 'ConflictError';
}

class UnprocessableEntityError extends APIError {
  UnprocessableEntityError(int super.status, super.error, super.message, Map<String, String> super.headers);

  @override
  String get name => 'UnprocessableEntityError';
}

class RateLimitError extends APIError {
  RateLimitError(int super.status, super.error, super.message, Map<String, String> super.headers);

  @override
  String get name => 'RateLimitError';
}

class InternalServerError extends APIError {
  InternalServerError(int super.status, super.error, super.message, Map<String, String> super.headers);

  @override
  String get name => 'InternalServerError';
}
