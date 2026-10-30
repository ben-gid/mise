import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../recipe_models.dart';
import '../recipe_parser.dart';
import '../recipe_server.dart';
import '../recipe_store.dart';
import 'glass.dart';
import 'import_recipe_screen.dart' show ErrorList;
import 'pro_screen.dart' show writeOrUpgrade;
import 'writing.dart';

/// A recipe made up from a sentence, by the server, laid out as a chat: what
/// the cook said and chose scrolls above, and one thing at a time sits at the
/// bottom — the composer, then each question in its place, then the round's
/// last word and its buttons. Waiting is a line in the conversation, not a
/// dialog over it.
///
/// With "Ask me" on, the server first puts two to four forks to the cook —
/// crisp or gooey, beef or beef and pork — each option with the why behind
/// it. Submit asks a second round, which the server may decline; there is
/// never a third. Create writes whatever has been chosen so far, and the
/// headnote explains the choices.
///
/// Only pushed when [serverRecipesOn], so never under `flutter test` — the
/// progress line animates forever, which `pumpAndSettle` would never get past.
class CreateRecipeScreen extends StatefulWidget {
  final RecipeStore store;
  final RecipeParser parser;

  const CreateRecipeScreen({
    super.key,
    required this.store,
    required this.parser,
  });

  @override
  State<CreateRecipeScreen> createState() => _CreateRecipeScreenState();
}

class _CreateRecipeScreenState extends State<CreateRecipeScreen> {
  final _input = TextEditingController();
  final _note = TextEditingController();
  final _scroll = ScrollController();
  bool _askMe = true;

  /// The idea as sent; null until the cook sends one.
  String? _idea;

  /// The rounds asked so far, at most two, and each one's "anything else".
  final _rounds = <List<Fork>>[];
  final _extra = <String>[];

  /// How many of the latest round's questions are answered. Equal to its
  /// length once they all are, which is when its buttons show.
  int _step = 0;

  /// The option chosen per answered fork; answered and absent is "You pick".
  final _picked = <Fork, Option>{};

  /// What is being waited on, as [Writing]'s verbs at the end of the chat;
  /// null when idle.
  List<String>? _busy;
  String? _failed;
  List<String> _errors = const [];

  @override
  void initState() {
    super.initState();
    widget.store.askMe().then((on) {
      if (mounted) setState(() => _askMe = on);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _note.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _answered(int round, int index) =>
      round < _rounds.length - 1 || index < _step;

  String get _brief => brief(_idea!, [
    for (final (r, round) in _rounds.indexed)
      for (final (i, fork) in round.indexed)
        if (_answered(r, i)) (fork, _picked[fork]),
  ], _extra);

  /// Whatever just landed at the end of the chat, brought into view.
  /// Whatever just landed at the end of the chat, brought into view — once
  /// the bottom panel has finished resizing, or the end it scrolled to moves.
  void _toEnd() => Future.delayed(const Duration(milliseconds: 220), () {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  });

  void _wait(List<String> busy) {
    setState(() {
      _busy = busy;
      _failed = null;
      _errors = const [];
    });
    _toEnd();
  }

  Future<void> _send() async {
    final idea = _input.text.trim();
    if (idea.isEmpty) return;
    setState(() => _idea = idea);
    _input.clear();
    _askMe ? await _ask() : await _create();
  }

  /// Keeps the round's note before moving on, overwriting rather than
  /// appending, so a failed Create retried sends it once rather than twice.
  void _keepNote() {
    final round = _rounds.isEmpty ? 0 : _rounds.length - 1;
    while (_extra.length <= round) {
      _extra.add('');
    }
    _extra[round] = _note.text;
  }

  /// The first round, or the second once there is one to answer. Nothing to
  /// ask goes straight to writing: the cook pressed a button to move on.
  Future<void> _ask() async {
    final second = _rounds.isNotEmpty;
    if (second) _keepNote();
    FocusScope.of(context).unfocus();
    _wait(const ['Thinking of questions…']);
    final List<Fork> forks;
    try {
      forks = await askQuestions(_idea!, brief: second ? _brief : null);
    } on ServerRecipeException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _failed = e.message;
        // Nothing asked yet: hand the idea back so sending again is one tap.
        if (!second) {
          _input.text = _idea!;
          _idea = null;
        }
      });
      return;
    }
    if (!mounted) return;
    if (forks.isEmpty) return _create();
    _note.clear();
    setState(() {
      _busy = null;
      _rounds.add(forks);
      _step = 0;
    });
    _toEnd();
  }

