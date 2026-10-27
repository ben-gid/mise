import 'dart:convert';
import 'dart:io';

import 'recipe_account.dart';
import 'recipe_parser.dart';

/// The app's own server, as in recipe_account.dart.
const _server = String.fromEnvironment('PHOTO_PROXY');

/// Whether this build can ask the server for a recipe. Off with no accounts or
/// no server, which is every run of `flutter test` and the desktop harness —
/// the controls that would ask are not shown at all.
bool get serverRecipesOn => accountsOn && _server.isNotEmpty;

/// Anything but a recipe that failed the checks, already worded for a
/// SnackBar. That one is a [RecipeValidationException], so it lands in the
/// same error list a bad paste does.
class ServerRecipeException implements Exception {
  final String message;
  const ServerRecipeException(this.message);

  @override
  String toString() => message;
}

/// The free tries are gone. Its own type so the screens that ask can offer
/// Pro instead of only saying so.
class OutOfTriesException extends ServerRecipeException {
  const OutOfTriesException() : super('You\'ve used your five free recipes.');
}

/// Asks the server to write a recipe, and returns it as raw JSON.
///
/// Raw, because it is untrusted like any paste: the caller puts it through
/// [RecipeParser.parse] before it goes anywhere near the store. The server
/// checks it with the same schema and fixtures first, so that should never
/// fail — but the phone's check is the one that counts.
///
/// One kind of material: [text] alone is a dish to write; with [base] it is
/// the change to make to that recipe. [url] is a page, [image] a photo of a
/// recipe as (media type, bytes).
Future<String> askForRecipe({
  String? text,
  String? url,
  (String, List<int>)? image,
  Map<String, dynamic>? base,
}) => _post('recipe', {
  'text': ?text,
  'url': ?url,
  if (image != null) ...{
    'image_type': image.$1,
    'image': base64Encode(image.$2),
  },
  'base': ?base,
});

/// One question the server puts to the cook before a recipe is written, and
/// the options it offers, each with a [Option.why]: what in the recipe makes it
/// so. The whys are what the finished recipe's headnote explains.
class Fork {
  final String question;
  final List<Option> options;
  const Fork(this.question, this.options);
}

typedef Option = ({String label, String why});

/// The forks worth asking about [idea]. With [brief] — the first round's
/// answers — this is the second and last round, and an empty list means there
/// is nothing left to ask. Free: only the recipe spends a try.
Future<List<Fork>> askQuestions(String idea, {String? brief}) async =>
    parseForks(await _post('questions', {'idea': idea, 'brief': ?brief}));

/// The server's answer as [Fork]s, by hand like the photo list. Anything
/// malformed is skipped rather than thrown: a question less is not an error.
List<Fork> parseForks(String body) => [
  for (final q
      in (jsonDecode(body) as Map<String, dynamic>)['questions'] as List)
    if (q case {'question': final String question, 'options': final List o})
      Fork(question, [
        for (final option in o)
          if (option case {
            'label': final String label,
            'why': final String why,
          })
            (label: label, why: why),
      ]),
];

/// What a cook chose, and what Create sends as the recipe's text: the idea,
/// then one line per question answered. Null in [choices] is "You pick", which
/// is said rather than left out, so the model knows it was asked and makes the
/// call. Also what the second round of questions is told, so it never asks the
/// first round's again.
String brief(String idea, List<(Fork, Option?)> choices, List<String> extra) =>
    [
      idea,
      if (choices.isNotEmpty) ...[
        '',
        'What the cook chose:',
        for (final (fork, option) in choices)
          option == null
              ? '- ${fork.question} Your call.'
              : '- ${fork.question} ${option.label}: ${option.why}',
      ],
      for (final more in extra)
        if (more.trim().isNotEmpty) 'Also: ${more.trim()}',
    ].join('\n');

/// One authenticated POST to the server, answering its body on a 200 and
/// throwing the exception each other status means.
Future<String> _post(String path, Map<String, Object?> json) async {
  final token = accessToken;
  if (token == null) {
    throw const ServerRecipeException(
      'Still signing in — try again in a moment.',
    );
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.postUrl(Uri.parse(_server).resolve(path));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..contentType = ContentType.json;
    request.write(jsonEncode(json));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    switch (response.statusCode) {
      case HttpStatus.ok:
        return body;
      case HttpStatus.unprocessableEntity:
        final errors = (jsonDecode(body) as Map<String, dynamic>)['errors'];
        if (errors is List) {
          throw RecipeValidationException(errors.cast<String>());
        }
      case HttpStatus.paymentRequired:
        throw const OutOfTriesException();
      case HttpStatus.tooManyRequests:
        // The hourly limit or Pro's monthly one; the server words both.
        final detail = (jsonDecode(body) as Map<String, dynamic>)['detail'];
        throw ServerRecipeException(
          detail is String ? detail : 'Too many recipes. Try again later.',
        );
      case HttpStatus.serviceUnavailable:
        throw const ServerRecipeException(
          'Recipe writing isn\'t available right now.',
        );
    }
    throw ServerRecipeException(
      'The recipe server answered ${response.statusCode}. Try again.',
    );
  } on IOException {
    throw const ServerRecipeException('Couldn\'t reach the recipe server.');
  } finally {
    client.close();
  }
}

/// The media type the server should be told for a picked photo's [name].
String photoType(String name) => switch (name.split('.').last.toLowerCase()) {
  'png' => 'image/png',
  'webp' => 'image/webp',
  _ => 'image/jpeg',
};
