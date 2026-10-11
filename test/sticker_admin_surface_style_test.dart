import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sticker studio and administration use project-owned controls', () {
    const paths = [
      'lib/chat/sticker_set_studio_view.dart',
      'lib/chat/sticker_reorder_grid.dart',
      'lib/chat/sticker_studio_controls.dart',
      'lib/chat/group_administration_view.dart',
    ];
    final forbiddenControls = RegExp(
      r'\b(AlertDialog|SimpleDialog|TextButton|DropdownButton|DropdownMenuItem|ListTile|SwitchListTile|Switch|FilledButton|ElevatedButton|OutlinedButton|IconButton|FloatingActionButton|ActionChip|ChoiceChip|FilterChip|InputChip|Chip|Checkbox|Radio|CircularProgressIndicator|LinearProgressIndicator|RefreshIndicator|PopupMenuButton|MenuAnchor|SegmentedButton|Slider|RangeSlider|InkWell|RawMaterialButton)\\b',
    );

    for (final path in paths) {
      final source = File(path).readAsStringSync();
      expect(
        forbiddenControls.hasMatch(source),
        isFalse,
        reason: '$path must use project-owned controls',
      );
      expect(
        source.replaceAll('HeroAppIcons.', '').contains('Icons.'),
        isFalse,
        reason: '$path must use AppIcon data',
      );
      expect(source.contains('CupertinoIcons'), isFalse, reason: path);
      expect(source.contains(' child: Icon('), isFalse, reason: path);
    }
  });

  test(
    'drag proxies and reorder machinery stay owned, not Material chrome',
    () {
      const paths = [
        'lib/chat/sticker_set_studio_view.dart',
        'lib/chat/sticker_reorder_grid.dart',
      ];
      for (final path in paths) {
        final source = File(path).readAsStringSync();
        // Material( is allowed in the file for MaterialApp/Scaffold plumbing
        // only; the drag feedback/proxy surfaces must paint with owned
        // primitives (DecoratedBox/ClipRRect/ColoredBox + AppColors tokens).
        expect(source.contains('MaterialType'), isFalse, reason: path);
        expect(source.contains('Material('), isFalse, reason: path);
        expect(source.contains('Theme.of('), isFalse, reason: path);
        expect(source.contains('colorScheme'), isFalse, reason: path);
        // Reorder machinery comes from the widgets layer; the Material
        // ReorderableListView (its default proxy decorates with Material
        // elevation and inserts drag handles) must not appear. The create
        // flow uses the builder API; the grid file has no list machinery of
        // its own (its LongPressDraggable drag is owned), so the checks are
        // split per surface.
        expect(source.contains('ReorderableListView'), isFalse, reason: path);
        if (path == 'lib/chat/sticker_set_studio_view.dart') {
          expect(source.contains('ReorderableList('), isTrue, reason: path);
          expect(
            source.contains('ReorderableDelayedDragStartListener'),
            isTrue,
            reason: path,
          );
        } else {
          expect(source.contains('LongPressDraggable'), isTrue, reason: path);
        }
      }
    },
  );
}