  Future<void> _create() async {
    _keepNote();
    FocusScope.of(context).unfocus();
    final text = _brief;
    final verbs = verbsFor(text);
    _wait(verbs);
    final Recipe recipe;
    try {
      recipe = widget.parser.parse(
        await writeOrUpgrade(
          context,
          verbs,
          () => askForRecipe(text: text),
          inline: true,
        ),
      );
    } on RecipeValidationException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _errors = e.errors;
      });
      _toEnd();
      return;
    } on ServerRecipeException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _failed = e.message;
      });
      _toEnd();
      return;
    }
    final id = await widget.store.save(recipe);
    if (mounted) Navigator.pop(context, (id, recipe));
  }

  void _pick(Option? option) {
    final fork = _rounds.last[_step];
    setState(() {
      option == null ? _picked.remove(fork) : _picked[fork] = option;
      _step++;
    });
    _toEnd();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // No app bar to set the status bar's icons, so say it here.
      value: theme.brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: RoundBackButton(),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Create a recipe',
                      style: theme.textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _askMe
                          ? 'Say what you want to make. mise asks about '
                                'texture, flavour and look, then writes it.'
                          : 'Say what you want to make. mise writes it.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ..._transcript(),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.bottomCenter,
                  child: _bottom(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _transcript() => [
    if (_idea case final idea?) _Bubble(idea),
    for (final (r, round) in _rounds.indexed) ...[
      _Said(r == 0 ? 'A few questions first.' : 'One more thing.'),
      if ([
            for (final (i, fork) in round.indexed)
              if (_answered(r, i))
                (fork.question, _picked[fork]?.label ?? 'You pick'),
            if (r < _extra.length && _extra[r].trim().isNotEmpty)
              (null, _extra[r].trim()),
          ]
          case final answers when answers.isNotEmpty)
        _Answers(answers),
    ],
    if (_busy case final busy?)
      Padding(padding: const EdgeInsets.only(bottom: 14), child: Writing(busy)),
    if (_failed case final failed?) _Said(failed, error: true),
    if (_errors.isNotEmpty)
      ErrorList(errors: _errors, tip: 'Try Create again.'),
  ];

  /// One thing at a time: the composer, a question, or the round's buttons.
  /// Nothing while waiting — the chat says what is happening.
  Widget _bottom() {
    if (_busy != null) return const SizedBox(width: double.infinity);
    if (_idea == null) {
      return _Composer(
        controller: _input,
        askMe: _askMe,
        onAskMe: (on) {
          setState(() => _askMe = on);
          widget.store.setAskMe(on);
        },
        onSend: _send,
      );
    }
    if (_rounds.isNotEmpty && _step < _rounds.last.length) {
      return _Question(
        key: ValueKey(_rounds.last[_step]),
        fork: _rounds.last[_step],
        position: '${_step + 1} of ${_rounds.last.length}',
        onPick: _pick,
        onBack: _step == 0 ? null : () => setState(() => _step--),
      );
    }
    return _Finish(
      note: _note,
      onBack: _rounds.isEmpty ? null : () => setState(() => _step--),
      onSubmit: _askMe && _rounds.length == 1 ? _ask : null,
      onCreate: _create,
    );
  }
}

/// The cook's side of the chat: their words on a tinted bubble, to the right.
class _Bubble extends StatelessWidget {
  final String text;
  const _Bubble(this.text);

  @override
  Widget build(BuildContext context) =>
      _Tinted(child: Text(text, style: Theme.of(context).textTheme.bodyLarge));
}

/// A round's answers as the cook's reply: each question small and muted over
/// the answer, so a column of them reads as pairs rather than one paragraph.
/// A null question is the round's "anything else".
class _Answers extends StatelessWidget {
  final List<(String?, String)> answers;
  const _Answers(this.answers);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Tinted(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, (question, answer)) in answers.indexed) ...[
            if (i > 0) const SizedBox(height: 10),
            if (question != null)
              Text(
                question,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Text(answer, style: theme.textTheme.bodyLarge),
          ],
        ],
      ),
    );
  }
}

