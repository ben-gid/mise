import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise/recipe/recipe_server.dart';

void main() {
  final texture = Fork('What texture?', [
    (label: 'Crisp and flat', why: 'Melted butter spreads them.'),
    (label: 'Tall and gooey', why: 'Cold butter keeps them thick.'),
  ]);
  final sweetness = Fork('How sweet?', [
    (label: 'Less', why: 'More salt.'),
    (label: 'Classic', why: 'As written.'),
  ]);

  test('forks are read from the server, skipping malformed ones', () {
    final forks = parseForks(
      jsonEncode({
        'questions': [
          {
            'question': 'What texture?',
            'options': [
              {'label': 'Crisp', 'why': 'Melted butter.'},
              {'label': 'Gooey'},
            ],
          },
          {'question': 3},
        ],
      }),
    );

    expect(forks, hasLength(1));
    expect(forks.single.options, [(label: 'Crisp', why: 'Melted butter.')]);
  });

  test('an idea with no questions is sent as it is', () {
    expect(brief('Cookies', [], ['']), 'Cookies');
  });

  test('the brief says each choice, its why, and what was left open', () {
    expect(
      brief(
        'Cookies',
        [(texture, texture.options[1]), (sweetness, null)],
        ['no nuts ', ''],
      ),
      'Cookies\n'
      '\n'
      'What the cook chose:\n'
      '- What texture? Tall and gooey: Cold butter keeps them thick.\n'
      '- How sweet? Your call.\n'
      'Also: no nuts',
    );
  });
}
