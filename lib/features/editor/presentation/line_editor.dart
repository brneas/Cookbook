import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'linked_text_field.dart';

/// Explicit up/down actions provide a keyboard/TalkBack alternative to dragging.
class LineEditor extends StatefulWidget {
  const LineEditor({
    super.key,
    required this.label,
    required this.lines,
    required this.onEdit,
    required this.onAdd,
    required this.onRemove,
    required this.onMove,
    required this.revision,
    this.allowAddRemove = true,
  });
  final bool allowAddRemove;
  final String label;
  final List<String> lines;
  final void Function(int, String) onEdit;
  final VoidCallback onAdd;
  final void Function(int) onRemove;
  final void Function(int, int) onMove;
  final int revision;
  @override
  State<LineEditor> createState() => _LineEditorState();
}

class _LineEditorState extends State<LineEditor> {
  late List<Key> identities = List.generate(
    widget.lines.length,
    (_) => UniqueKey(),
  );
  String get label => widget.label;
  List<String> get lines => widget.lines;
  @override
  void didUpdateWidget(covariant LineEditor old) {
    super.didUpdateWidget(old);
    if (identities.length != lines.length) {
      identities = List.generate(lines.length, (_) => UniqueKey());
    }
  }

  void onMove(int from, int to) {
    if (from == to) return;
    setState(() => identities.insert(to, identities.removeAt(from)));
    widget.onMove(from, to);
  }

  void onRemove(int index) {
    setState(() => identities.removeAt(index));
    widget.onRemove(index);
  }

  void onAdd() {
    setState(() => identities.add(UniqueKey()));
    widget.onAdd();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (lines.isEmpty) Text('No ${label.toLowerCase()} yet.'),
      // No nested Scrollable: the native reorder sliver auto-scrolls the editor's
      // containing scroll view, even while dragging beyond this section.
      if (lines.isNotEmpty)
        Semantics(
          container: true,
          explicitChildNodes: true,
          child: ShrinkWrappingViewport(
            axisDirection: AxisDirection.down,
            offset: ViewportOffset.zero(),
            slivers: [
              SliverReorderableList(
                itemCount: lines.length,
                findChildIndexCallback: (key) {
                  final index = identities.indexOf(key);
                  return index < 0 ? null : index;
                },
                onReorderItem: onMove,
                proxyDecorator: (child, index, animation) =>
                    Material(elevation: 2, child: child),
                itemBuilder: (context, i) => Padding(
                  key: identities[i],
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ReorderableDragStartListener(
                        index: i,
                        child: Semantics(
                          label: 'Reorder $label ${i + 1}',
                          hint:
                              'Drag to move. The actions menu also offers Move up and Move down.',
                          child: Tooltip(
                            message: 'Drag $label ${i + 1}',
                            child: const SizedBox(
                              width: 48,
                              height: 48,
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: LinkedTextField(
                          value: lines[i],
                          maxLines: 5,
                          label: '$label ${i + 1}',
                          onChanged: (value) => widget.onEdit(i, value),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '$label ${i + 1} actions',
                        onSelected: (action) {
                          switch (action) {
                            case 'up':
                              onMove(i, i - 1);
                            case 'down':
                              onMove(i, i + 1);
                            case 'remove':
                              onRemove(i);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'up',
                            enabled: i > 0,
                            child: Text('Move $label ${i + 1} up'),
                          ),
                          PopupMenuItem(
                            value: 'down',
                            enabled: i < lines.length - 1,
                            child: Text('Move $label ${i + 1} down'),
                          ),
                          if (widget.allowAddRemove)
                            PopupMenuItem(
                              value: 'remove',
                              child: Text(
                                'Remove $label ${i + 1}',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      if (widget.allowAddRemove)
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: Text('Add ${label.toLowerCase()}'),
        ),
    ],
  );
}
