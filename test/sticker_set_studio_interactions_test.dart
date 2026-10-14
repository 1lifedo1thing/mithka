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
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/sticker_preview.dart';
import 'package:mithka/chat/sticker_set_management_service.dart';
import 'package:mithka/chat/sticker_set_studio_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
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

  /// Sticker file ids whose removeStickerFromSet throws, to exercise the
  /// continue-and-report path of the batch delete.
  final failRemoveIds = <int>{};

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
      case 'removeStickerFromSet':
        if (gate != null) await gate!.future;
        final fileId = (object['sticker'] as Map)['id'] as int;
        if (failRemoveIds.contains(fileId)) {
          throw StateError('TDLib error 400: STICKER_INVALID');
        }
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

/// A fake TdClient that fronts one [_FakeTd] per account slot, so a test can
/// flip the foreground account mid-session and see exactly which backend
/// received each request. The pinned query (`stickerSetQueryForOwner`) uses
/// [clientId] to route and fails closed if a slot's client is replaced.
class _FakeClient implements TdClient {
  _FakeClient({required this.backends});

  final Map<int, _FakeTd> backends;

  /// The foreground account slot; flipping it is the "account switch".
  @override
  int activeSlot = 0;

  /// Maps each slot to a distinct client id.
  final Map<int, int> _clientIdForSlot = {0: 9, 1: 10};

  _FakeTd _backendFor(int clientId) {
    for (final entry in _clientIdForSlot.entries) {
      if (entry.value == clientId && backends.containsKey(entry.key)) {
        return backends[entry.key]!;
      }
    }
    throw StateError('No backend for client $clientId');
  }

  @override
  int get activeClientId => _clientIdForSlot[activeSlot] ?? 0;

  @override
  int? clientId(int slot) => _clientIdForSlot[slot];

  @override
  Future<Map<String, dynamic>> query(
    Map<String, dynamic> request, {
    Duration timeout = const Duration(seconds: 30),
  }) => queryTo(request, activeClientId, timeout: timeout);

