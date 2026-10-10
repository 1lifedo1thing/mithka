//
//  sticker_set_studio_interactions_test.dart
//
//  Widget tests for the redesigned sticker studio, against a fake TDLib
//  modeled on sticker_set_management_service_test.dart's query harness:
//
//  * long-press drag reorder persists through setStickerPositionInSet;
//  * the mask-position badge and the custom-emoji association show on cells;
//  * create flow validates title/stickers/short-name before publishing;
//  * delete set asks for confirmation before issuing deleteStickerSet;
//  * reorder while a move is in flight is ignored (the working guard).
//

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/sticker_preview.dart';
import 'package:mithka/chat/sticker_set_management_service.dart';
import 'package:mithka/chat/sticker_set_studio_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

/// A fake TDLib that owns one set. Every request is recorded (round-tripped
/// through JSON like real TDLib output, so nested maps are typed), and
/// setStickerPositionInSet actually mutates the set's order, so a reload
/// after a drag reflects the persisted server order.
class _FakeTd {
  _FakeTd({required Map<String, dynamic> set}) {
    _set = _decode(set);
  }

  Map<String, dynamic> _set = const {};
  final requests = <Map<String, dynamic>>[];
  var _nextUploadedId = 9000;
  Completer<void>? gate;

  Map<String, dynamic> get set => _set;

  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async {
    final object = _decode(request);
    requests.add(object);
    switch (object['@type']) {
      case 'getMe':
        return {'@type': 'user', 'id': 73};
      case 'getOwnedStickerSets':
        return {
          '@type': 'stickerSets',
          'sets': [_set],
        };
      case 'getStickerSet':
        return _set;
      case 'checkStickerSetName':
        return switch (object['name']) {
          'taken' => {'@type': 'checkStickerSetNameResultNameOccupied'},
          _ => {'@type': 'checkStickerSetNameResultOk'},
        };
      case 'getSuggestedStickerSetName':
        return {'@type': 'text', 'text': 'suggested_by_me'};
      case 'setStickerPositionInSet':
        if (gate != null) await gate!.future;
        _applyMove(object);
        return {'@type': 'ok'};
      case 'deleteStickerSet':
        return {'@type': 'ok'};
      case 'uploadStickerFile':
        return {'@type': 'file', 'id': _nextUploadedId++};
    }
    return {'@type': 'ok'};
  }

  void _applyMove(Map<String, dynamic> request) {
    final fileId = (request['sticker'] as Map)['id'] as int;
    final position = request['position'] as int;
    final stickers = (set['stickers'] as List).toList();
    final index = stickers.indexWhere(
      (sticker) => (sticker['sticker'] as Map)['id'] == fileId,
    );
    if (index < 0 || index == position) return;
    final moved = stickers.removeAt(index);
    stickers.insert(position.clamp(0, stickers.length), moved);
    set['stickers'] = stickers;
  }

  Map<String, dynamic> _decode(Map<String, dynamic> request) =>
      jsonDecode(jsonEncode(request)) as Map<String, dynamic>;
}

Map<String, dynamic> _sticker(
  int fileId,
  String emoji, {
  String format = 'stickerFormatWebm',
  Map<String, dynamic>? fullType,
}) => {
  'sticker': {
    '@type': 'file',
    'id': fileId,
    'local': {'@type': 'localFile', 'path': ''},
  },
  'format': {'@type': format},
  'emoji': emoji,
  'full_type': fullType ?? {'@type': 'stickerFullTypeRegular'},
};

Map<String, dynamic> _maskSet() => _set(
  'Masks',
  'stickerTypeMask',
  name: 'masks_by_me',
  stickers: [
    _sticker(11, '🎭', fullType: _mask(StickerMaskPoint.eyes)),
    _sticker(12, '😷', fullType: _mask(StickerMaskPoint.mouth, scale: 1.5)),
    _sticker(13, '👑', fullType: _mask(StickerMaskPoint.forehead)),
  ],
);

Map<String, dynamic> _mask(StickerMaskPoint point, {double scale = 1.0}) => {
  '@type': 'stickerFullTypeMask',
  'mask_position': {
    '@type': 'maskPosition',
    'point': {'@type': point.tdType},
    'x_shift': 0.0,
    'y_shift': 0.0,
    'scale': scale,
  },
};

Map<String, dynamic> _customEmojiSet() => _set(
  'My Emojis',
  'stickerTypeCustomEmoji',
  name: 'emojis_by_me',
  stickers: [
    _sticker(21, '😀', fullType: _customEmoji('2101')),
    _sticker(22, '🔥', fullType: _customEmoji('2102')),
  ],
);

Map<String, dynamic> _customEmoji(String id) => {
  '@type': 'stickerFullTypeCustomEmoji',
  'custom_emoji_id': id,
  'needs_repainting': false,
};

