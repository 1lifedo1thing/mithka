//
//  chat_sticker_packs_service.dart
//
//  Finds the sticker packs and custom-emoji packs a chat has used. Walks the
//  chat's recent history once, collects every sticker set id (sticker
//  messages) and custom_emoji_id (text/caption entities, single-emoji
//  messages, reactions), resolves custom emoji to their sets, and dedupes by
//  set id — so a pack used fifty times shows once, ranked by use count.
//

import 'dart:math' as math;

import '../tdlib/json_helpers.dart';
import '../tdlib/td_client.dart';
import 'custom_emoji.dart';
import 'emoji_store.dart';
import 'sticker_item.dart';
import 'sticker_store.dart';

typedef TdQuery =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

class ChatUsedPack {
  ChatUsedPack({
    required this.id,
    required this.title,
    required this.isCustomEmoji,
    required this.itemCount,
    required this.uses,
    required this.installed,
    this.cover,
  });

  final int id;
  final String title;
  final bool isCustomEmoji;
  final int itemCount;
  final int uses;
  final StickerItem? cover;
  bool installed;
}

class ChatUsedPacks {
  const ChatUsedPacks({
    required this.stickers,
    required this.emoji,
    required this.scannedMessages,
  });

  static const empty = ChatUsedPacks(
    stickers: [],
    emoji: [],
    scannedMessages: 0,
  );

  final List<ChatUsedPack> stickers;
  final List<ChatUsedPack> emoji;
  final int scannedMessages;
}

/// Raw set/emoji references pulled out of message JSON, before resolution.
class ChatPackReferences {
  /// Sticker set id → number of uses. Insertion order is newest first.
  final Map<int, int> stickerSets = {};

  /// custom_emoji_id → number of uses.
  final Map<int, int> customEmoji = {};

  void addMessage(Map<String, dynamic> message) {
    final content = message.obj('content');
    switch (content?.type) {
      case 'messageSticker':
        _addSticker(content!.obj('sticker'));
      case 'messageAnimatedEmoji':
        _addSticker(content!.obj('animated_emoji')?.obj('sticker'));
    }
    for (final text in [content?.obj('text'), content?.obj('caption')]) {
      for (final entity
          in text?.objects('entities') ?? const <Map<String, dynamic>>[]) {
        final type = entity.obj('type');
        if (type?.type != 'textEntityTypeCustomEmoji') continue;
        _bump(customEmoji, type!.int64('custom_emoji_id'));
      }
    }
    final reactions = message
        .obj('interaction_info')
        ?.obj('reactions')
        ?.objects('reactions');
    for (final reaction in reactions ?? const <Map<String, dynamic>>[]) {
      final type = reaction.obj('type');
      if (type?.type != 'reactionTypeCustomEmoji') continue;
      _bump(customEmoji, type!.int64('custom_emoji_id'));
    }
  }

  void _addSticker(Map<String, dynamic>? sticker) {
    if (sticker == null) return;
    final customEmojiId = sticker.obj('full_type')?.int64('custom_emoji_id');
    if (customEmojiId != null && customEmojiId != 0) {
      _bump(customEmoji, customEmojiId);
      return;
    }
    _bump(stickerSets, sticker.int64('set_id'));
  }

  static void _bump(Map<int, int> counts, int? id) {
    if (id == null || id == 0) return;
    counts[id] = (counts[id] ?? 0) + 1;
  }
}

class ChatStickerPacksService {
  ChatStickerPacksService({TdQuery? query})
    : _query = query ?? TdClient.shared.query;

  final TdQuery _query;

  static const int defaultMessageLimit = 1000;
  static const int _pageSize = 100;

