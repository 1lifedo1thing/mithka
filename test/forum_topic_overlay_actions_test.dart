//
//  forum_topic_overlay_actions_test.dart
//
//  The split shell's topic-list overlay carries the moderation affordances
//  of the live transcript: create gated on the real rights, the row menu
//  gated per TDLib's model, and every action firing its TDLib request.
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

void main() {
  late StreamController<Map<String, dynamic>> updates;
  final requests = <Map<String, dynamic>>[];
  var adminRights = false;
  var canCreateTopics = false;
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
          return _response(request, adminRights, canCreateTopics);
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });
  setUp(() {
    requests.clear();
    clearChatMemoryCaches();
    ForumTopicIndex.shared.clear();
    adminRights = false;
    canCreateTopics = false;
  });
  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  testWidgets('member: no create button, row menu offers read and mute only', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _setSurfaceSize(tester, const Size(1180, 820));
      await _pumpMainShell(tester);
      tester.widget<ChatListView>(find.byType(ChatListView)).onChatSelected!(
        ChatListSelection.fromChat(_chat()),
      );
      await _settle(tester);

      // No create right: the overlay header hides its '+'.
      expect(find.byKey(const ValueKey('topic-list-create')), findsNothing);

      // Topic 79 arrives unread; its row menu offers mark-read and mute,
      // never pin/edit/close/delete for a plain member.
      await tester.longPress(
        find.byKey(const ValueKey('topic-navigation-item-79')),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('topic-row-menu-79')), findsOneWidget);
      expect(find.byKey(const ValueKey('topic-menu-read')), findsOneWidget);
      expect(find.byKey(const ValueKey('topic-menu-mute')), findsOneWidget);
      expect(find.byKey(const ValueKey('topic-menu-pin')), findsNothing);
      expect(find.byKey(const ValueKey('topic-menu-edit')), findsNothing);
      expect(find.byKey(const ValueKey('topic-menu-close')), findsNothing);
      expect(find.byKey(const ValueKey('topic-menu-delete')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('topic-menu-read')));
      await _settle(tester);
      // Mark-read views the topic's newest message (topic 79's row pins
      // message 68 as its last).
      expect(
        requests.any(
          (request) =>
              request['@type'] == 'viewMessages' &&
              (request['message_ids'] as List).contains(68),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('admin: pin and create fire their TDLib requests', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      adminRights = true;
      canCreateTopics = true;
      await _setSurfaceSize(tester, const Size(1180, 820));
      await _pumpMainShell(tester);
      tester.widget<ChatListView>(find.byType(ChatListView)).onChatSelected!(
        ChatListSelection.fromChat(_chat()),
      );
      await _settle(tester);

      // The create right lights the overlay header's '+'.
      expect(find.byKey(const ValueKey('topic-list-create')), findsOneWidget);

      await tester.longPress(
        find.byKey(const ValueKey('topic-navigation-item-78')),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('topic-menu-pin')));
      await _settle(tester);
      expect(
        requests.any(
          (request) =>
              request['@type'] == 'toggleForumTopicIsPinned' &&
              request['forum_topic_id'] == 78 &&
              request['is_pinned'] == true,
        ),
        isTrue,
      );

      // Create flows through the shared draft dialog and opens the topic.
      await tester.tap(find.byKey(const ValueKey('topic-list-create')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('topic-draft-name')),
        'Fresh',
      );
      await tester.tap(find.byKey(const ValueKey('topic-draft-save')));
      await _settle(tester);
      expect(
        requests.any(
          (request) =>
              request['@type'] == 'createForumTopic' &&
              request['name'] == 'Fresh',
        ),
        isTrue,
      );
      expect(tester.widget<ChatView>(find.byType(ChatView)).forumTopicId, 500);
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

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
  isForum: true,
);

Map<String, dynamic> _message(int id, {String? text}) => <String, dynamic>{
  '@type': 'message',
  'id': id,
  'chat_id': -42,
  'date': id,
  'is_outgoing': false,
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': text ?? 'Post $id'},
  },
};

Map<String, dynamic> _response(
  Map<String, dynamic> request,
  bool adminRights,
  bool canCreateTopics,
) => switch (request['@type']) {
  'getChat' => {
    '@type': 'chat',
    'id': request['chat_id'],
    'title': 'Forum',
    'view_as_topics': true,
    'type': {
      '@type': 'chatTypeSupergroup',
      'supergroup_id': 42,
      'is_channel': false,
    },
    'permissions': {
      '@type': 'chatPermissions',
      'can_send_basic_messages': true,
      'can_create_topics': canCreateTopics,
    },
  },
  'getSupergroup' => {
    '@type': 'supergroup',
    'id': 42,
    'is_forum': true,
    'has_forum_tabs': false,
    'status': adminRights
        ? {
            '@type': 'chatMemberStatusAdministrator',
            'rights': {
              '@type': 'chatAdministratorRights',
              'can_manage_topics': true,
              'can_delete_messages': true,
            },
          }
        : {'@type': 'chatMemberStatusMember'},
  },
  'getConnectionState' => {'@type': 'connectionStateReady'},
  'createForumTopic' => {
    '@type': 'forumTopicInfo',
    'chat_id': -42,
    'forum_topic_id': 500,
    'name': request['name'],
  },
  'getForumTopics' => {
    '@type': 'forumTopics',
    'topics': [
      for (var index = 0; index < 12; index++)
        {
          '@type': 'forumTopic',
          'info': {
            '@type': 'forumTopicInfo',
            'chat_id': -42,
            'forum_topic_id': 77 + index,
            'name': 'Topic $index',
          },
          'last_message': _message(70 - index),
          'unread_count': index == 2 ? 4 : 0, // topic 79 is unread
        },
    ],
  },
  'getForumTopicHistory' || 'getMessageThreadHistory' => {
    '@type': 'messages',
    'messages': [
      _message(
        70 - ((request['forum_topic_id'] ?? request['message_id']) as int) + 77,
      ),
    ],
  },
  'getMessage' => _message(request['message_id'] as int),
  'getChatHistory' => {
    '@type': 'messages',
    'messages': [_message(70)],
  },
  'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Test'},
  _ => {'@type': 'ok'},
};

Future<void> _pumpMainShell(
  WidgetTester tester, {
  bool reducedMotion = true,
}) async {
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
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reducedMotion,
            textScaler: TextScaler.noScaling,
          ),
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

Future<void> _setSurfaceSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 3),
  );
}