Map<String, dynamic> _set(
  String title,
  String type, {
  required String name,
  List<Map<String, dynamic>> stickers = const [],
}) => {
  '@type': 'stickerSet',
  'id': 10,
  'title': title,
  'name': name,
  'sticker_type': {'@type': type},
  'stickers': stickers,
};

Future<Widget> _app(Widget home) async {
  SharedPreferences.setMockInitialValues({});
  final controller = ThemeController(await SharedPreferences.getInstance());
  return ChangeNotifierProvider<ThemeController>.value(
    value: controller,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
}

/// Pumps the manage screen for a fake set.
Future<void> _pumpManage(
  WidgetTester tester,
  _FakeTd td, {
  int setId = 10,
}) async {
  await tester.pumpWidget(
    await _app(StickerSetManageView(setId: setId, service: _service(td))),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 1600));
}

StickerSetManagementService _service(_FakeTd td) =>
    StickerSetManagementService(query: td.call);

/// Long-press drags [from] onto [to] the way a user does on a phone.
Future<void> _dragCell(WidgetTester tester, Finder from, Finder to) async {
  final fromCenter = tester.getCenter(from);
  final toCenter = tester.getCenter(to);
  final gesture = await tester.startGesture(fromCenter);
  await tester.pump(kLongPressTimeout * 2);
  await gesture.moveBy(const Offset(4, 0));
  await tester.pump();
  await gesture.moveBy(toCenter - fromCenter - const Offset(4, 0));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  final fixtures = L10nFixtures.load();

  setUp(() {
    fixtures.install();
    AppStrings.setLocale(const Locale('en'));
  });

  testWidgets('drag reorder persists via setStickerPositionInSet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    final cells = find.byType(StickerPreview);
    expect(cells, findsNWidgets(3));
    await _dragCell(tester, cells.first, cells.last);
    await tester.pumpAndSettle();

    final moves = td.requests
        .where((request) => request['@type'] == 'setStickerPositionInSet')
        .toList();
    expect(moves, hasLength(1));
    expect(moves.single['sticker'], {'@type': 'inputFileId', 'id': 11});
    expect(moves.single['position'], 2);
  });

  testWidgets('mask position badge shows on each mask cell', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    expect(find.textContaining('Mask · mouth'), findsOneWidget);
    expect(find.textContaining('Mask · eyes'), findsOneWidget);
    expect(find.textContaining('Mask · forehead'), findsOneWidget);
  });

  testWidgets('custom emoji association shows on each cell', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _customEmojiSet());
    await _pumpManage(tester, td);

    // The webm preview fallback also renders the emoji, so each association
    // appears twice: once in the preview glyph and once in the badge.
    expect(find.text('😀'), findsNWidgets(2));
    expect(find.text('🔥'), findsNWidgets(2));
  });

  testWidgets('a drag while a move is in flight is ignored', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    final cells = find.byType(StickerPreview);
    // Hold the first move's response until the second drop has been made.
    td.gate = Completer<void>();
    await _dragCell(tester, cells.first, cells.last);
    await tester.pump();
    expect(
      td.requests.where(
        (request) => request['@type'] == 'setStickerPositionInSet',
      ),
      isNotEmpty,
      reason: 'the first drop issued its move',
    );

    // The move is in flight (_working), so this drop must be ignored.
    await _dragCell(tester, cells.at(1), cells.last);
    await tester.pump();
    final moves = td.requests
        .where((request) => request['@type'] == 'setStickerPositionInSet')
        .length;
    expect(moves, 1, reason: 'the in-flight guard dropped the second drop');

    td.gate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('delete set asks for confirmation before the request', (
    tester,
  ) async {
    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    await tester.tap(find.text('Delete set'));
    await tester.pumpAndSettle();

    expect(find.text('Delete sticker set?'), findsOneWidget);
    expect(
      td.requests.where((request) => request['@type'] == 'deleteStickerSet'),
      isEmpty,
    );

    await tester.tap(find.text('Delete set').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1600));
    expect(
      td.requests.where((request) => request['@type'] == 'deleteStickerSet'),
      isNotEmpty,
    );
  });

  testWidgets('create flow surfaces validation before publishing', (
    tester,
  ) async {
    final td = _FakeTd(set: _maskSet());
    await tester.pumpWidget(
      await _app(StickerSetCreateView(service: _service(td))),
    );
    await tester.pumpAndSettle();

    // Publish with nothing filled in: the title error comes first.
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(
      find.text('Enter a title between 1 and 64 characters.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 1600));
    expect(
      td.requests.where((request) => request['@type'] == 'createNewStickerSet'),
      isEmpty,
    );

    // With a title but no stickers, the sticker error is shown.
    await tester.enterText(find.byType(TextField).first, 'Masks');
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(find.text('Add at least one sticker.'), findsOneWidget);
    expect(
      td.requests.where((request) => request['@type'] == 'createNewStickerSet'),
      isEmpty,
    );
    // Let the toast fully retire so no timer is pending at teardown.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  });
}
