//
//  forum_topic_section_headers_test.dart
//
//  A forum opened without a topic mixes every topic into one transcript. The
//  messages then need a topic attribution so the reader can tell which topic
//  each one belongs to — the section header Telegram iOS draws at every topic
//  boundary, which also navigates to that topic.
//

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/chat_deep_link_controller.dart';
import 'package:mithka/app/main_tab_view.dart';
import 'package:mithka/auth/account_store.dart';
import 'package:mithka/auth/auth_manager.dart';
import 'package:mithka/chat/chat_view.dart';
import 'package:mithka/chats/chat_list_view.dart';
import 'package:mithka/components/drawer_controller.dart' as dc;
import 'package:mithka/l10n/app_locale_controller.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/translation_controller.dart';
import 'package:mithka/tdlib/forum_topic_index.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The mixed-topic transcript the fixtures return, oldest first.
///
/// 10-11 belong to topic 78, 12/14 to General (TDLib omits `topic_id`
/// there), 13 is a service event with no topic, and 15 belongs to topic 99,
/// which the topic page does not list.
/// When set, the fixtures describe a plain supergroup instead of a forum.
var groupChat = false;

final List<Map<String, dynamic>> _mixedHistory = [
  _message(10, 'In topic A', topicId: 78),
  _message(11, 'Still topic A', topicId: 78),
  _message(12, 'In general'),
  _serviceMessage(13),
  _message(14, 'Also general'),
  _message(15, 'Unlisted topic', topicId: 99),
];

void main() {
  final requests = <Map<String, dynamic>>[];
  late StreamController<Map<String, dynamic>> updates;
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('mithka/share_intent'),
          (call) async => null,
        );
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(request);
          return _response(request);
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
    // Native TDLib supplies this pushed state; it cannot be queried.
    TdClient.shared.routeUpdateForTesting({
      '@type': 'updateConnectionState',
      '@client_id': 1,
      'state': {'@type': 'connectionStateReady'},
    });
  });
  setUp(() {
    requests.clear();
    clearChatMemoryCaches();
    ForumTopicIndex.shared.clear();
    groupChat = false;
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  testWidgets('the mixed-topic transcript sections messages by topic', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1180, 820);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _pumpMainShell(tester);
      tester.widget<ChatListView>(find.byType(ChatListView)).onChatSelected!(
        ChatListSelection.fromChat(_chat()),
      );
      await _settle(tester);

      // The All view is the unscoped transcript.
      expect(tester.widget<ChatView>(find.byType(ChatView)).forumTopicId, null);

      // One header per topic run, named after the topic it introduces.
      expect(
        find.byKey(const ValueKey('forum-topic-section-78')),
        findsOneWidget,
        reason: 'the run of topic-78 messages carries exactly one header',
      );
      expect(_headerLabel(tester, 78), 'Topic A');
      expect(
        find.byKey(const ValueKey('forum-topic-section-1')),
        findsOneWidget,
        reason:
            'the service event between the two General messages must not '
            'split the General run',
      );
      expect(_headerLabel(tester, 1), 'General');

      // A topic the loaded page does not list still gets an attributed
      // header rather than silently joining the previous run.
      expect(
        find.byKey(const ValueKey('forum-topic-section-99')),
        findsOneWidget,
      );
      expect(
        _headerLabel(tester, 99),
        'Topic',
        reason: 'falls back to a generic label when the topic is unknown',
      );

      // Ordering: the headers sit above their own run, oldest first.
      final headers = tester
          .widgetList<Padding>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Padding &&
                  widget.key is ValueKey<String> &&
                  (widget.key as ValueKey<String>).value.startsWith(
                    'forum-topic-section-',
                  ),
            ),
          )
          .map((widget) => (widget.key as ValueKey<String>).value)
          .toList();
      expect(headers, [
        'forum-topic-section-78',
        'forum-topic-section-1',
        'forum-topic-section-99',
      ]);
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a section header opens that topic transcript', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1180, 820);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _pumpMainShell(tester);
      tester.widget<ChatListView>(find.byType(ChatListView)).onChatSelected!(
        ChatListSelection.fromChat(_chat()),
      );
      await _settle(tester);

      await tester.tap(
        find.byKey(const ValueKey('forum-topic-section-tap-78')),
      );
      await _settle(tester);

      expect(tester.widget<ChatView>(find.byType(ChatView)).forumTopicId, 78);
      // A scoped transcript is one topic already: no sections inside it.
      expect(
        find.byKey(const ValueKey('forum-topic-section-78')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a live message from another topic starts a new section', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1180, 820);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _pumpMainShell(tester);
      tester.widget<ChatListView>(find.byType(ChatListView)).onChatSelected!(
        ChatListSelection.fromChat(_chat()),
      );
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('forum-topic-section-79')),
        findsNothing,
      );

      // The newest message lands in topic 79, which the mixed history had
      // not shown yet.
      updates.add({
        '@type': 'updateNewMessage',
        'message': _message(16, 'Fresh in B', topicId: 79),
      });
      await _settle(tester);

      expect(
        find.byKey(const ValueKey('forum-topic-section-79')),
        findsOneWidget,
        reason: 'a live arrival is attributed like any other message',
      );
      expect(_headerLabel(tester, 79), 'Topic B');
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a phone All-topics transcript sections and navigates', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _pumpMainShell(tester);
      ChatDeepLinkController.shared.openChat(chatId: -42, title: 'Forum');
      await _settle(tester);

      // The phone surface has no overlay rail, but the mixed transcript is
      // attributed the same way.
      expect(tester.widget<ChatView>(find.byType(ChatView)).forumTopicId, null);
      expect(
        find.byKey(const ValueKey('forum-topic-section-78')),
        findsOneWidget,
      );
      expect(_headerLabel(tester, 78), 'Topic A');
      expect(
        find.byKey(const ValueKey('forum-topic-section-1')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('forum-topic-section-tap-78')),
      );
      await _settle(tester);
      expect(tester.widget<ChatView>(find.byType(ChatView)).forumTopicId, 78);
      expect(
        find.byKey(const ValueKey('forum-topic-section-78')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('an ordinary group transcript draws no topic sections', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    groupChat = true;
    try {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1180, 820);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _pumpMainShell(tester);
      tester.widget<ChatListView>(find.byType(ChatListView)).onChatSelected!(
        ChatListSelection.fromChat(_chat()),
      );
      await _settle(tester);

      // A plain supergroup is not a forum: its messages carry no topic, and a
      // "General" header would be a fiction the reader cannot navigate.
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Padding &&
              widget.key is ValueKey<String> &&
              (widget.key as ValueKey<String>).value.startsWith(
                'forum-topic-section-',
              ),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      groupChat = false;
    }
  });
}