  @override
  Future<Map<String, dynamic>> queryTo(
    Map<String, dynamic> request,
    int clientId, {
    Duration timeout = const Duration(seconds: 30),
  }) => _backendFor(clientId).call(request);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

/// Starts the long-press drag of [from] but leaves the pointer down, so a
/// test can end it however it wants (up, cancel, …).
Future<TestGesture> _beginCellDrag(
  WidgetTester tester,
  Finder from,
  Finder to,
) async {
  final fromCenter = tester.getCenter(from);
  final toCenter = tester.getCenter(to);
  final gesture = await tester.startGesture(fromCenter);
  await tester.pump(kLongPressTimeout * 2);
  await gesture.moveBy(const Offset(4, 0));
  await tester.pump();
  await gesture.moveBy(toCenter - fromCenter - const Offset(4, 0));
  await tester.pump();
  return gesture;
}

/// Long-press drags [from] onto [to] the way a user does on a phone.
Future<void> _dragCell(WidgetTester tester, Finder from, Finder to) async {
  final gesture = await _beginCellDrag(tester, from, to);
  await gesture.up();
  await tester.pump();
}

bool _hasMove(_FakeTd td) =>
    td.requests.any((request) => request['@type'] == 'setStickerPositionInSet');

void main() {
  final fixtures = L10nFixtures.load();

  // The mock clipboard answers Clipboard.setData/Clipboard.getData, which
  // otherwise hang in a plain widget test (no platform plugin).
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboardWrites = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardWrites.add(call.arguments['text'] as String);
        }
        return null;
      });

  setUp(() {
    clipboardWrites.clear();
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

  testWidgets('manage card shows the set link and copies it on tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    expect(find.text('t.me/addstickers/masks_by_me'), findsOneWidget);

    await tester.tap(find.text('t.me/addstickers/masks_by_me'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Link copied'), findsOneWidget);
    expect(clipboardWrites, ['https://t.me/addstickers/masks_by_me']);
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('custom emoji sets use the addemoji link prefix', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _customEmojiSet());
    await _pumpManage(tester, td);

    expect(find.text('t.me/addemoji/emojis_by_me'), findsOneWidget);
  });

  testWidgets('use-as-thumbnail from a cell sends inputFileId, no upload', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    await tester.tap(find.byType(StickerPreview).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use as set thumbnail'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1600));

    final thumbnails = td.requests
        .where((request) => request['@type'] == 'setStickerSetThumbnail')
        .toList();
    expect(thumbnails, hasLength(1));
    expect(thumbnails.single['thumbnail'], {'@type': 'inputFileId', 'id': 11});
    expect(thumbnails.single['name'], 'masks_by_me');
    expect(thumbnails.single['format'], {'@type': 'stickerFormatWebm'});
    expect(
      td.requests.where((request) => request['@type'] == 'uploadStickerFile'),
      isEmpty,
    );
  });

  testWidgets('edit mode picks cells and batch-removes after one confirm', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('studio-selection-toolbar')),
      findsOneWidget,
    );
    expect(find.text('Tap stickers to select them'), findsOneWidget);

    await tester.tap(find.byType(StickerPreview).at(1));
    await tester.pump();
    await tester.tap(find.byType(StickerPreview).at(2));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('studio-selection-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Remove 2 stickers?'), findsOneWidget);
    expect(
      td.requests.where(
        (request) => request['@type'] == 'removeStickerFromSet',
      ),
      isEmpty,
    );

    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1600));
    final removed = td.requests
        .where((request) => request['@type'] == 'removeStickerFromSet')
        .toList();
    expect(removed, hasLength(2));
    expect(
      removed.map((request) => (request['sticker'] as Map)['id']).toSet(),
      {12, 13},
    );
    // The toolbar collapses back to the hint once the batch is gone.
    expect(find.text('Tap stickers to select them'), findsOneWidget);
  });

  testWidgets('a pointer-cancelled drag writes nothing', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    final cells = find.byType(StickerPreview);
    final gesture = await _beginCellDrag(tester, cells.first, cells.last);
    await gesture.cancel();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(_hasMove(td), isFalse, reason: 'cancellation must not commit');
  });

  testWidgets('disabling the drag mid-flight writes nothing', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    // A live drag, then the affordance disappears underneath it (edit mode
    // opens while the pointer is still down).
    final cells = find.byType(StickerPreview);
    final gesture = await _beginCellDrag(tester, cells.first, cells.last);
    await tester.tap(find.text('Edit'));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      _hasMove(td),
      isFalse,
      reason: 'a drag disabled mid-flight must abort, not drop',
    );
    // Rebinding the affordance must not resurrect the stale drag either.
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(_hasMove(td), isFalse);
  });

  testWidgets('an overlapping second pointer cancels the drag, writes nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    // Snapshot the cell geometry BEFORE the drag: once a drag is live the
    // feedback overlay mounts a second StickerPreview, which would make the
    // finder resolve the second finger's target to the floating copy.
    final cells = find.byType(StickerPreview);
    final from = tester.getCenter(cells.first);
    final middle = tester.getCenter(cells.at(1));
    final to = tester.getCenter(cells.last);

    final first = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout * 2);
    await first.moveBy(const Offset(4, 0));
    await tester.pump();
    await first.moveBy(to - from - const Offset(4, 0));
    await tester.pump();
    // A second finger lands on another cell mid-drag. Flutter's gesture arena
    // cancels the first pointer when the second touches down, so the live drag
    // is aborted: the safe outcome is that NEITHER finger commits a reorder —
    // the overlapping pointer must not produce an unsolicited write, and the
    // cancelled first drag must not either.
    final second = await tester.startGesture(middle, pointer: 7);
    await tester.pump();
    await second.up();
    await tester.pump();
    await first.up();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      td.requests.where(
        (request) => request['@type'] == 'setStickerPositionInSet',
      ),
      isEmpty,
      reason: 'an overlapping pointer cancels the drag; no write is issued',
    );
  });

  testWidgets('a dispose during a drag writes nothing', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    await _pumpManage(tester, td);

    final cells = find.byType(StickerPreview);
    final gesture = await _beginCellDrag(tester, cells.first, cells.last);
    await gesture.cancel();
    // Navigating away disposes the grid with the drag state still live.
    await tester.pumpWidget(await _app(const SizedBox()));
    await tester.pumpAndSettle();

    expect(_hasMove(td), isFalse);
  });

  testWidgets('a drag after a jump to the bottom commits exactly one move', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 120 stickers: the grid is lazy, so a jump leaves sparse mounted keys.
    final set = _set(
      'Masks',
      'stickerTypeMask',
      name: 'masks_by_me',
      stickers: [
        for (var i = 0; i < 120; i++)
          _sticker(11 + i, '🎭', fullType: _mask(StickerMaskPoint.eyes)),
      ],
    );
    final td = _FakeTd(set: set);
    await _pumpManage(tester, td);

    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    // Two cells visible at the bottom; dragging one onto the other must
    // resolve through the sparse mounted keys, not dense index math.
    final cells = find.byType(StickerPreview);
    expect(cells, findsWidgets);
    final visible = tester.widgetList<StickerPreview>(cells).toList();
    expect(visible.length, greaterThan(1));
    await _dragCell(tester, cells.first, cells.at(1));
    await tester.pumpAndSettle();

    final moves = td.requests
        .where((request) => request['@type'] == 'setStickerPositionInSet')
        .toList();
    expect(moves, hasLength(1));
    // Dragging the first mounted bottom cell onto the second one moves it
    // one slot forward.
    final movedId = (moves.single['sticker'] as Map)['id'];
    expect(movedId, isNot(11), reason: 'bottom cells, not the head of the set');
  });

  testWidgets('autoscroll during a drag reaches off-screen rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final set = _set(
      'Masks',
      'stickerTypeMask',
      name: 'masks_by_me',
      stickers: [
        for (var i = 0; i < 120; i++)
          _sticker(11 + i, '🎭', fullType: _mask(StickerMaskPoint.eyes)),
      ],
    );
    final td = _FakeTd(set: set);
    await _pumpManage(tester, td);

    final cells = find.byType(StickerPreview);
    // Drag the first cell to the bottom edge and hold: the autoscroll timer
    // fires every 110ms and scrolls the viewport down.
    final fromCenter = tester.getCenter(cells.first);
    final bottomY = tester.view.physicalSize.height - 20;
    final gesture = await tester.startGesture(fromCenter);
    await tester.pump(kLongPressTimeout * 2);
    await gesture.moveBy(const Offset(4, 0));
    await tester.pump();
    await gesture.moveBy(Offset(0, bottomY - fromCenter.dy));
    await tester.pump();
    final before = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;
    await tester.pump(const Duration(milliseconds: 500));
    final after = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(after, greaterThan(before), reason: 'edge drag autoscrolls');
    expect(_hasMove(td), isFalse, reason: 'the cancelled drag wrote nothing');
  });

  testWidgets('an off-screen drag source still completes its drop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final td = _FakeTd(
      set: _set(
        'Masks',
        'stickerTypeMask',
        name: 'masks_by_me',
        stickers: [
          for (var i = 0; i < 120; i++)
            _sticker(11 + i, '🎭', fullType: _mask(StickerMaskPoint.eyes)),
        ],
      ),
    );
    await _pumpManage(tester, td);
    final cells = find.byType(StickerPreview);
    final source = tester.element(
      find
          .ancestor(
            of: cells.first,
            matching: find.byType(LongPressDraggable<int>),
          )
          .first,
    );
    final start = tester.getCenter(cells.first);
    final gesture = await tester.startGesture(start);
    await tester.pump(kLongPressTimeout * 2);
    await gesture.moveBy(const Offset(4, 0));
    await tester.pump();
    await gesture.moveBy(
      Offset(0, tester.view.physicalSize.height - 20 - start.dy),
    );
    await tester.pump();
    for (var step = 0; step < 60; step++) {
      await tester.pump(const Duration(milliseconds: 110));
    }
    expect(source.mounted, isTrue, reason: 'the active source is kept alive');
    await gesture.moveTo(tester.getCenter(cells.hitTestable().last));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      td.requests.where((r) => r['@type'] == 'setStickerPositionInSet'),
      hasLength(1),
    );
  });

  testWidgets('batch delete keeps writing to the source account', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Two fake accounts behind one _FakeClient (slot 0 → client 9, slot 1 →
    // client 10). The service is pinned with the REAL stickerSetQueryForOwner
    // to the slot-0 client captured at open time; flipping the foreground
    // slot mid-batch must not retarget the pending removals to the other
    // account — the pin routes by the captured client id, not the active slot.
    final source = _FakeTd(set: _maskSet());
    final other = _FakeTd(set: _maskSet());
    final client = _FakeClient(backends: {0: source, 1: other});
    final service = StickerSetManagementService(
      query: client.query,
      pinnedQuery: stickerSetQueryForOwner(client, accountSlot: 0, clientId: 9),
    );
    await tester.pumpWidget(
      await _app(StickerSetManageView(setId: 10, service: service)),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1600));

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(StickerPreview).at(1));
    await tester.pump();
    await tester.tap(find.byType(StickerPreview).at(2));
    await tester.pump();

    // The foreground account flips while the confirmation sheet is open.
    client.activeSlot = 1;
    await tester.tap(find.byKey(const ValueKey('studio-selection-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1600));

    expect(
      other.requests.where(
        (request) => request['@type'] == 'removeStickerFromSet',
      ),
      isEmpty,
      reason: 'a foreground switch must not receive the pending ids',
    );
    // The pin keeps both removals on the account that loaded the set.
    expect(
      source.requests.where(
        (request) => request['@type'] == 'removeStickerFromSet',
      ),
      hasLength(2),
    );
  });

  testWidgets('partial batch failure reports and keeps deleting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    td.failRemoveIds.add(12);
    await _pumpManage(tester, td);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(StickerPreview).at(1));
    await tester.pump();
    await tester.tap(find.byType(StickerPreview).at(2));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('studio-selection-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();

    final removed = td.requests
        .where((request) => request['@type'] == 'removeStickerFromSet')
        .toList();
    // The failing sticker did not forfeit the rest: both were attempted.
    expect(removed, hasLength(2));
    expect(
      removed.map((request) => (request['sticker'] as Map)['id']).toSet(),
      {12, 13},
    );
    // The partial-failure toast names both counts (asserted while the toast
    // is still holding, before the drain retires it).
    expect(find.textContaining('Removed 1 of 2 stickers'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('an account that vanishes mid-batch stops cleanly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final td = _FakeTd(set: _maskSet());
    // The first removal reaches the source account; right after it the owning
    // account vanishes, so the pinned query fails closed for the rest. No
    // gate/timing race: the counter makes the switch deterministic.
    var removals = 0;
    final service = StickerSetManagementService(
      query: td.call,
      pinnedQuery: (request) {
        if (request['@type'] == 'removeStickerFromSet') {
          if (removals++ > 0) {
            throw const StickerSetAccountUnavailable(
              'The sticker set account is unavailable',
            );
          }
        }
        return td.call(request);
      },
    );
    await tester.pumpWidget(
      await _app(StickerSetManageView(setId: 10, service: service)),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 1600));

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(StickerPreview).at(1));
    await tester.pump();
    await tester.tap(find.byType(StickerPreview).at(2));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('studio-selection-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove').last);
    // The failure toast is raised synchronously in the catch; assert it while
    // it is still up (before its fade-out), not after a drain that hides it.
    await tester.pumpAndSettle();

    final removed = td.requests
        .where((request) => request['@type'] == 'removeStickerFromSet')
        .toList();
    // The batch stopped with the account after the first removal landed,
    // instead of half-deleting the rest on a client that is gone.
    expect(removed, hasLength(1), reason: 'stops at the vanished account');
    expect(find.textContaining('Sticker set update failed'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });
}
