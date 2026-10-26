import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_account.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('a Google account new to mise is linked to this phone', () async {
    final calls = <String>[];

    await linkOrSwitch(
      link: () async => calls.add('link'),
      signIn: () async => calls.add('signIn'),
    );

    expect(calls, ['link']);
  });

  test('an account already used on another phone is switched to', () async {
    final calls = <String>[];

    await linkOrSwitch(
      link: () async {
        calls.add('link');
        throw const AuthException(
          'Identity is already linked to another user',
          code: 'identity_already_exists',
        );
      },
      signIn: () async => calls.add('signIn'),
    );

    expect(calls, ['link', 'signIn']);
  });

  test('a new provider carrying a known email is switched to', () async {
    final calls = <String>[];

    await linkOrSwitch(
      link: () async {
        calls.add('link');
        throw const AuthException(
          'A user with this email address has already been registered',
          code: 'email_exists',
        );
      },
      signIn: () async => calls.add('signIn'),
    );

    expect(calls, ['link', 'signIn']);
  });

  test('any other failure is not papered over with a sign-in', () async {
    final calls = <String>[];

    await expectLater(
      linkOrSwitch(
        link: () async => throw const AuthException('offline'),
        signIn: () async => calls.add('signIn'),
      ),
      throwsA(isA<AuthException>()),
    );
    expect(calls, isEmpty);
  });

  test('accounts are off in a build with no Supabase url', () {
    // Every test run, and the desktop harness: nothing to initialise, nothing
    // for Settings to show.
    expect(accountsOn, isFalse);
  });
}