/// The label a rendered section header shows.
String _headerLabel(WidgetTester tester, int topicId) =>
    tester
        .widget<Text>(
          find.byKey(ValueKey('forum-topic-section-label-$topicId')),
        )
        .data ??
    '';

ChatSummary _chat() => ChatSummary(
  id: -42,
  title: 'Forum',
  lastMessage: '',
  lastMessageId: 0,
  date: 0,
  unreadCount: 0,
  order: 1,
  isMuted: false,
  kind: ChatKind.group,
  isForum: !groupChat,
);

Map<String, dynamic> _message(int id, String text, {int? topicId}) =>
    <String, dynamic>{
      '@type': 'message',
      'id': id,
      'chat_id': -42,
      'date': id,
      'is_outgoing': false,
      'sender_id': {'@type': 'messageSenderUser', 'user_id': 7},
      if (topicId != null)
        'topic_id': {'@type': 'messageTopicForum', 'forum_topic_id': topicId},
      'content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': text},
      },
    };

/// A pin event: TDLib reports service messages without a topic reference.
Map<String, dynamic> _serviceMessage(int id) => <String, dynamic>{
  '@type': 'message',
  'id': id,
  'chat_id': -42,
  'date': id,
  'is_outgoing': false,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': 7},
  'content': {'@type': 'messagePinMessage', 'message_id': id - 1},
};

