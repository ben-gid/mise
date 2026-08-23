import 'recipe_models.dart';
import 'recipe_refs.dart';
import 'recipe_scaling.dart';

/// What changed between two versions of a recipe. Pure functions — no widgets,
/// so they test directly.

/// What sort of thing a change happened to.
///
/// [countable] is what separates "+1 ingredient" from "changed the title":
/// a recipe can gain a second ingredient, but it cannot gain a second title,
/// so those only ever read as modifications.
enum ChangeKind {
  ingredient('ingredient', countable: true),
  step('step', countable: true),
  tag('tag', countable: true),
  title('title'),
  description('description'),
  servings('servings'),
  notes('notes'),
  source('source'),
  order('step order');

  const ChangeKind(this.noun, {this.countable = false});

  final String noun;
  final bool countable;
}

/// One field that differs. [before] is null for something added, [after] is
/// null for something removed; both are set for a change, and both are null
/// for a change with nothing to quote, like a reorder.
///
/// [detail] names the part that moved — "amount", "wording" — so the history
/// can say what was touched without the reader diffing two sentences by eye.
///
/// The strings are display-ready: amounts go through [amountLabel] and step
/// text through [toDisplayRefs], so a diff reads the way the recipe reads.
typedef RecipeChange = ({
  ChangeKind kind,
  String label,
  String? detail,
  String? before,
  String? after,
});

/// Every difference between [from] and [to], in reading order.
///
/// Ingredients and steps are matched by **id**, not by position: that is what
/// keeps a diff small and truthful. Because step content references `{0001}`
/// and never repeats the amount in prose, doubling the butter is one changed
/// line here rather than a change smeared across every step mentioning butter.
List<RecipeChange> diffRecipes(Recipe from, Recipe to) {
  return [
    ..._scalars(from, to),
    ..._tags(from, to),
    ..._ingredients(from, to),
    ..._steps(from, to),
  ];
}

Iterable<RecipeChange> _scalars(Recipe from, Recipe to) sync* {
  final fields = [
    (ChangeKind.title, 'Title', from.title, to.title),
    (ChangeKind.description, 'Description', from.description, to.description),
    (
      ChangeKind.servings,
      'Servings',
      '${from.baseServings}',
      '${to.baseServings}',
    ),
    (ChangeKind.notes, 'Notes', from.notes, to.notes),
    (ChangeKind.source, 'Source', from.source, to.source),
  ];
  for (final (kind, label, before, after) in fields) {
    if (before == after) continue;
    yield (
      kind: kind,
      label: label,
      detail: null,
      before: _blankToNull(before),
      after: _blankToNull(after),
    );
  }
}

/// Tags are a set, so order is not a change — only what was added or dropped.
Iterable<RecipeChange> _tags(Recipe from, Recipe to) sync* {
  for (final tag in to.tags.toSet().difference(from.tags.toSet())) {
    yield (
      kind: ChangeKind.tag,
      label: 'Tag',
      detail: null,
      before: null,
      after: tag,
    );
  }
  for (final tag in from.tags.toSet().difference(to.tags.toSet())) {
    yield (
      kind: ChangeKind.tag,
      label: 'Tag',
      detail: null,
      before: tag,
      after: null,
    );
  }
}

Iterable<RecipeChange> _ingredients(Recipe from, Recipe to) sync* {
  final before = {for (final i in from.ingredients) i.id: i};
  final after = {for (final i in to.ingredients) i.id: i};

  for (final ingredient in to.ingredients) {
    final old = before[ingredient.id];
    if (old == null) {
      yield (
        kind: ChangeKind.ingredient,
        label: 'Ingredient',
        detail: null,
        before: null,
        after: _ingredientLabel(ingredient),
      );
      continue;
    }
    // Compared as rendered, so a change too small to show — 60.001 against
    // 60.002 — is never announced as one.
    final moved = [
      if (old.name != ingredient.name) 'name',
      if (formatAmount(old.amount) != formatAmount(ingredient.amount)) 'amount',
      if (old.unit != ingredient.unit) 'unit',
      if (old.densityGPerMl != ingredient.densityGPerMl) 'density',
    ];
    if (moved.isEmpty) continue;
    yield (
      kind: ChangeKind.ingredient,
      label: 'Ingredient',
      detail: moved.join(', '),
      before: _ingredientLabel(old),
      after: _ingredientLabel(ingredient),
    );
  }
  for (final ingredient in from.ingredients) {
    if (!after.containsKey(ingredient.id)) {
      yield (
        kind: ChangeKind.ingredient,
        label: 'Ingredient',
        detail: null,
        before: _ingredientLabel(ingredient),
        after: null,
      );
    }
  }
}

/// Unscaled, so a diff always compares base amounts rather than whatever the
/// servings stepper happened to be showing.
String _ingredientLabel(Ingredient ingredient) =>
    '${amountLabel(ingredient, 1)} ${ingredient.name}';

Iterable<RecipeChange> _steps(Recipe from, Recipe to) sync* {
  final before = {for (final s in from.steps) s.id: s};
  final after = {for (final s in to.steps) s.id: s};

  for (final (index, step) in to.steps.indexed) {
    final label = 'Step ${index + 1}';
    final old = before[step.id];
    if (old == null) {
      yield (
        kind: ChangeKind.step,
        label: label,
        detail: null,
        before: null,
        after: step.title,
      );
      continue;
    }
    if (old.title != step.title) {
      yield (
        kind: ChangeKind.step,
        label: label,
        detail: 'title',
        before: old.title,
        after: step.title,
      );
    }
    if (old.content != step.content) {
      // Compared as stored but shown by name. Each side resolves against its
      // own version, so a renamed ingredient reads as the name that version
      // actually used.
      yield (
        kind: ChangeKind.step,
        label: label,
        detail: 'wording',
        before: toDisplayRefs(old.content, from.ingredients),
        after: toDisplayRefs(step.content, to.ingredients),
      );
    }
    if (old.timerSeconds != step.timerSeconds) {
      yield (
        kind: ChangeKind.step,
        label: label,
        detail: 'timer',
        before: _timerLabel(old.timerSeconds),
        after: _timerLabel(step.timerSeconds),
      );
    }
  }
  for (final step in from.steps) {
    if (!after.containsKey(step.id)) {
      yield (
        kind: ChangeKind.step,
        label: 'Step',
        detail: null,
        before: step.title,
        after: null,
      );
    }
  }

  // Reported once rather than per step: a single move renumbers everything
  // after it, which would otherwise read as a dozen unrelated changes. There
  // is no before or after to quote — the steps themselves did not change.
  final kept = to.steps.map((s) => s.id).where(before.containsKey);
  final was = from.steps.map((s) => s.id).where(after.containsKey);
  if (!_sameOrder(kept, was)) {
    yield (
      kind: ChangeKind.order,
      label: 'Step order',
      detail: null,
      before: null,
      after: null,
    );
  }
}

String? _timerLabel(int? seconds) =>
    seconds == null ? null : formatDuration(seconds);

bool _sameOrder(Iterable<String> a, Iterable<String> b) =>
    a.join(' ') == b.join(' ');

/// An emptied-out field reads as removed rather than as a change to "".
String? _blankToNull(String? value) =>
    value == null || value.isEmpty ? null : value;
