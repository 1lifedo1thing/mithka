//
//  forum_topic_fields.dart
//
//  Readers for a forum topic's fields. TDLib reports a topic as a
//  `forumTopic` plus its `forumTopicInfo`, and older layers keep some fields
//  on only one of the two, so each reader checks both.
//

import 'package:flutter/widgets.dart';

import '../tdlib/json_helpers.dart';

int? forumTopicId(TdObject topic, TdObject info) =>
    info.integer('forum_topic_id') ??
    topic.integer('forum_topic_id') ??
    info.int64('message_thread_id') ??
    topic.int64('message_thread_id');

/// Unread messages in the topic, falling back to unread mentions; never
/// negative.
int forumTopicUnreadCount(TdObject topic, TdObject info) {
  final count =
      topic.integer('unread_count') ??
      info.integer('unread_count') ??
      topic.integer('unread_mention_count') ??
      info.integer('unread_mention_count') ??
      0;
  return count < 0 ? 0 : count;
}

/// The topic icon's custom emoji, or 0 for the default icon.
int forumTopicCustomEmojiId(TdObject topic, TdObject info) =>
    info.obj('icon')?.int64('custom_emoji_id') ??
    topic.obj('icon')?.int64('custom_emoji_id') ??
    info.int64('icon_custom_emoji_id') ??
    topic.int64('icon_custom_emoji_id') ??
    0;

/// The topic icon's opaque RGB color, or null when TDLib reports none.
Color? forumTopicIconColor(TdObject topic, TdObject info) {
  final raw =
      info.obj('icon')?.integer('color') ??
      topic.obj('icon')?.integer('color') ??
      info.integer('icon_color') ??
      topic.integer('icon_color');
  if (raw == null || raw == 0) return null;
  return Color(0xFF000000 | (raw & 0xFFFFFF));
}
