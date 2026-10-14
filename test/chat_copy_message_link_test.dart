import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view.dart'
    show ChatView, clearChatMemoryCaches;
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/settings/translation_controller.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/l10n_fixtures.dart';

// Shell-level regression for "复制消息链接": the long-press action menu gains a
// Copy Message Link entry gated on the server-reported
// messageProperties.can_get_link, and selecting it copies the TDLib-generated
// getMessageLink URL. Pumped through the real ChatView against the TdClient
// proxy so the actual scoped TDLib requests are pinned.

const _chatId = -1004242;

Map<String, dynamic> _textMessage(int id) => {
  '@type': 'message',
  'id': id,
  'chat_id': _chatId,
  'date': 1785862260 + id,
  'is_outgoing': false,
  'sender_id': {'@type': 'messageSenderUser', 'user_id': 2},
  'content': {
    '@type': 'messageText',
    'text': {
      '@type': 'formattedText',
      'text': 'shareable message $id',
      'entities': <Map<String, dynamic>>[],
    },
  },
};

Map<String, dynamic> _chatJson() => {
  '@type': 'chat',
  'id': _chatId,
  'title': 'Group chat',
  'type': {
    '@type': 'chatTypeSupergroup',
    'supergroup_id': -_chatId - 1000000000000,
    'is_channel': false,
  },
  'last_read_inbox_message_id': 5,
  'unread_count': 0,
  'permissions': {'can_send_basic_messages': true},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  L10nFixtures.load().install();

  // Clipboard.setData never returns in a plain widget test (no platform
  // plugin) — mock the platform channel and record what the app copied.
  final clipboard = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });

  late List<Map<String, dynamic>> requests;
  late bool canGetLink;
  setUpAll(() {
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(Map<String, dynamic>.from(request));
          return switch (request['@type']) {
            'getChat' => _chatJson(),
            'getChatHistory' => {
              '@type': 'messages',
              'total_count': 1,
              'messages': [_textMessage(5)],
            },
            'getMe' => {
              '@type': 'user',
              'id': 1,
              'type': {'@type': 'userTypeRegular'},
            },
            'getUser' => {
              '@type': 'user',
              'id': request['user_id'] ?? 2,
              'first_name': 'Member',
              'type': {'@type': 'userTypeRegular'},
            },
            'getSupergroup' => {
              '@type': 'supergroup',
              'id': -_chatId - 1000000000000,
            },
            'getSupergroupFullInfo' => {
              '@type': 'supergroupFullInfo',
              'member_count': 3,
            },
            'getMessageProperties' => {
              '@type': 'messageProperties',
              'can_get_link': canGetLink,
            },
            'getMessageLink' => {
              '@type': 'messageLink',
              'link': 'https://t.me/c/4242/5',
              'is_public': false,
            },
            'getMessageAvailableReactions' => {
              '@type': 'availableReactions',
              'top_reactions': <Map<String, dynamic>>[],
              'recent_reactions': <Map<String, dynamic>>[],
              'popular_reactions': <Map<String, dynamic>>[],
              'allow_custom_emoji': false,
              'are_tags': false,
              'unavailability_reason': null,
            },
            'getOption' => {'@type': 'optionValueBoolean', 'value': false},
            _ => {'@type': 'ok'},
          };
        },
        send: (_) async {},
        updates: const Stream.empty(),
      ),
    );
  });
  tearDownAll(TdClient.shared.closeProxy);

  late ThemeController theme;
  late TranslationController translation;

  setUp(() async {
    requests = [];
    canGetLink = true;
    SharedPreferences.setMockInitialValues({});
    theme = ThemeController(await SharedPreferences.getInstance());
    translation = TranslationController(await SharedPreferences.getInstance());
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    clearChatMemoryCaches();
    theme.dispose();
    translation.dispose();
  });

  Future<void> openMenuOnMessage(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    clearChatMemoryCaches();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ThemeController>.value(value: theme),
          ChangeNotifierProvider<TranslationController>.value(
            value: translation,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            extensions: [AppColors.light],
            platform: TargetPlatform.android,
          ),
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ChatView(chatId: _chatId, title: 'Group'),
        ),
      ),
    );
    // The chat surface keeps timers alive (progress polling): bounded pumps
    // instead of pumpAndSettle.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(
      find.byKey(const ValueKey('messageTapTarget-5')),
      findsOneWidget,
      reason: 'the fixture message must render',
    );
    await tester.longPress(find.byKey(const ValueKey('messageTapTarget-5')));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
  }

  testWidgets('a linkable message offers Copy Message Link and copies it', (
    tester,
  ) async {
    await openMenuOnMessage(tester);

    final linkAction = find.byKey(
      const ValueKey('message-action-copyMessageLink'),
    );
    expect(linkAction, findsOneWidget);
    expect(
      requests.whereType<Map<String, dynamic>>().any(
        (request) =>
            request['@type'] == 'getMessageProperties' &&
            request['message_id'] == 5,
      ),
      isTrue,
      reason: 'availability is decided by the server-provided flag',
    );

    await tester.tap(linkAction);
    await tester.pump(const Duration(milliseconds: 300));
    expect(clipboard, ['https://t.me/c/4242/5']);
    expect(
      requests.whereType<Map<String, dynamic>>().any(
        (request) =>
            request['@type'] == 'getMessageLink' && request['message_id'] == 5,
      ),
      isTrue,
      reason: 'the copied URL is the TDLib-generated link',
    );
    expect(find.text('Link copied'), findsOneWidget);

    // Drain the toast (visibleFor + hold timer) and the chat surface.
    debugDefaultTargetPlatformOverride = null;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a message without a linkable flag keeps the entry hidden', (
    tester,
  ) async {
    canGetLink = false;
    await openMenuOnMessage(tester);

    expect(
      find.byKey(const ValueKey('message-action-copyMessageLink')),
      findsNothing,
    );
    expect(
      requests.whereType<Map<String, dynamic>>().any(
        (request) => request['@type'] == 'getMessageLink',
      ),
      isFalse,
      reason: 'no link request is sent for a message the server excluded',
    );

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });
}
