import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../app/providers.dart';

String? recipeReferenceId(String href) =>
    RegExp(r'^#r/([0-9]+)$').firstMatch(href)?.group(1);
String recipeReference(String id) {
  if (!RegExp(r'^[0-9]+$').hasMatch(id)) {
    throw const FormatException('Recipe needs a stable server ID');
  }
  return '#r/$id';
}

final recipeLinkNamesProvider = FutureProvider.autoDispose
    .family<Map<String, String>, String>((ref, ids) async {
      final account = await ref.watch(accountProvider.future);
      ref.watch(syncProvider.select((s) => s.revision));
      if (account == null || ids.isEmpty) return {};
      final values = ids.split(',').take(200).toList();
      final db = await ref.watch(databaseProvider.future);
      final rows = await db.db.query(
        'recipes',
        columns: ['id', 'name'],
        where:
            'account_id=? AND id IN (${List.filled(values.length, '?').join(',')})',
        whereArgs: [account.id, ...values],
      );
      return {
        for (final row in rows) row['id'] as String: row['name'] as String,
      };
    });

class RecipeReferenceSyntax extends md.InlineSyntax {
  RecipeReferenceSyntax(this.names) : super(r'#r/([0-9]+)(?=$|[\s,._+&?!-])');
  final Map<String, String> names;
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    if (match.start > 0 &&
        !RegExp(r'[\s,._+&?!-]').hasMatch(parser.source[match.start - 1])) {
      return false;
    }
    final id = match[1]!;
    parser.addNode(
      md.Element.text('a', names[id] ?? 'Recipe $id')
        ..attributes['href'] = recipeReference(id),
    );
    return true;
  }
}

class RecipeText extends ConsumerWidget {
  const RecipeText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = RegExp(
      r'#r/([0-9]+)',
    ).allMatches(text).map((m) => m[1]!).toSet().toList()..sort();
    final names = ids.isEmpty
        ? <String, String>{}
        : ref.watch(recipeLinkNamesProvider(ids.join(','))).asData?.value ?? {};
    return MarkdownBody(
      key: ValueKey(
        Object.hashAll(names.entries.map((e) => Object.hash(e.key, e.value))),
      ),
      data: text,
      selectable: true,
      inlineSyntaxes: [RecipeReferenceSyntax(names)],
      styleSheet: MarkdownStyleSheet.fromTheme(
        Theme.of(context),
      ).copyWith(p: style ?? Theme.of(context).textTheme.bodyLarge),
      // Never let arbitrary recipe markup load device files or tracking images.
      imageBuilder: (uri, title, alt) => Text(alt ?? 'Embedded image'),
      onTapLink: (label, href, title) async {
        if (href == null) return;
        final id = recipeReferenceId(href);
        if (id != null) {
          context.push('/recipe/$id');
          return;
        }
        final uri = Uri.tryParse(href);
        if (uri == null ||
            !['https', 'http'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          return;
        }
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('This link could not be opened.')),
            );
          }
        }
      },
    );
  }
}