/// The bubble itself: tinted, to the right, short of the left edge.
class _Tinted extends StatelessWidget {
  final Widget child;
  const _Tinted({required this.child});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      margin: const EdgeInsets.only(left: 48, bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: herbWash(context),
        borderRadius: BorderRadius.circular(pillRadius),
      ),
      child: child,
    ),
  );
}

/// mise's side: plain text on the page, the way a chat model answers.
class _Said extends StatelessWidget {
  final String text;
  final bool error;

  const _Said(this.text, {this.error = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14, right: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: error ? theme.colorScheme.error : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// The box every bottom state sits in, so swapping one for another reads as
/// the same box changing rather than a new one arriving.
class _Panel extends StatelessWidget {
  final Widget child;
  const _Panel({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
    decoration: BoxDecoration(
      color: glassFill(context),
      borderRadius: BorderRadius.circular(panelRadius),
      border: Border.all(color: glassRim(context)),
    ),
    child: child,
  );
}

/// A text field that is only text: the panel around it is the field.
InputDecoration _bare(String hint) => InputDecoration(
  hintText: hint,
  filled: false,
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  contentPadding: const EdgeInsets.symmetric(vertical: 8),
);

/// The input: grows with what is typed up to six lines, then scrolls, with
/// the Ask me toggle and send under it.
class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool askMe;
  final ValueChanged<bool> onAskMe;
  final VoidCallback onSend;

  const _Composer({
    required this.controller,
    required this.askMe,
    required this.onAskMe,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          minLines: 1,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          decoration: _bare('Chocolate chip cookies'),
        ),
        Row(
          children: [
            FilterChip(
              label: const Text('Ask me'),
              selected: askMe,
              onSelected: onAskMe,
            ),
            const Spacer(),
            ValueListenableBuilder(
              valueListenable: controller,
              builder: (context, value, _) => IconButton.filled(
                onPressed: value.text.trim().isEmpty ? null : onSend,
                tooltip: askMe ? 'Ask me' : 'Create',
                icon: const Icon(Icons.arrow_upward),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// One question in the composer's place: its options as tiles, label over
/// why, and "You pick" for a question the cook doesn't care about. A tap
/// answers it and brings the next.
class _Question extends StatelessWidget {
  final Fork fork;
  final String position;
  final ValueChanged<Option?> onPick;
  final VoidCallback? onBack;

  const _Question({
    super.key,
    required this.fork,
    required this.position,
    required this.onPick,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    Widget tile(Option? option) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: theme.scaffoldBackgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(pillRadius),
          side: BorderSide(color: glassRim(context)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(pillRadius),
          onTap: () => onPick(option),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  option?.label ?? 'You pick',
                  style: weighted(theme.textTheme.bodyLarge, FontWeight.w500),
                ),
                if (option != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    option.why,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    return _Panel(
      child: ConstrainedBox(
        // A question with four long whys outgrows a phone; the chat above
        // keeps at least a sliver of itself.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(right: 4, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (onBack != null)
                    IconButton(
                      onPressed: onBack,
                      tooltip: 'Previous question',
                      icon: const Icon(Icons.arrow_back, size: 20),
                    ),
                  Expanded(
                    child: Text(
                      fork.question,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    position,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              for (final option in fork.options) tile(option),
              tile(null),
            ],
          ),
        ),
      ),
    );
  }
}

/// The end of a round, or of an idea sent with Ask me off: anything else to
/// add, then Submit (one more round, maybe) and Create.
class _Finish extends StatelessWidget {
  final TextEditingController note;
  final VoidCallback? onBack;
  final VoidCallback? onSubmit;
  final VoidCallback onCreate;

  const _Finish({
    required this.note,
    required this.onBack,
    required this.onSubmit,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: note,
          minLines: 1,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: _bare('Anything else? No nuts, a smaller batch…'),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            if (onBack != null)
              IconButton(
                onPressed: onBack,
                tooltip: 'Previous question',
                icon: const Icon(Icons.arrow_back, size: 20),
              ),
            const Spacer(),
            if (onSubmit != null) ...[
              FilledButton.tonal(
                onPressed: onSubmit,
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                ),
                child: const Text('Submit'),
              ),
              const SizedBox(width: 8),
            ],
            FilledButton(onPressed: onCreate, child: const Text('Create')),
          ],
        ),
      ],
    ),
  );
}
