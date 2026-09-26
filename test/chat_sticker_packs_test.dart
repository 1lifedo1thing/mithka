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

Map<String, dynamic> _from(int userId) => {
  '@type': 'messageSenderUser',
  'user_id': userId,
};

Map<String, dynamic> _sticker(int id, int date, int setId, {int from = 1}) => {
  '@type': 'message',
  'id': id,
  'date': date,
  'sender_id': _from(from),
  'content': {
    '@type': 'messageSticker',
    'sticker': {'@type': 'sticker', 'set_id': '$setId'},
  },
};

Map<String, dynamic> _text(
  int id,
  int date,
  List<int> emojiIds, {
  int? reactionEmojiId,
  int from = 1,
}) => {
  '@type': 'message',
  'id': id,
  'date': date,
  'sender_id': _from(from),
  'content': {
    '@type': 'messageText',
    'text': {
      '@type': 'formattedText',
      'text': 'x',
      'entities': [
        for (final emojiId in emojiIds)
          {
            '@type': 'textEntity',
            'type': {
              '@type': 'textEntityTypeCustomEmoji',
              'custom_emoji_id': '$emojiId',
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
            // Three reactors, of whom TDLib names the two most recent.
            'total_count': 3,
            'recent_sender_ids': [_from(5), _from(6)],
          },
        ],
      },
    },
};

/// A fake TDLib. Chats 1 and 2 are in the main list, chat 3 in the archive;
/// histories are newest first, sent by users 1–4. Custom emoji 501/502 belong to set 50, 601 to
/// set 60. Set N has N % 17 items, so sizes differ between sets.
class _FakeTd {
  _FakeTd({Map<int, List<Map<String, dynamic>>>? history})
    : history =
          history ??
          {
            1: [
              _sticker(30, 900, 10),
              _sticker(20, 500, 10, from: 2),
              _text(10, 100, [501, 502]),
            ],
            2: [
              _sticker(31, 800, 20, from: 3),
              _text(21, 600, [601], reactionEmojiId: 501, from: 3),
            ],
            3: [_sticker(5, 700, 30, from: 4)],
          },
      archive = history == null ? {3} : const {};

  final Map<int, List<Map<String, dynamic>>> history;
  final Set<int> archive;
  final requests = <Map<String, dynamic>>[];
  final installed = <int>{20};

  // Round-trip through JSON so nested maps are typed like real TDLib output.
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async =>
      jsonDecode(jsonEncode(_respond(request))) as Map<String, dynamic>;

  Map<String, dynamic> _respond(Map<String, dynamic> request) {
    requests.add(request);
    switch (request['@type']) {
      case 'getChats':
        final archived = request['chat_list']['@type'] == 'chatListArchive';
        final ids = [
          for (final id in history.keys)
            if (archive.contains(id) == archived) id,
        ];
        return {'chat_ids': ids.take(request['limit'] as int).toList()};
      case 'getChat':
        final messages = history[request['chat_id']]!;
        return {
          'id': request['chat_id'],
          if (messages.isNotEmpty) 'last_message': messages.first,
        };
      case 'getChatHistory':
        final from = request['from_message_id'] as int;
        final older = history[request['chat_id']]!.where(
          (m) => from == 0 || (m['id'] as int) < from,
        );
        // Like TDLib, an uncached first read returns only the newest message.
        final limit = from == 0 ? 1 : request['limit'] as int;
        return {'messages': older.take(limit).toList()};
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
            '@type': id >= 50 && id < 100
                ? 'stickerTypeCustomEmoji'
                : 'stickerTypeRegular',
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

/// One chat of [count] messages; message i uses set 1000 + i ~/ 4, or none
/// when [withPacks] is false.
_FakeTd _longChat(int count, {bool withPacks = true}) => _FakeTd(
  history: {
    9: [
      for (var i = 0; i < count; i++)
        withPacks
            ? _sticker(count - i, 100000 - i, 1000 + i ~/ 4)
            : _text(count - i, 100000 - i, const []),
    ],
  },
);

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

Map<int, int> _uses(List<ChatUsedPack> packs) => {
  for (final p in packs) p.id: p.uses,
};

Map<int, int> _users(List<ChatUsedPack> packs) => {
  for (final p in packs) p.id: p.users,
};

int _historyReads(_FakeTd td) =>
    td.requests.where((r) => r['@type'] == 'getChatHistory').length;

void main() {
  final fixtures = L10nFixtures.load();

  setUp(() {
    fixtures.install();
    AppStrings.setLocale(const Locale('en'));
  });

  test('one chat: dedupes packs by set and counts uses', () async {
    final td = _FakeTd();
    final scanner = ChatStickerPacksService(query: td.call).chatScanner(1);
    await scanner.loadMore();

    expect(scanner.scannedMessages, 3);
    expect(scanner.exhausted, isTrue);
    expect(_uses(scanner.stickers), {10: 2});
    expect(_users(scanner.stickers), {10: 2}, reason: 'users 1 and 2');
    expect(scanner.stickers.single.lastUsed, 900);
    expect(scanner.stickers.single.itemCount, 10);
    expect(scanner.stickers.single.previews, hasLength(10));
    expect(_uses(scanner.emoji), {50: 2});
    expect(_users(scanner.emoji), {50: 1}, reason: 'one message, one sender');
  });

  test(
    'global scan merges every chat by message date, batch by batch',
    () async {
      final td = _FakeTd();
      final scanner = ChatStickerPacksService(query: td.call).globalScanner();

      // The two newest messages overall: chat 1 at 900, chat 2 at 800.
      await scanner.loadMore(messages: 2);
      expect(scanner.scannedMessages, 2);
      expect(_uses(scanner.stickers), {10: 1, 20: 1});
      expect(scanner.emoji, isEmpty);
      expect(scanner.exhausted, isFalse);

      // Next: the archived chat 3 at 700, then chat 2 at 600, whose custom
      // emoji reaction had three reactors.
      await scanner.loadMore(messages: 2);
      expect(_uses(scanner.stickers), {10: 1, 20: 1, 30: 1});
      expect(_uses(scanner.emoji), {60: 1, 50: 3});

      await scanner.loadMore();
      expect(scanner.scannedMessages, 6);
      expect(scanner.exhausted, isTrue);
      expect(_uses(scanner.stickers), {10: 2, 20: 1, 30: 1});
      // 501 (three reactors, then text) and 502 all land on set 50.
      expect(_uses(scanner.emoji), {60: 1, 50: 5});
      // Set 50: user 1's text plus the two named reactors, 5 and 6.
      expect(_users(scanner.emoji), {60: 1, 50: 3});
      expect(_users(scanner.stickers), {10: 2, 20: 1, 30: 1});
      expect(scanner.stickers.firstWhere((p) => p.id == 20).installed, isTrue);
      expect(
        td.requests.where((r) => r['@type'] == 'getStickerSet').length,
        5,
        reason: 'each set is looked up once across batches',
      );
    },
  );

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
          chatId: 2,
          service: ChatStickerPacksService(query: td.call),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pack 20'), findsOneWidget);
    expect(find.text('Added'), findsOneWidget, reason: 'set 20 is installed');
    final stats = find.byKey(const ValueKey('chat-sticker-pack-stats-20'));
    expect(
      find.descendant(of: stats, matching: find.text('1')),
      findsNWidgets(2),
      reason: 'one use by one person',
    );
    expect(
      tester.getBottomRight(stats).dy,
      lessThan(tester.getTopLeft(find.text('Added')).dy),
      reason: 'counts sit above the button',
    );
    expect(find.textContaining(RegExp(r'used \d')), findsNothing);
    expect(find.text('No older messages'), findsOneWidget);
    expect(find.byType(SliverGrid), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-sticker-packs-tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('Pack 50'), findsOneWidget);
    expect(find.text('Pack 60'), findsOneWidget);
    expect(find.text('Add (${60 % 17})'), findsOneWidget);
    expect(find.text('😀'), findsWidgets, reason: 'preview strip renders');

    await tester.tap(find.byKey(const ValueKey('chat-sticker-pack-add-50')));
    await tester.pumpAndSettle();
    expect(td.installed, contains(50));

    await tester.tap(find.byKey(const ValueKey('chat-sticker-packs-add-all')));
    await tester.pumpAndSettle();
    expect(td.installed, contains(60));
    expect(find.text('Added'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('filter, not-added and sort controls reshape the list', (
    tester,
  ) async {
    final td = _FakeTd();
    await tester.pumpWidget(
      await _app(
        ChatStickerPacksView(service: ChatStickerPacksService(query: td.call)),
      ),
    );
    await tester.pumpAndSettle();

    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(top('Pack 10'), lessThan(top('Pack 20')), reason: 'most used');

    await tester.tap(
      find.byKey(const ValueKey('chat-sticker-packs-sort-name')),
    );
    await tester.pumpAndSettle();
    expect(top('Pack 10'), lessThan(top('Pack 30')));

    // Tapping the active sort flips its direction.
    await tester.tap(
      find.byKey(const ValueKey('chat-sticker-packs-sort-name')),
    );
    await tester.pumpAndSettle();
    expect(top('Pack 30'), lessThan(top('Pack 10')));

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

  testWidgets('global finder reads every chat, newest messages first', (
    tester,
  ) async {
    final td = _FakeTd();
    await tester.pumpWidget(
      await _app(
        ChatStickerPacksView(service: ChatStickerPacksService(query: td.call)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sticker & Emoji Finder'), findsOneWidget);
    expect(find.text('From your last 6 messages'), findsOneWidget);
    expect(find.text('Pack 30'), findsOneWidget, reason: 'archived chat');
  });

  testWidgets('scrolling to the end loads the next batch of messages', (
    tester,
  ) async {
    final td = _longChat(1000);
    await tester.pumpWidget(
      await _app(
        ChatStickerPacksView(
          chatId: 9,
          service: ChatStickerPacksService(query: td.call),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 400 messages, four per set: 100 packs, far taller than the screen.
    expect(find.text('From the last 400 messages'), findsOneWidget);
    expect(find.text('Pack 1099'), findsNothing);

    await tester.dragUntilVisible(
      find.text('Pack 1099'),
      find.byType(CustomScrollView),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(find.text('From the last 800 messages'), findsOneWidget);
  });

  testWidgets('filling a short list pauses and offers Load more', (
    tester,
  ) async {
    final td = _longChat(4000, withPacks: false);
    await tester.pumpWidget(
      await _app(
        ChatStickerPacksView(
          chatId: 9,
          service: ChatStickerPacksService(query: td.call),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The first batch plus four automatic ones, then it waits for the user.
    expect(find.text('Load more'), findsOneWidget);
    final reads = _historyReads(td);

    await tester.tap(
      find.byKey(const ValueKey('chat-sticker-packs-load-more')),
    );
    await tester.pumpAndSettle();
    expect(_historyReads(td), greaterThan(reads));
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
      expect(find.byType(SliverGrid), findsOneWidget);
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
