import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_sticker_packs_service.dart';
import 'package:mithka/chat/chat_sticker_packs_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

Map<String, dynamic> _sticker(int setId, {int date = 0}) => {
  '@type': 'message',
  'date': date,
  'content': {
    '@type': 'messageSticker',
    'sticker': {'@type': 'sticker', 'set_id': '$setId'},
  },
};

Map<String, dynamic> _text(
  List<int> emojiIds, {
  int? reactionEmojiId,
  int date = 0,
}) => {
  '@type': 'message',
  'date': date,
  'content': {
    '@type': 'messageText',
    'text': {
      '@type': 'formattedText',
      'text': 'x',
      'entities': [
        for (final id in emojiIds)
          {
            '@type': 'textEntity',
            'type': {
              '@type': 'textEntityTypeCustomEmoji',
              'custom_emoji_id': '$id',
            },
          },
      ],
    },
  },
  if (reactionEmojiId != null)
    'interaction_info': {
      'reactions': {
        'reactions': [
          {
            'type': {
              '@type': 'reactionTypeCustomEmoji',
              'custom_emoji_id': '$reactionEmojiId',
            },
          },
        ],
      },
    },
};

/// A fake TDLib. Chat 1 has two history pages; chat 2 one sticker message.
/// Custom emoji 501/502 belong to set 50, 601 to set 60. Set N has N % 17
/// items, so sizes differ between sets.
class _FakeTd {
  final requests = <Map<String, dynamic>>[];
  final installed = <int>{20};

  late final Map<int, List<List<Map<String, dynamic>>>> history = {
    1: [
      [
        _sticker(10, date: 400),
        _sticker(20, date: 900),
        _sticker(10, date: 300),
        _text([501, 502], date: 200),
      ],
      [
        _sticker(10, date: 100),
        _text([601], reactionEmojiId: 501, date: 950),
      ],
    ],
    2: [
      [_sticker(30, date: 1000)],
    ],
  };

  // Round-trip through JSON so nested maps are typed like real TDLib output.
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async =>
      jsonDecode(jsonEncode(_respond(request))) as Map<String, dynamic>;

  Map<String, dynamic> _respond(Map<String, dynamic> request) {
    requests.add(request);
    switch (request['@type']) {
      case 'getChats':
        return {'total_count': 2, 'chat_ids': history.keys.toList()};
      case 'getChatHistory':
        final pages = history[request['chat_id']]!;
        final from = request['from_message_id'] as int;
        final index = from == 0 ? 0 : from ~/ 1000 + 1;
        if (index >= pages.length) return {'messages': []};
        var id = index * 1000 + 999;
        return {
          'messages': [
            for (final m in pages[index].take(request['limit'] as int))
              {...m, 'id': id--},
          ],
        };
      case 'getCustomEmojiStickers':
        final ids = (request['custom_emoji_ids'] as List).cast<String>();
        return {
          'stickers': [
            for (final id in ids)
              {
                'set_id': id.startsWith('5') ? '50' : '60',
                'full_type': {
                  '@type': 'stickerFullTypeCustomEmoji',
                  'custom_emoji_id': id,
                },
              },
          ],
        };
      case 'getStickerSet':
        final id = request['set_id'] as int;
        return {
          'id': '$id',
          'title': 'Pack $id',
          'is_installed': installed.contains(id),
          'sticker_type': {
            '@type': id >= 50 ? 'stickerTypeCustomEmoji' : 'stickerTypeRegular',
          },
          // Animated with no thumbnail: previews fall back to the emoji glyph,
          // so widget tests never start file downloads.
          'stickers': [
            for (var i = 0; i < id % 17; i++)
              {
                'sticker': {'id': id * 100 + i},
                'format': {'@type': 'stickerFormatTgs'},
                'emoji': '😀',
              },
          ],
        };
      case 'changeStickerSet':
        installed.add(request['set_id'] as int);
        return {'@type': 'ok'};
    }
    throw StateError('unexpected ${request['@type']}');
  }
}

