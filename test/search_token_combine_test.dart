import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_message_search_bar.dart';
import 'package:mithka/chat/chat_message_search_controller.dart';
import 'package:mithka/chats/search_view.dart';
import 'package:mithka/components/keyboard_dismiss_on_tap.dart';
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

  testWidgets('typed from: and has: combine while retaining in-chat focus', (
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
    final musicRow = find.byKey(
      ValueKey('searchTokenSuggestion-${ChatSearchFilter.music.index}'),
    );
    expect(
      find.descendant(of: musicRow, matching: find.text('Music')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey('searchTokenSuggestion-${ChatSearchFilter.links.index}'),
      ),
      findsOneWidget,
    );

    final pick = await tester.startGesture(tester.getCenter(musicRow));
    await tester.pump();
    expect(
      controller.focusNode.hasFocus,
      isTrue,
      reason: 'a filter suggestion must remain inside the search field region',
    );
    await pick.up();
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();

    // The picked kind completes the token; both filters reach TDLib together.
    // applyChatSearchToken's contract: value glued to the key, caret past a
    // separating space — the same shape every other token completion leaves.
    expect(controller.textController.text, 'from:@mao has:music ');
    final searches = requests
        .where((request) => request['@type'] == 'searchChatMessages')
        .toList();
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
    // once the raw query is emptied the remaining tokens are offered again.
    // clear() deliberately resets badges too, so simulate editing the text.
    expect(controller.query, isEmpty);
    final field = find.byKey(const ValueKey('desktop-title-bar-search-input'));
    await tester.enterText(field, 'needle');
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    expect(controller.resolvedSender?.id, 55);
    expect(
      find.byKey(const ValueKey('desktop-title-bar-search-from')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('searchTokenHints')), findsOneWidget);
    expect(find.byKey(const ValueKey('searchTokenHint-has:')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('searchTokenHint-has:')));
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    expect(controller.textController.text, 'has:');

    // Completing the kind narrows the search while the sender stays committed.
    requests.clear();
    final musicRow = find.byKey(
      ValueKey('searchTokenSuggestion-${ChatSearchFilter.music.index}'),
    );
    expect(musicRow, findsOneWidget);
    final musicPress = await tester.startGesture(tester.getCenter(musicRow));
    await tester.pump();
    expect(controller.focusNode.hasFocus, isTrue);
    await musicPress.up();
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    final searches = requests
        .where((request) => request['@type'] == 'searchChatMessages')
        .toList();
    expect(searches, isNotEmpty);
    expect(
      searches.every(
        (request) =>
            (request['sender_id'] as Map<String, dynamic>)['user_id'] == 55,
      ),
      isTrue,
    );
    expect(
      searches.every(
        (request) =>
            (request['filter'] as Map<String, dynamic>)['@type'] ==
            'searchMessagesFilterAudio',
      ),
      isTrue,
    );
  });

  testWidgets('committed sender and picked has: combine in the real header', (
    tester,
  ) async {
    final controller = ChatMessageSearchController(chatId: _chatId);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_chatHarness(controller));
    controller.open();
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('chatSearchField'));
    await tester.enterText(field, 'from:@mao');
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    final senderPress = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('searchTokenSuggestion-55'))),
    );
    await tester.pump();
    expect(controller.focusNode.hasFocus, isTrue);
    await senderPress.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chatSearchSenderChip')), findsOneWidget);
    expect(controller.textController.text, isEmpty);

    final hintPress = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('searchTokenHint-has:'))),
    );
    await tester.pump();
    expect(controller.focusNode.hasFocus, isTrue);
    await hintPress.up();
    await tester.pumpAndSettle();
    requests.clear();
    final musicPress = await tester.startGesture(
      tester.getCenter(
        find.byKey(
          ValueKey('searchTokenSuggestion-${ChatSearchFilter.music.index}'),
        ),
      ),
    );
    await tester.pump();
    expect(controller.focusNode.hasFocus, isTrue);
    await musicPress.up();
    await tester.pump(const Duration(milliseconds: 281));
    await tester.pumpAndSettle();
    final search = requests.lastWhere(
      (request) => request['@type'] == 'searchChatMessages',
    );
    expect(search['chat_id'], _chatId);
    expect(search['query'], '');
    expect(search['sender_id'], {'@type': 'messageSenderUser', 'user_id': 55});
    expect(search['filter'], {'@type': 'searchMessagesFilterAudio'});
    expect(find.byKey(const ValueKey('chatSearchSenderChip')), findsOneWidget);
  });

  testWidgets('desktop suggestions follow selection-only caret changes', (
    tester,
  ) async {
    final controller = DesktopInlineSearchController(
      miniAppSearch: (_) async => const [],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_desktopHarness(controller));
    final field = find.byKey(const ValueKey('desktop-title-bar-search-input'));
    await tester.enterText(field, 'from:@mao has:mu');
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    expect(controller.activeToken?.kind.name, 'has');
    controller.textController.selection = const TextSelection.collapsed(
      offset: 6,
    );
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    expect(controller.activeToken?.kind.name, 'from');
    expect(controller.suggestions.single.id, 55);
    controller.textController.selection = const TextSelection.collapsed(
      offset: 15,
    );
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    expect(controller.activeToken?.kind.name, 'has');
    expect(controller.suggestions.single.token, 'music');
  });

  testWidgets('in-chat suggestions follow selection-only caret changes', (
    tester,
  ) async {
    final controller = ChatMessageSearchController(chatId: _chatId);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_chatHarness(controller));
    controller.open();
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('chatSearchField'));
    await tester.enterText(field, 'from:@mao has:mu');
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    expect(controller.activeToken?.kind.name, 'has');
    controller.textController.selection = const TextSelection.collapsed(
      offset: 6,
    );
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    expect(
      controller.activeToken?.kind.name,
      'from',
      reason: 'moving the caret must refresh suggestions without editing text',
    );
    expect(controller.suggestions.single.id, 55);
    controller.textController.selection = const TextSelection.collapsed(
      offset: 15,
    );
    await tester.pump(const Duration(milliseconds: 241));
    await tester.pumpAndSettle();
    expect(controller.activeToken?.kind.name, 'has');
    expect(controller.suggestions.single.token, 'music');
  });
}

const _chatId = -100200;

Widget _chatHarness(ChatMessageSearchController controller) => MaterialApp(
  builder: (context, child) =>
      AppKeyboardDismissOnTap(child: child ?? const SizedBox.shrink()),
  locale: const Locale('en'),
  localizationsDelegates: const [AppLocalizations.delegate],
  supportedLocales: AppLocalizations.supportedLocales,
  theme: ThemeData(extensions: [AppColors.light]),
  home: Scaffold(
    body: Column(
      children: [
        ChatSearchHeaderBar(
          controller: controller,
          height: 44,
          onClose: controller.close,
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
  builder: (context, child) =>
      AppKeyboardDismissOnTap(child: child ?? const SizedBox.shrink()),
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
      'getGroupsInCommon' => {
        '@type': 'chats',
        'total_count': 1,
        'chat_ids': <int>[_chatId],
      },
      'createPrivateChat' => {
        '@type': 'chat',
        'id': 55,
        'title': 'Mao Contact',
        'type': {'@type': 'chatTypePrivate', 'user_id': 55},
        'positions': <Map<String, dynamic>>[],
        'unread_count': 0,
      },
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
