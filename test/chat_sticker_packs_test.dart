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

Map<String, dynamic> _sticker(int setId) => {
  '@type': 'message',
  'id': 0,
  'content': {
    '@type': 'messageSticker',
    'sticker': {'@type': 'sticker', 'set_id': '$setId'},
  },
};

Map<String, dynamic> _text(List<int> emojiIds, {int? reactionEmojiId}) => {
  '@type': 'message',
  'id': 0,
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

/// A fake TDLib: history of 3 pages, custom emoji 501/502 → set 50, 601 → 60.
class _FakeTd {
  final requests = <Map<String, dynamic>>[];
  final installed = <int>{20};

  late final List<List<Map<String, dynamic>>> pages = [
    [
      _sticker(10),
      _sticker(20),
      _sticker(10),
      _text([501, 502]),
    ],
    [
      _sticker(10),
      _text([601], reactionEmojiId: 501),
    ],
  ];

  // Round-trip through JSON so nested maps are typed like real TDLib output.
  Future<Map<String, dynamic>> call(Map<String, dynamic> request) async =>
      jsonDecode(jsonEncode(_respond(request))) as Map<String, dynamic>;

  Map<String, dynamic> _respond(Map<String, dynamic> request) {
    requests.add(request);
    switch (request['@type']) {
      case 'getChatHistory':
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
          'stickers': [],
        };
      case 'changeStickerSet':
        installed.add(request['set_id'] as int);
        return {'@type': 'ok'};
    }
    throw StateError('unexpected ${request['@type']}');
  }
}

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
    expect(result.emoji.map((p) => p.id), [50, 60]);
    // 501 twice (text + reaction) and 502 once all land on set 50.
    expect(result.emoji.first.uses, 3);
    expect(result.stickers[1].installed, isTrue);
    expect(
      td.requests.where((r) => r['@type'] == 'getStickerSet').length,
      4,
      reason: 'each set is looked up once',
    );
  });

  test('stops paging at the message limit', () async {
    final td = _FakeTd();
    final result = await ChatStickerPacksService(
      query: td.call,
    ).scan(1, messageLimit: 3);
    expect(result.scannedMessages, 3);
    expect(td.requests.first['limit'], 3);
  });

  testWidgets('phone layout: tabs, add one, add all', (tester) async {
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
        44,
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