Map<String, dynamic> _response(Map<String, dynamic> request) =>
    switch (request['@type']) {
      'getChat' => {
        '@type': 'chat',
        'id': request['chat_id'],
        'title': groupChat ? 'Group' : 'Forum',
        'view_as_topics': !groupChat,
        'type': {
          '@type': 'chatTypeSupergroup',
          'supergroup_id': 42,
          'is_channel': false,
        },
        'permissions': {
          '@type': 'chatPermissions',
          'can_send_basic_messages': true,
        },
      },
      'getSupergroup' => {
        '@type': 'supergroup',
        'id': 42,
        'is_forum': !groupChat,
        'has_forum_tabs': false,
        'status': {'@type': 'chatMemberStatusMember'},
      },
      'getConnectionState' => {'@type': 'connectionStateReady'},
      'getForumTopics' => {
        '@type': 'forumTopics',
        'topics': [
          {
            '@type': 'forumTopic',
            'info': {
              '@type': 'forumTopicInfo',
              'chat_id': -42,
              'forum_topic_id': 1,
              'name': 'General',
              'is_general': true,
            },
            'last_message': _message(12, 'In general'),
          },
          {
            '@type': 'forumTopic',
            'info': {
              '@type': 'forumTopicInfo',
              'chat_id': -42,
              'forum_topic_id': 78,
              'name': 'Topic A',
            },
            'last_message': _message(11, 'Still topic A', topicId: 78),
          },
          {
            '@type': 'forumTopic',
            'info': {
              '@type': 'forumTopicInfo',
              'chat_id': -42,
              'forum_topic_id': 79,
              'name': 'Topic B',
              'icon_color': 0x00FF8800,
            },
            'last_message': _message(9, 'In topic B', topicId: 79),
          },
          // Topic 99 is deliberately absent: the transcript shows a message
          // from it, so the header has to fall back to a generic label.
        ],
      },
      'getForumTopic' => {
        '@type': 'forumTopic',
        'info': {
          '@type': 'forumTopicInfo',
          'chat_id': -42,
          'forum_topic_id': request['forum_topic_id'],
          'name': 'Topic ${(request['forum_topic_id'] as int) - 77}',
        },
      },
      'getForumTopicHistory' || 'getMessageThreadHistory' => {
        '@type': 'messages',
        'messages': [
          _message(
            20,
            'Scoped to ${(request['forum_topic_id'] ?? 0)}',
            topicId: request['forum_topic_id'] as int?,
          ),
        ],
      },
      'searchChatMessages'
          when (request['filter'] as Map?)?['@type'] ==
              'searchMessagesFilterPinned' =>
        {'@type': 'foundChatMessages', 'total_count': 0, 'messages': <Map>[]},
      'getChatHistory' => {'@type': 'messages', 'messages': _mixedHistory},
      'getMessage' => _message(request['message_id'] as int, 'Fetched'),
      'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
      'getUser' => {
        '@type': 'user',
        'id': request['user_id'],
        'first_name': 'Author',
      },
      _ => {'@type': 'ok'},
    };

Future<void> _pumpMainShell(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'showChannelsTab': false,
    'showMomentsTab': false,
    'communitiesEnabled': false,
  });
  final prefs = await SharedPreferences.getInstance();
  final theme = ThemeController(prefs);
  final accounts = AccountStore(prefs);
  final auth = AuthManager();
  final translation = TranslationController(prefs);
  final drawer = dc.DrawerController();
  final deepLinks = ChatDeepLinkController.shared;
  deepLinks.consumePending();

  addTearDown(theme.dispose);
  addTearDown(accounts.dispose);
  addTearDown(auth.dispose);
  addTearDown(translation.dispose);
  addTearDown(drawer.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<AppLocaleController>.value(
          value: AppLocaleController(prefs),
        ),
        ChangeNotifierProvider<AccountStore>.value(value: accounts),
        ChangeNotifierProvider<AuthManager>.value(value: auth),
        ChangeNotifierProvider<TranslationController>.value(value: translation),
        ChangeNotifierProvider<ChatDeepLinkController>.value(value: deepLinks),
        ChangeNotifierProvider<dc.DrawerController>.value(value: drawer),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          brightness: Brightness.light,
          extensions: [AppColors.light],
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: true, textScaler: TextScaler.noScaling),
          child: child!,
        ),
        home: const MainSplitRootView(),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _disposeShell(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}
