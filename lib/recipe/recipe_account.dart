import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The Supabase project. Empty is a supported state, the way an empty
/// `PHOTO_PROXY` is: a fresh checkout, the desktop harness and every run of
/// `flutter test` have no accounts at all, and Settings shows no panel.
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');

/// Safe to compile in: it identifies the project, and row level security is
/// what keeps one user out of another's rows.
const _publishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

/// The "Web application" OAuth client, which Supabase checks the ID token's
/// audience against. Android needs it as `serverClientId`; iOS needs its own
/// client id as well.
const _googleWebClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
const _googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

/// The app's own server — the photo proxy has grown an account route, so the
/// name is historical.
const _server = String.fromEnvironment('PHOTO_PROXY');

bool get accountsOn => _supabaseUrl.isNotEmpty;

/// Who this phone is signed in as: [email] is null for the anonymous user every
/// install starts as. Null itself until a session exists, which offline can be
/// a while — nothing in the app waits on it.
typedef Account = ({String id, String? email});

final account = ValueNotifier<Account?>(null);

GoTrueClient get _auth => Supabase.instance.client.auth;

/// Starts the session: the one saved on the phone if there is one, otherwise a
/// fresh anonymous user. Never awaited by `main()` — a recipe app that can't
/// open in a kitchen with no signal has its priorities wrong.
Future<void> startAccount() async {
  if (!accountsOn) return;
  await Supabase.initialize(
    url: _supabaseUrl,
    publishableKey: _publishableKey,
  );
  _show(_auth.currentUser);
  _auth.onAuthStateChange.listen((state) => _show(state.session?.user));
  // Offline at launch is the case this covers: the next time the app comes
  // back to the foreground, try again.
  AppLifecycleListener(onResume: () => unawaited(_ensureUser()));
  await _ensureUser();
}

void _show(User? user) => account.value = user == null
    ? null
    : (id: user.id, email: user.isAnonymous ? null : user.email);

Future<void> _ensureUser() async {
  if (_auth.currentUser != null) return;
  try {
    await _auth.signInAnonymously();
  } catch (e) {
    debugPrint('Anonymous sign-in failed, will retry on resume: $e');
  }
}

/// Links a provider to this phone's user, or switches to the user that
/// provider already belongs to.
///
/// The second case is a second phone: its anonymous user is new, but the
/// Google account was linked on the first phone, so linking fails with
/// `identity_already_exists`. Signing in with the same token moves this phone
/// onto that user. The abandoned anonymous user costs nothing to leave behind.
@visibleForTesting
Future<void> linkOrSwitch({
  required Future<void> Function() link,
  required Future<void> Function() signIn,
}) async {
  try {
    await link();
  } on AuthException catch (e) {
    if (e.code != ErrorCode.identityAlreadyExists.code) rethrow;
    await signIn();
  }
}

Future<void> _linkOrSignIn(
  OAuthProvider provider,
  String idToken, {
  String? nonce,
}) {
  Future<void> signIn() =>
      _auth.signInWithIdToken(provider: provider, idToken: idToken, nonce: nonce);
  // No session at all — anonymous sign-in never got through — is nothing to
  // link to.
  if (_auth.currentUser == null) return signIn();
  return linkOrSwitch(
    link: () => _auth.linkIdentityWithIdToken(
      provider: provider,
      idToken: idToken,
      nonce: nonce,
    ),
    signIn: signIn,
  );
}

/// v7 of google_sign_in must be initialised exactly once before anything else.
/// A top-level final is lazy, so this runs on the first Google sign-in.
final Future<void> _googleReady = GoogleSignIn.instance.initialize(
  clientId: Platform.isIOS ? _googleIosClientId : null,
  serverClientId: _googleWebClientId,
);

/// Throws on cancel and on failure alike; Settings answers both with a
/// SnackBar.
Future<void> signInWithGoogle() async {
  await _googleReady;
  final user = await GoogleSignIn.instance.authenticate();
  final idToken = user.authentication.idToken;
  if (idToken == null) throw const AuthException('Google gave no ID token');
  await _linkOrSignIn(OAuthProvider.google, idToken);
}

/// iOS only, and unverified until it runs on a Mac (see CLAUDE.md).
Future<void> signInWithApple() async {
  final rawNonce = _auth.generateRawNonce();
  final credential = await SignInWithApple.getAppleIDCredential(
    scopes: [AppleIDAuthorizationScopes.email],
    // Apple embeds the hash; Supabase is handed the raw value and checks one
    // against the other.
    nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
  );
  final idToken = credential.identityToken;
  if (idToken == null) throw const AuthException('Apple gave no ID token');
  await _linkOrSignIn(OAuthProvider.apple, idToken, nonce: rawNonce);
}

/// Leaves the account, keeping every recipe on the phone, and carries on as a
/// new anonymous user. Signing back in returns to the old account.
Future<void> signOut() async {
  await _auth.signOut();
  try {
    // So the next Google sign-in offers the account chooser again.
    await _googleReady;
    await GoogleSignIn.instance.signOut();
  } catch (_) {
    // Never signed in with Google, or no plugin on this platform.
  }
  await _ensureUser();
}

/// Deletes the user on the server, then signs out. Recipes are files on the
/// phone and stay; only what the account held is gone.
Future<void> deleteAccount() async {
  final token = _auth.currentSession?.accessToken;
  if (token == null) throw const AuthException('Not signed in');
  final client = HttpClient();
  try {
    final request = await client.deleteUrl(Uri.parse(_server).resolve('me'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode != HttpStatus.noContent) {
      throw HttpException('Delete failed: ${response.statusCode}');
    }
  } finally {
    client.close();
  }
  await signOut();
}
