import 'package:flutter/material.dart';
import 'dart:ui' show CheckedState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:cookbook/app/providers.dart';
import 'package:cookbook/core/database/app_database.dart';
import 'package:cookbook/core/theme/app_theme.dart';
import 'package:cookbook/features/editor/presentation/line_editor.dart';
import 'package:cookbook/features/recipes/domain/recipe.dart';
import 'package:cookbook/features/recipes/presentation/detail_ingredients.dart';
import 'package:cookbook/features/recipes/presentation/recipe_actions.dart';
import 'package:cookbook/features/recipes/presentation/recipe_screen.dart';
import 'package:cookbook/features/sync/presentation/sync_providers.dart';
import 'widget_test.dart' show SavedAccount;

void main() {
  for (final config in [('Ingredient', 3), ('Ingredient', 30), ('Step', 50)]) {
    testWidgets(
      '${config.$1} ${config.$2} handle drag retains text and auto scrolls long lists',
      (tester) async {
        tester.view.physicalSize = const Size(390, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final values = List.generate(config.$2, (i) => 'Line $i');
        var revision = 0;
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: cookbookTheme(Brightness.light),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) => SingleChildScrollView(
                    controller: scroll,
                    child: LineEditor(
                      label: config.$1,
                      lines: values,
                      revision: revision,
                      onEdit: (i, text) => setState(() => values[i] = text),
                      onAdd: () => setState(() => values.add('')),
                      onRemove: (i) => setState(() => values.removeAt(i)),
                      onMove: (from, to) => setState(() {
                        values.insert(to, values.removeAt(from));
                        revision++;
                      }),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextFormField).first,
          'Edited before drag',
        );
        final handle = find.byTooltip('Drag ${config.$1} 1');
        expect(
          tester
              .getSemantics(
                find.bySemanticsLabel(RegExp('Reorder ${config.$1} 1')).first,
              )
              .label,
          contains('Reorder'),
        );
        final gesture = await tester.startGesture(tester.getCenter(handle));
        await gesture.moveBy(const Offset(0, 25));
        await tester.pump(const Duration(milliseconds: 100));
        if (config.$2 == 3) {
          await gesture.moveTo(
            tester.getCenter(find.byTooltip('Drag ${config.$1} 3')) +
                const Offset(0, 25),
          );
          await tester.pump(const Duration(milliseconds: 400));
        } else {
          await gesture.moveTo(const Offset(24, 592));
          for (var i = 0; i < 35; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(scroll.offset, greaterThan(150));
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(values.indexOf('Edited before drag'), greaterThan(0));
        expect(values.toSet().length, config.$2);
        expect(revision, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  sqfliteFfiInit();
  testWidgets(
    'detail check semantics strike-through persist after remount and clear menu',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await AppDatabase.open(
        factory: databaseFactoryFfiNoIsolate,
        path: inMemoryDatabasePath,
      );
      await db.db.insert('accounts', {
        'id': 'test',
        'server': 'https://cloud.test',
        'login_name': 'cook',
        'capabilities': '{}',
      });
      final recipe = Recipe.fromJson({
        'id': '42',
        'name': 'Soup',
        'recipeIngredient': ['## Sauce', '2 tablespoons butter', '1 cup flour'],
      });
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith((_) async => db),
          accountProvider.overrideWith(SavedAccount.new),
          recipeDetailProvider.overrideWith((_, _) async => recipe),
          recipeRecordProvider.overrideWith(
            (_, _) async => {'sync_state': 'clean', 'local_deleted': 0},
          ),
        ],
      );
      await tester.runAsync(
        () => container.read(detailChecksProvider('42').future),
      );
      Future<void> pump() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: cookbookTheme(Brightness.light),
              home: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: Scaffold(
                  appBar: AppBar(
                    actions: [RecipeActions(recipe, menuOnly: true)],
                  ),
                  body: SingleChildScrollView(child: DetailIngredients(recipe)),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump();
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      final semantics = tester.ensureSemantics();
      expect(
        tester
            .getSemantics(
              find.widgetWithText(CheckboxListTile, '2 tablespoons butter'),
            )
            .getSemanticsData()
            .flagsCollection
            .isChecked,
        CheckedState.isFalse,
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('2 tablespoons butter'));
        await container.read(detailChecksProvider('42').notifier).settled;
      });
      await tester.pumpAndSettle();
      final text = tester.widget<Text>(find.text('2 tablespoons butter'));
      expect(text.style!.decoration, TextDecoration.lineThrough);
      expect(
        tester
            .getSemantics(
              find.widgetWithText(CheckboxListTile, '2 tablespoons butter'),
            )
            .getSemanticsData()
            .flagsCollection
            .isChecked,
        CheckedState.isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      container.invalidate(detailChecksProvider('42'));
      await tester.runAsync(
        () => container.read(detailChecksProvider('42').future),
      );
      await pump();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '2 tablespoons butter'),
            )
            .value,
        true,
      );
      await tester.tap(find.byTooltip('Recipe actions'));
      await tester.pumpAndSettle();
      final action = tester
          .widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>))
          .onSelected!;
      await tester.runAsync(() async {
        action('clear');
        await container.read(detailChecksProvider('42').notifier).settled;
      });
      await tester.tapAt(const Offset(1, 500));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '2 tablespoons butter'),
            )
            .value,
        false,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.runAsync(db.close);
    },
  );
}
