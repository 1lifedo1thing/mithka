import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/channels/topic_chat_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the aggregated feed labels every post with its topic chip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final theme = ThemeController(preferences);
    addTearDown(theme.dispose);
    final requests = <Map<String, dynamic>>[];
    final chat = ChatSummary(
      id: -10042,
      title: 'Forum',
      lastMessage: 'Latest',
      lastMessageId: 90,
      date: 90,
      unreadCount: 0,
      order: 1,
      isMuted: false,
      isForum: true,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: TopicChatView(
            chat: chat,
            showBackButton: false,
            query: (request) async {
              requests.add(Map<String, dynamic>.from(request));
              return switch (request['@type']) {
                'getForumTopics' => _forumTopicsResponse(),
                'getForumTopicHistory' => _historyResponse(
                  int.parse((request['forum_topic_id'] as num).toString()),
                ),
                _ => {
                  '@type': 'messages',
                  'messages': const <Map<String, dynamic>>[],
                },
              };
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Both posts carry their topic's name in a chip in the "All" feed.
    // Each topic's stubbed history holds two messages, so each chip
    // renders twice.
    expect(find.byKey(const ValueKey('topic-post-chip-1')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('topic-post-chip-2')), findsNWidgets(2));
    expect(
      find.text('Post in General 101', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Post in Design 201', findRichText: true), findsOneWidget);

    // Tapping a post's chip opens that topic: the chip disappears because
    // the feed becomes topic-scoped.
    await tester.tap(find.byKey(const ValueKey('topic-post-chip-2')).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('topic-post-chip-1')), findsNothing);
    expect(find.byKey(const ValueKey('topic-post-chip-2')), findsNothing);
    expect(find.text('Post in Design 201', findRichText: true), findsOneWidget);
    // Topic 2's messages were already cached by the All-feed preview, so
    // the only topic-2 history request is that initial limit-6 probe; the
    // scoping itself is asserted by the chips disappearing above.
    expect(
      requests.where((request) => request['@type'] == 'getForumTopicHistory'),
      contains(
        equals({
          '@type': 'getForumTopicHistory',
          'chat_id': -10042,
          'forum_topic_id': 2,
          'from_message_id': 0,
          'offset': 0,
          'limit': 6,
        }),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a topic-scoped feed does not label its posts', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final theme = ThemeController(preferences);
    addTearDown(theme.dispose);
    final chat = ChatSummary(
      id: -10042,
      title: 'Forum',
      lastMessage: 'Latest',
      lastMessageId: 90,
      date: 90,
      unreadCount: 0,
      order: 1,
      isMuted: false,
      isForum: true,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeController>.value(
        value: theme,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: AppLocalizations.supportedLocales,
          home: TopicChatView(
            chat: chat,
            initialThreadId: 2,
            showBackButton: false,
            query: (request) async {
              return switch (request['@type']) {
                'getForumTopics' => _forumTopicsResponse(),
                'getForumTopicHistory' => _historyResponse(2),
                _ => {
                  '@type': 'messages',
                  'messages': const <Map<String, dynamic>>[],
                },
              };
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('topic-post-chip-2')), findsNothing);
    expect(find.text('Design'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

Map<String, dynamic> _forumTopicsResponse() => {
  '@type': 'forumTopics',
  'topics': [
    _topic(1, 'General', 20, color: 1),
    _topic(2, 'Design', 40, color: 2),
  ],
};

Map<String, dynamic> _topic(
  int id,
  String name,
  int lastMessageDate, {
  int? color,
}) => {
  '@type': 'forumTopic',
  'info': {
    '@type': 'forumTopicInfo',
    'forum_topic_id': id,
    'name': name,
    if (color != null) 'icon': {'@type': 'chatTheme', 'color': color},
  },
  'unread_count': 0,
  'order': -lastMessageDate,
  'last_message': _message(id * 100, lastMessageDate, topic: name),
};

Map<String, dynamic> _historyResponse(int topicId) => {
  '@type': 'messages',
  'messages': [
    _message(
      topicId * 100 + 1,
      topicId * 10 + 1,
      topic: topicId == 1 ? 'General' : 'Design',
    ),
    _message(
      topicId * 100 + 2,
      topicId * 10 + 2,
      topic: topicId == 1 ? 'General' : 'Design',
    ),
  ],
};

Map<String, dynamic> _message(int id, int date, {required String topic}) => {
  '@type': 'message',
  'id': id,
  'chat_id': -10042,
  'date': date,
  'is_outgoing': false,
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': 'Post in $topic $id'},
  },
};
