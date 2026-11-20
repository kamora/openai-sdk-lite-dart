// Streams a reply from the Responses API and prints its text. Run with a key in the environment:
//
//     OPENAI_API_KEY=... dart run example/example.dart

import 'dart:io';

import 'package:openai_sdk_lite_dart/openai_sdk_lite_dart.dart';

Future<void> main() async {
  final client = OpenAI(apiKey: Platform.environment['OPENAI_API_KEY'] ?? '', baseURL: 'https://api.openai.com/v1');
  try {
    final (:data, :response) = await client.responses.create({
      'model': 'gpt-6-luna',
      'input': 'Say hello in French.',
      'stream': true,
    });
    stdout.writeln('status ${response.statusCode}');
    await for (final event in data) {
      if (event['type'] == 'response.output_text.delta') {
        stdout.write(event['delta']);
      }
    }

    stdout.writeln();
  } on APIError catch (error) {
    stderr.writeln('${error.name}: ${error.message}');
  } finally {
    client.close();
  }
}