ChatUsedPack _pack(
  int id,
  String title, {
  int uses = 1,
  int lastUsed = 0,
  int items = 1,
  bool installed = false,
}) => ChatUsedPack(
  id: id,
  title: title,
  isCustomEmoji: false,
  itemCount: items,
  uses: uses,
  lastUsed: lastUsed,
  installed: installed,
);

void main() {
  final fixtures = L10nFixtures.load();

  setUp(() {
    fixtures.install();
    AppStrings.setLocale(const Locale('en'));
  });

  test('dedupes packs by set and ranks by use count', () async {
    final td = _FakeTd();
    final result = await ChatStickerPacksService(query: td.call).scan(1);

    expect(result.scannedMessages, 6);
    expect(result.stickers.map((p) => p.id), [10, 20]);
    expect(result.stickers.map((p) => p.uses), [3, 1]);
    expect(result.stickers.map((p) => p.lastUsed), [400, 900]);
    expect(result.stickers.first.itemCount, 10);
    expect(result.stickers.first.previews, hasLength(10));
    expect(result.emoji.map((p) => p.id), [50, 60]);
    // 501 twice (text + reaction) and 502 once all land on set 50.
    expect(result.emoji.first.uses, 3);
    expect(result.emoji.first.lastUsed, 950);
    expect(result.stickers[1].installed, isTrue);
    expect(
      td.requests.where((r) => r['@type'] == 'getStickerSet').length,
      4,
      reason: 'each set is looked up once',
    );
  });

  test('plain animated emoji do not surface the built-in emoji set', () {
    final refs = ChatPackReferences()
      ..addMessage({
        'content': {
          '@type': 'messageAnimatedEmoji',
          'animated_emoji': {
            'sticker': {
              'set_id': '99',
              'full_type': {'@type': 'stickerFullTypeRegular'},
            },
          },
        },
      })
      ..addMessage({
        'content': {
          '@type': 'messageAnimatedEmoji',
          'animated_emoji': {
            'sticker': {
              'set_id': '50',
              'full_type': {
                '@type': 'stickerFullTypeCustomEmoji',
                'custom_emoji_id': '501',
              },
            },
          },
        },
      });
    expect(refs.stickerSets, isEmpty);
    expect(refs.customEmoji, {501: 1});
  });

  test('stops paging at the message limit', () async {
    final td = _FakeTd();
    final result = await ChatStickerPacksService(
      query: td.call,
    ).scan(1, messageLimit: 3);
    expect(result.scannedMessages, 3);
    expect(td.requests.first['limit'], 3);
  });

  test('recent-chats scan merges packs across chats', () async {
    final td = _FakeTd();
    final progress = <(int, int)>[];
    final packProgress = <(int, int)>[];
    final result = await ChatStickerPacksService(query: td.call)
        .scanRecentChats(
          onProgress: (phase, done, total) =>
              (phase == ChatPackScanPhase.chats ? progress : packProgress).add((
                done,
                total,
              )),
        );
    expect(result.scannedChats, 2);
    expect(result.scannedMessages, 7);
    expect(result.stickers.map((p) => p.id), [10, 20, 30]);
    expect(progress.first, (0, 2));
    expect(progress.last, (2, 2));
    // Sets 10, 20, 30 plus emoji sets 50 and 60.
    expect(packProgress.first, (0, 5));
    expect(packProgress.last, (5, 5));
  });

  test('sorts by each key in both directions, stable on ties', () {
    final packs = [
      _pack(1, 'beta', uses: 2, lastUsed: 10, items: 5),
      _pack(2, 'Alpha', uses: 5, lastUsed: 30, items: 5),
      _pack(3, 'gamma', uses: 2, lastUsed: 20, items: 9),
    ];
    List<int> ids(ChatPackSort sort, bool descending) => sortPacks(
      packs,
      sort,
      descending: descending,
    ).map((p) => p.id).toList();

    expect(ids(ChatPackSort.usage, true), [2, 1, 3]);
    expect(ids(ChatPackSort.usage, false), [1, 3, 2]);
    expect(ids(ChatPackSort.recent, true), [2, 3, 1]);
    expect(ids(ChatPackSort.name, false), [2, 1, 3]);
    expect(ids(ChatPackSort.name, true), [3, 1, 2]);
    expect(ids(ChatPackSort.size, true), [3, 1, 2]);
  });

  test('filters by title and by not-added', () {
    final packs = [
      _pack(1, 'Duck Stickers'),
      _pack(2, 'Cats', installed: true),
      _pack(3, 'duckling'),
    ];
    expect(filterPacks(packs, query: ' DUCK ').map((p) => p.id), [1, 3]);
    expect(filterPacks(packs, onlyMissing: true).map((p) => p.id), [1, 3]);
    expect(
      filterPacks(packs, query: 'cat', onlyMissing: true).map((p) => p.id),
      isEmpty,
    );
  });

  testWidgets('phone layout: previews, Add (N), tabs, add all', (tester) async {
    final td = _FakeTd();
    await tester.pumpWidget(
      await _app(
        ChatStickerPacksView(
          chatId: 1,
          service: ChatStickerPacksService(query: td.call),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pack 10'), findsOneWidget);
    expect(find.text('Add (10)'), findsOneWidget);
    expect(find.textContaining(RegExp(r'used \d')), findsNothing);
    expect(find.text('😀'), findsWidgets, reason: 'preview strip renders');
    expect(find.text('Pack 50'), findsNothing);
    expect(find.byType(GridView), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-sticker-pack-add-10')));
    await tester.pumpAndSettle();
    expect(td.installed, contains(10));
    expect(
      find.byKey(const ValueKey('chat-sticker-packs-add-all')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('chat-sticker-packs-tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('Pack 50'), findsOneWidget);
    expect(find.text('Pack 60'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-sticker-packs-add-all')));
    await tester.pumpAndSettle();
    expect(td.installed, containsAll([50, 60]));
    expect(find.text('Added'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('filter, not-added and sort controls reshape the list', (
    tester,
  ) async {
    final td = _FakeTd();
    await tester.pumpWidget(
      await _app(
        ChatStickerPacksView(
          chatId: 1,
          service: ChatStickerPacksService(query: td.call),
        ),
      ),
    );
    await tester.pumpAndSettle();

    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(top('Pack 10'), lessThan(top('Pack 20')), reason: 'most used');

    await tester.tap(
      find.byKey(const ValueKey('chat-sticker-packs-sort-recent')),
    );
    await tester.pumpAndSettle();
    expect(top('Pack 20'), lessThan(top('Pack 10')));

    // Tapping the active sort flips its direction.
    await tester.tap(
      find.byKey(const ValueKey('chat-sticker-packs-sort-recent')),
    );
    await tester.pumpAndSettle();
    expect(top('Pack 10'), lessThan(top('Pack 20')));

    await tester.tap(
      find.byKey(const ValueKey('chat-sticker-packs-not-added')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pack 20'), findsNothing, reason: 'already installed');
    expect(find.text('Pack 10'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No packs match'), findsOneWidget);
  });

  testWidgets('global finder scans recent chats', (tester) async {
    final td = _FakeTd();
    await tester.pumpWidget(
      await _app(
        ChatStickerPacksView(service: ChatStickerPacksService(query: td.call)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sticker & Emoji Finder'), findsOneWidget);
    expect(find.text('From 2 recent chats'), findsOneWidget);
    expect(find.text('Pack 30'), findsOneWidget);
  });

  testWidgets('wide desktop layout uses two compact columns', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    try {
      final td = _FakeTd();
      await tester.pumpWidget(
        await _app(
          ChatStickerPacksView(
            chatId: 1,
            service: ChatStickerPacksService(query: td.call),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GridView), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('chat-sticker-pack-10')))
            .height,
        58,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<Widget> _app(Widget home) async {
  SharedPreferences.setMockInitialValues({});
  final theme = ThemeController(await SharedPreferences.getInstance());
  return ChangeNotifierProvider<ThemeController>.value(
    value: theme,
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