  Future<ChatUsedPacks> scan(
    int chatId, {
    int messageLimit = defaultMessageLimit,
  }) async {
    final refs = ChatPackReferences();
    var scanned = 0;
    var fromMessageId = 0;
    while (scanned < messageLimit) {
      final page = await _query({
        '@type': 'getChatHistory',
        'chat_id': chatId,
        'from_message_id': fromMessageId,
        'offset': 0,
        'limit': math.min(_pageSize, messageLimit - scanned),
        'only_local': false,
      });
      final messages =
          page.objects('messages') ?? const <Map<String, dynamic>>[];
      if (messages.isEmpty) break;
      for (final message in messages) {
        refs.addMessage(message);
      }
      scanned += messages.length;
      final lastId = messages.last.int64('id');
      if (lastId == null || lastId == fromMessageId) break;
      fromMessageId = lastId;
    }
    return resolve(refs, scannedMessages: scanned);
  }

  /// Turns raw references into deduplicated, ranked packs.
  Future<ChatUsedPacks> resolve(
    ChatPackReferences refs, {
    required int scannedMessages,
  }) async {
    final setUses = Map<int, int>.of(refs.stickerSets);
    final emojiIds = refs.customEmoji.keys.toList();
    for (var i = 0; i < emojiIds.length; i += 200) {
      final batch = emojiIds.sublist(i, math.min(i + 200, emojiIds.length));
      try {
        final res = await _query({
          '@type': 'getCustomEmojiStickers',
          'custom_emoji_ids': batch.map((e) => e.toString()).toList(),
        });
        for (final sticker
            in res.objects('stickers') ?? const <Map<String, dynamic>>[]) {
          final setId = sticker.int64('set_id');
          final emojiId = sticker.obj('full_type')?.int64('custom_emoji_id');
          if (setId == null || setId == 0 || emojiId == null) continue;
          setUses[setId] =
              (setUses[setId] ?? 0) + (refs.customEmoji[emojiId] ?? 1);
        }
      } catch (_) {}
    }

    final stickers = <ChatUsedPack>[];
    final emoji = <ChatUsedPack>[];
    final ids = setUses.keys.toList();
    for (var i = 0; i < ids.length; i += 8) {
      final batch = ids.sublist(i, math.min(i + 8, ids.length));
      final packs = await Future.wait(
        batch.map((id) => _loadSet(id, setUses[id]!)),
      );
      for (final pack in packs) {
        if (pack == null) continue;
        (pack.isCustomEmoji ? emoji : stickers).add(pack);
      }
    }
    int byUses(ChatUsedPack a, ChatUsedPack b) => b.uses.compareTo(a.uses);
    // List.sort is not stable; keep newest-first order for equal counts.
    return ChatUsedPacks(
      stickers: _stableSorted(stickers, byUses),
      emoji: _stableSorted(emoji, byUses),
      scannedMessages: scannedMessages,
    );
  }

  Future<ChatUsedPack?> _loadSet(int id, int uses) async {
    try {
      final set = await _query({'@type': 'getStickerSet', 'set_id': id});
      final title = set.str('title');
      if (title == null) return null;
      final items = parseStickers(set.objects('stickers'));
      return ChatUsedPack(
        id: id,
        title: title,
        isCustomEmoji:
            set.obj('sticker_type')?.type == 'stickerTypeCustomEmoji',
        itemCount: items.length,
        uses: uses,
        installed: set.boolean('is_installed') ?? false,
        cover: items.isEmpty ? null : items.first,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> install(ChatUsedPack pack) async {
    try {
      await _query({
        '@type': 'changeStickerSet',
        'set_id': pack.id,
        'is_installed': true,
        'is_archived': false,
      });
      pack.installed = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Installs every pack not yet installed; returns how many succeeded.
  Future<int> installAll(Iterable<ChatUsedPack> packs) async {
    var added = 0;
    for (final pack in packs.where((p) => !p.installed).toList()) {
      if (await install(pack)) added += 1;
    }
    if (added > 0) refreshComposerStores();
    return added;
  }

  static void refreshComposerStores() {
    StickerStore.shared.invalidate();
    EmojiStore.shared.invalidate();
  }

  static List<T> _stableSorted<T>(List<T> list, int Function(T, T) compare) {
    final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
    indexed.sort((a, b) {
      final c = compare(a.$2, b.$2);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }
}
