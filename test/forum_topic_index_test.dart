import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/tdlib/forum_topic_index.dart';

Map<String, dynamic> _topic(
  int id, {
  String name = 'Topic',
  int unread = 0,
  int? lastMessageId,
  int lastReadInbox = 0,
  int muteFor = 0,
  int iconColor = 0,
}) => {
  '@type': 'forumTopic',
  'info': {
    '@type': 'forumTopicInfo',
    'forum_topic_id': id,
    'name': name,
    'icon_color': iconColor,
    'last_read_inbox_message_id': lastReadInbox,
  },
  if (lastMessageId != null)
    'last_message': {'@type': 'message', 'id': lastMessageId},
  'unread_count': unread,
  'notification_settings': {
    '@type': 'chatNotificationSettings',
    'mute_for': muteFor,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(ForumTopicIndex.shared.clear);

  test('parses a topic page and reports membership', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(_topic(1, name: 'General', unread: 3))!,
      ForumTopicIndexEntry.fromTopic(_topic(7, name: 'Dev'))!,
    ]);
    expect(ForumTopicIndex.shared.knowsTopics(0, -100), isTrue);
    final topics = ForumTopicIndex.shared.topicsFor(0, -100);
    expect(topics.length, 2);
    expect(ForumTopicIndex.shared.entryFor(0, -100, 7)?.name, 'Dev');
    expect(ForumTopicIndex.shared.entryFor(0, -100, 9), isNull);
    expect(ForumTopicIndex.shared.topicsFor(0, -200), isEmpty);
    expect(ForumTopicIndex.shared.topicsFor(1, -100), isEmpty);
  });

  test('an empty page drops the chat from the index', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(_topic(1))!,
    ]);
    ForumTopicIndex.shared.storeAll(0, -100, const []);
    expect(ForumTopicIndex.shared.knowsTopics(0, -100), isFalse);
  });

  test('new messages bump only the target topic counter', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(
        _topic(7, unread: 2, lastMessageId: 100, lastReadInbox: 90),
      )!,
    ]);
    ForumTopicIndex.shared.observe(0, {
      '@type': 'updateNewMessage',
      'message': {
        '@type': 'message',
        'id': 101,
        'chat_id': -100,
        'is_outgoing': false,
        'topic_id': {'@type': 'messageTopicForum', 'forum_topic_id': 7},
        'content': {'@type': 'messageText'},
      },
    });
    expect(ForumTopicIndex.shared.entryFor(0, -100, 7)?.unreadCount, 3);
    expect(ForumTopicIndex.shared.entryFor(0, -100, 7)?.lastMessageId, 101);

    // Outgoing traffic never inflates the counter.
    ForumTopicIndex.shared.observe(0, {
      '@type': 'updateNewMessage',
      'message': {
        '@type': 'message',
        'id': 102,
        'chat_id': -100,
        'is_outgoing': true,
        'topic_id': {'@type': 'messageTopicForum', 'forum_topic_id': 7},
        'content': {'@type': 'messageText'},
      },
    });
    expect(ForumTopicIndex.shared.entryFor(0, -100, 7)?.unreadCount, 3);
  });

  test('a message without a topic reference lands in General', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(_topic(1))!,
    ]);
    ForumTopicIndex.shared.observe(0, {
      '@type': 'updateNewMessage',
      'message': {
        '@type': 'message',
        'id': 5,
        'chat_id': -100,
        'is_outgoing': false,
        'content': {'@type': 'messageText'},
      },
    });
    expect(ForumTopicIndex.shared.entryFor(0, -100, 1)?.unreadCount, 1);
  });

  test('reading to the newest message clears the counter', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(
        _topic(7, unread: 4, lastMessageId: 200, lastReadInbox: 180),
      )!,
    ]);
    ForumTopicIndex.shared.observe(0, {
      '@type': 'updateForumTopic',
      'chat_id': -100,
      'forum_topic_id': 7,
      'last_read_inbox_message_id': 200,
    });
    final entry = ForumTopicIndex.shared.entryFor(0, -100, 7);
    expect(entry?.unreadCount, 0);
    expect(entry?.lastReadInboxMessageId, 200);
  });

  test('a partial read keeps the counter', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(
        _topic(7, unread: 4, lastMessageId: 200, lastReadInbox: 180),
      )!,
    ]);
    ForumTopicIndex.shared.observe(0, {
      '@type': 'updateForumTopic',
      'chat_id': -100,
      'forum_topic_id': 7,
      'last_read_inbox_message_id': 190,
    });
    expect(ForumTopicIndex.shared.entryFor(0, -100, 7)?.unreadCount, 4);
  });

  test('mute state follows notification settings updates', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(_topic(7))!,
    ]);
    ForumTopicIndex.shared.observe(0, {
      '@type': 'updateForumTopic',
      'chat_id': -100,
      'forum_topic_id': 7,
      'notification_settings': {
        '@type': 'chatNotificationSettings',
        'mute_for': 3600,
      },
    });
    expect(ForumTopicIndex.shared.entryFor(0, -100, 7)?.isMuted, isTrue);
  });

  test('a live counter ahead of a stale page wins over the page', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(
        _topic(7, unread: 1, lastMessageId: 300, lastReadInbox: 290),
      )!,
    ]);
    ForumTopicIndex.shared.observe(0, {
      '@type': 'updateNewMessage',
      'message': {
        '@type': 'message',
        'id': 301,
        'chat_id': -100,
        'is_outgoing': false,
        'topic_id': {'@type': 'messageTopicForum', 'forum_topic_id': 7},
        'content': {'@type': 'messageText'},
      },
    });
    // The stale page still reports the pre-bump snapshot.
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(
        _topic(7, unread: 1, lastMessageId: 300, lastReadInbox: 290),
      )!,
    ]);
    expect(ForumTopicIndex.shared.entryFor(0, -100, 7)?.unreadCount, 2);
    // A page that caught up is authoritative again.
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(
        _topic(7, unread: 5, lastMessageId: 301, lastReadInbox: 290),
      )!,
    ]);
    expect(ForumTopicIndex.shared.entryFor(0, -100, 7)?.unreadCount, 5);
  });

  test('renames through updateForumTopicInfo update the entry', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(_topic(7, name: 'Old'))!,
    ]);
    ForumTopicIndex.shared.observe(0, {
      '@type': 'updateForumTopicInfo',
      'info': {
        '@type': 'forumTopicInfo',
        'forum_topic_id': 7,
        'name': 'New',
        'icon': {
          '@type': 'forumTopicIcon',
          'custom_emoji_id': 55,
          'color': 0xFF1122,
        },
      },
    });
    final entry = ForumTopicIndex.shared.entryFor(0, -100, 7);
    expect(entry?.name, 'New');
    expect(entry?.iconCustomEmojiId, 55);
    expect(entry?.iconColor, 0xFF1122);
  });

  test('listeners wake on counter changes, not on bookkeeping', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(
        _topic(7, unread: 2, lastMessageId: 100, lastReadInbox: 90),
      )!,
    ]);
    var notifications = 0;
    ForumTopicIndex.shared.addListener(() => notifications++);

    ForumTopicIndex.shared.observe(0, {
      '@type': 'updateNewMessage',
      'message': {
        '@type': 'message',
        'id': 101,
        'chat_id': -100,
        'is_outgoing': false,
        'topic_id': {'@type': 'messageTopicForum', 'forum_topic_id': 7},
        'content': {'@type': 'messageText'},
      },
    });
    expect(notifications, 1);

    // A read position below the known one is bookkeeping only.
    ForumTopicIndex.shared.observe(0, {
      '@type': 'updateForumTopic',
      'chat_id': -100,
      'forum_topic_id': 7,
      'last_read_inbox_message_id': 95,
    });
    expect(notifications, 1);

    // Storing the same page again changes nothing displayed.
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(
        _topic(7, unread: 3, lastMessageId: 101, lastReadInbox: 95),
      )!,
    ]);
    expect(notifications, 1);
  });

  test('clearSlot drops only that slot', () {
    ForumTopicIndex.shared.storeAll(0, -100, [
      ForumTopicIndexEntry.fromTopic(_topic(7))!,
    ]);
    ForumTopicIndex.shared.storeAll(1, -100, [
      ForumTopicIndexEntry.fromTopic(_topic(8))!,
    ]);
    ForumTopicIndex.shared.clearSlot(0);
    expect(ForumTopicIndex.shared.knowsTopics(0, -100), isFalse);
    expect(ForumTopicIndex.shared.knowsTopics(1, -100), isTrue);
  });
}
