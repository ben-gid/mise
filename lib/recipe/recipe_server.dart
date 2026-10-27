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
}) async {
  final token = accessToken;
  if (token == null) {
    throw const ServerRecipeException(
      'Still signing in — try again in a moment.',
    );
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.postUrl(Uri.parse(_server).resolve('recipe'));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..contentType = ContentType.json;
    request.write(
      jsonEncode({
        'text': ?text,
        'url': ?url,
        if (image != null) ...{
          'image_type': image.$1,
          'image': base64Encode(image.$2),
        },
        'base': ?base,
      }),
    );
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
        throw const ServerRecipeException(
          'That was the last free recipe. Pro is coming soon.',
        );
      case HttpStatus.tooManyRequests:
        throw const ServerRecipeException(
          'That is a lot of recipes for one hour. Try again later.',
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
