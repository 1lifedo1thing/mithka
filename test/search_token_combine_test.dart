import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_message_search_bar.dart';
import 'package:mithka/chat/chat_message_search_controller.dart';
import 'package:mithka/chats/search_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';

/// `from:` and `has:` must combine: committing one filter must not close the
/// only door to the other. These tests pin the two halves — the committed
/// sender keeps the hint card alive with the tokens still available, and a
/// picked `has:` value completes the token in the field and reaches the search.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> updates;
  late List<Map<String, dynamic>> requests;

  setUpAll(() {
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(Map<String, dynamic>.from(request));
          return _response(request);
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  setUp(() => requests = []);

  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  testWidgets('a committed from: keeps the has: hint reachable in-chat', (
    tester,
  ) async {
    final controller = ChatMessageSearchController(chatId: _chatId);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_chatHarness(controller));
    controller.open();
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'from:@mao has:');
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();

    // The caret sits in a has: token with no kind yet: the field offers its
    // closed vocabulary instead of hits for a half-written filter.
    expect(
      find.byKey(const ValueKey('searchTokenSuggestions')),
      findsOneWidget,
    );
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Links'), findsOneWidget);

    await tester.tap(find.text('Music'));
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();

    // The picked kind completes the token; both filters reach TDLib together.
    // applyChatSearchToken's contract: value glued to the key, caret past a
    // separating space — the same shape every other token completion leaves.
    expect(controller.textController.text, 'from:@mao has:music ');
    final searches = requests
        .where((request) => request['@type'] == 'searchChatMessages')
        .toList();
    // ignore: avoid_print
    print('DEBUGREQ ${requests.map((r) => r["@type"]).toList()}');
    // ignore: avoid_print
    print(
      'DEBUGF ${requests.where((r) => r["@type"] == "searchChatMessages").map((r) => r["filter"]).toList()}',
    );
    expect(searches, isNotEmpty);
    // The run after the completion carries both filters together: the audio
    // filter from `has:` and the sender resolved from `from:`.
    final last = searches.last;
    expect(
      (last['filter'] as Map<String, dynamic>)['@type'],
      'searchMessagesFilterAudio',
    );
    expect((last['sender_id'] as Map<String, dynamic>)['user_id'], 55);
  });

  testWidgets('a committed desktop from: keeps the has: hint reachable', (
    tester,
  ) async {
    final controller = DesktopInlineSearchController(
      miniAppSearch: (_) async => const [],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_desktopHarness(controller));

    await tester.enterText(
      find.byKey(const ValueKey('desktop-title-bar-search-input')),
      'from:@mao',
    );
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('searchTokenSuggestion-55')));
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('desktop-title-bar-search-from')),
      findsOneWidget,
    );

    // The badge did not lock the field: results arrive for the sender, and
    // once the query is emptied the remaining tokens — `has:` among them —
    // are offered again.
    expect(controller.query, isEmpty);
    controller.clear();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('searchTokenHints')), findsOneWidget);
    expect(find.byKey(const ValueKey('searchTokenHint-has:')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('searchTokenHint-has:')));
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    expect(controller.textController.text, 'has:');

    // Completing the kind narrows the search while the sender stays committed.
    await tester.enterText(
      find.byKey(const ValueKey('desktop-title-bar-search-input')),
      'has: music',
    );
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    final searches = requests
        .where((request) => request['@type'] == 'searchChatMessages')
        .toList();
    // ignore: avoid_print
    print('DEBUGREQ ${requests.map((r) => r["@type"]).toList()}');
    // ignore: avoid_print
    print(
      'DEBUGF ${requests.where((r) => r["@type"] == "searchChatMessages").map((r) => r["filter"]).toList()}',
    );
    expect(searches, isNotEmpty);
    expect(
      searches.every(
        (request) =>
            (request['sender_id'] as Map<String, dynamic>)['user_id'] == 55,
      ),
      isTrue,
    );
    expect(
      searches.any(
        (request) =>
            (request['filter'] as Map<String, dynamic>)['@type'] ==
            'searchMessagesFilterAudio',
      ),
      isTrue,
    );
  });
}

const _chatId = -100200;

Widget _chatHarness(ChatMessageSearchController controller) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [AppLocalizations.delegate],
  supportedLocales: AppLocalizations.supportedLocales,
  theme: ThemeData(extensions: [AppColors.light]),
  home: Scaffold(
    body: Column(
      children: [
        SizedBox(
          height: 44,
          child: Center(
            child: TextField(
              controller: controller.textController,
              focusNode: controller.focusNode,
              onChanged: controller.updateQuery,
            ),
          ),
        ),
        Expanded(
          child: ChatSearchResultsPane(
            controller: controller,
            peerTitle: 'Group',
            onSelect: (_) {},
          ),
        ),
      ],
    ),
  ),
);

Widget _desktopHarness(DesktopInlineSearchController controller) => MaterialApp(
  theme: ThemeData(extensions: [AppColors.light]),
  home: Scaffold(
    body: Column(
      children: [
        DesktopInlineSearchField(controller: controller, onSearchAll: (_) {}),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: DesktopInlineSearchPanel(
              controller: controller,
              onSearchAll: (_) {},
            ),
          ),
        ),
      ],
    ),
  ),
);

Map<String, dynamic> _response(Map<String, dynamic> request) =>
    switch (request['@type']) {
      'searchContacts' => {
        '@type': 'users',
        'user_ids': <int>[55],
      },
      'searchPublicChat' => {
        '@type': 'chat',
        'id': 55,
        'title': 'Mao Contact',
        'type': {'@type': 'chatTypePrivate', 'user_id': 55},
        'positions': <Map<String, dynamic>>[],
        'unread_count': 0,
      },
      'getUser' => {
        '@type': 'user',
        'id': request['user_id'],
        'first_name': 'Mao',
        'last_name': 'Contact',
        'status': {'@type': 'userStatusOffline', 'was_online': 0},
      },
      'searchChatMembers' => {
        '@type': 'chatMembers',
        'total_count': 1,
        'members': [
          {
            '@type': 'chatMember',
            'member_id': {'@type': 'messageSenderUser', 'user_id': 55},
            'status': {'@type': 'chatMemberStatusMember'},
          },
        ],
      },
      'searchChatMessages' => {
        '@type': 'foundChatMessages',
        'total_count': 0,
        'next_from_message_id': 0,
        'messages': <Map<String, dynamic>>[],
      },
      'searchMessages' => {
        '@type': 'foundMessages',
        'total_count': 0,
        'next_from_message_id': '',
        'messages': <Map<String, dynamic>>[],
      },
      _ => <String, dynamic>{'@type': 'ok'},
    };
