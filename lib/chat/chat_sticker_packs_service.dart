//
//  chat_sticker_packs_service.dart
//
//  Finds the sticker packs and custom-emoji packs used in one chat, or across
//  the user's recent chats. Walks recent history once, collects every sticker
//  set id (sticker messages) and custom_emoji_id (text/caption entities,
//  single custom-emoji messages, reactions), resolves custom emoji to their
//  sets, and dedupes by set id — so a pack used fifty times shows once.
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

/// Scanning walks chats first, then looks up each distinct pack.
enum ChatPackScanPhase { chats, packs }

typedef ChatPackScanProgress =
    void Function(ChatPackScanPhase phase, int done, int total);

class ChatUsedPack {
  ChatUsedPack({
    required this.id,
    required this.title,
    required this.isCustomEmoji,
    required this.itemCount,
    required this.uses,
    required this.lastUsed,
    required this.installed,
    this.previews = const [],
  });

  final int id;
  final String title;
  final bool isCustomEmoji;
  final int itemCount;
  final int uses;

  /// Unix time of the newest message that used this pack.
  final int lastUsed;

  /// The first items of the set, for the row's preview strip.
  final List<StickerItem> previews;
  bool installed;
}

class ChatUsedPacks {
  const ChatUsedPacks({
    required this.stickers,
    required this.emoji,
    required this.scannedMessages,
    this.scannedChats = 1,
  });

  static const empty = ChatUsedPacks(
    stickers: [],
    emoji: [],
    scannedMessages: 0,
  );

  final List<ChatUsedPack> stickers;
  final List<ChatUsedPack> emoji;
  final int scannedMessages;
  final int scannedChats;
}

/// Raw set/emoji references pulled out of message JSON, before resolution.
class ChatPackReferences {
  /// Sticker set id → number of uses.
  final Map<int, int> stickerSets = {};

  /// custom_emoji_id → number of uses.
  final Map<int, int> customEmoji = {};

  /// Newest message date per sticker set id / custom_emoji_id.
  final Map<int, int> stickerSetDates = {};
  final Map<int, int> customEmojiDates = {};

  void addMessage(Map<String, dynamic> message) {
    final date = message.integer('date') ?? 0;
    final content = message.obj('content');
    switch (content?.type) {
      case 'messageSticker':
        _addSticker(content!.obj('sticker'), date);
      case 'messageAnimatedEmoji':
        // A plain emoji sent alone animates from Telegram's built-in set,
        // which is not a pack anyone can add; only custom emoji count.
        final sticker = content!.obj('animated_emoji')?.obj('sticker');
        _addEmoji(sticker?.obj('full_type')?.int64('custom_emoji_id'), date);
    }
    for (final text in [content?.obj('text'), content?.obj('caption')]) {
      for (final entity
          in text?.objects('entities') ?? const <Map<String, dynamic>>[]) {
        final type = entity.obj('type');
        if (type?.type != 'textEntityTypeCustomEmoji') continue;
        _addEmoji(type!.int64('custom_emoji_id'), date);
      }
    }
    final reactions = message
        .obj('interaction_info')
        ?.obj('reactions')
        ?.objects('reactions');
    for (final reaction in reactions ?? const <Map<String, dynamic>>[]) {
      final type = reaction.obj('type');
      if (type?.type != 'reactionTypeCustomEmoji') continue;
      _addEmoji(type!.int64('custom_emoji_id'), date);
    }
  }

  void _addSticker(Map<String, dynamic>? sticker, int date) {
    if (sticker == null) return;
    final customEmojiId = sticker.obj('full_type')?.int64('custom_emoji_id');
    if (customEmojiId != null && customEmojiId != 0) {
      _addEmoji(customEmojiId, date);
      return;
    }
    _bump(stickerSets, stickerSetDates, sticker.int64('set_id'), date);
  }

  void _addEmoji(int? id, int date) =>
      _bump(customEmoji, customEmojiDates, id, date);

  static void _bump(
    Map<int, int> counts,
    Map<int, int> dates,
    int? id,
    int date,
  ) {
    if (id == null || id == 0) return;
    counts[id] = (counts[id] ?? 0) + 1;
    dates[id] = math.max(dates[id] ?? 0, date);
  }
}

class ChatStickerPacksService {
  ChatStickerPacksService({TdQuery? query})
    : _query = query ?? TdClient.shared.query;

  final TdQuery _query;

  static const int defaultMessageLimit = 1000;
  static const int defaultChatLimit = 40;
  static const int defaultPerChatLimit = 200;
  static const int previewCount = 16;
  static const int _pageSize = 100;
  static const int _chatConcurrency = 6;
  static const int _setConcurrency = 12;

  /// One chat's recent history.
  Future<ChatUsedPacks> scan(
    int chatId, {
    int messageLimit = defaultMessageLimit,
    ChatPackScanProgress? onProgress,
  }) async {
    final refs = ChatPackReferences();
    final scanned = await _scanHistory(chatId, messageLimit, refs);
    return resolve(refs, scannedMessages: scanned, onProgress: onProgress);
  }

  /// The newest [chatLimit] chats of the main list, [perChatLimit] messages
  /// each. [onProgress] reports finished chats, then looked-up packs.
  Future<ChatUsedPacks> scanRecentChats({
    int chatLimit = defaultChatLimit,
    int perChatLimit = defaultPerChatLimit,
    ChatPackScanProgress? onProgress,
  }) async {
    final chats = await _query({
      '@type': 'getChats',
      'chat_list': {'@type': 'chatListMain'},
      'limit': chatLimit,
    });
    final chatIds = chats.int64Array('chat_ids') ?? const <int>[];
    final refs = ChatPackReferences();
    var scanned = 0;
    var done = 0;
    onProgress?.call(ChatPackScanPhase.chats, 0, chatIds.length);
    // A few chats at a time keeps TDLib busy without flooding the network.
    for (var i = 0; i < chatIds.length; i += _chatConcurrency) {
      final batch = chatIds.sublist(
        i,
        math.min(i + _chatConcurrency, chatIds.length),
      );
      await Future.wait(
        batch.map((chatId) async {
          try {
            // Await first: `scanned += await …` would read the total before
            // the other chats in this batch add to it.
            final count = await _scanHistory(chatId, perChatLimit, refs);
            scanned += count;
          } catch (_) {}
          done += 1;
          onProgress?.call(ChatPackScanPhase.chats, done, chatIds.length);
        }),
      );
    }
    return resolve(
      refs,
      scannedMessages: scanned,
      scannedChats: chatIds.length,
      onProgress: onProgress,
    );
  }

  Future<int> _scanHistory(
    int chatId,
    int messageLimit,
    ChatPackReferences refs,
  ) async {
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
    return scanned;
  }

  /// Turns raw references into deduplicated packs, most used first.
  Future<ChatUsedPacks> resolve(
    ChatPackReferences refs, {
    required int scannedMessages,
    int scannedChats = 1,
    ChatPackScanProgress? onProgress,
  }) async {
    final setUses = Map<int, int>.of(refs.stickerSets);
    final setDates = Map<int, int>.of(refs.stickerSetDates);
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
          setDates[setId] = math.max(
            setDates[setId] ?? 0,
            refs.customEmojiDates[emojiId] ?? 0,
          );
        }
      } catch (_) {}
    }

    final stickers = <ChatUsedPack>[];
    final emoji = <ChatUsedPack>[];
    final ids = setUses.keys.toList();
    onProgress?.call(ChatPackScanPhase.packs, 0, ids.length);
    for (var i = 0; i < ids.length; i += _setConcurrency) {
      final batch = ids.sublist(i, math.min(i + _setConcurrency, ids.length));
      final packs = await Future.wait(
        batch.map((id) => _loadSet(id, setUses[id]!, setDates[id] ?? 0)),
      );
      for (final pack in packs) {
        if (pack == null) continue;
        (pack.isCustomEmoji ? emoji : stickers).add(pack);
      }
      onProgress?.call(
        ChatPackScanPhase.packs,
        math.min(i + _setConcurrency, ids.length),
        ids.length,
      );
    }
    return ChatUsedPacks(
      stickers: sortPacks(stickers, ChatPackSort.usage, descending: true),
      emoji: sortPacks(emoji, ChatPackSort.usage, descending: true),
      scannedMessages: scannedMessages,
      scannedChats: scannedChats,
    );
  }

  Future<ChatUsedPack?> _loadSet(int id, int uses, int lastUsed) async {
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
        lastUsed: lastUsed,
        installed: set.boolean('is_installed') ?? false,
        previews: items.take(previewCount).toList(growable: false),
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
}

enum ChatPackSort { usage, recent, name, size }

/// Stable sort, so equal keys keep their discovery order.
List<ChatUsedPack> sortPacks(
  List<ChatUsedPack> packs,
  ChatPackSort sort, {
  required bool descending,
}) {
  int compare(ChatUsedPack a, ChatUsedPack b) => switch (sort) {
    ChatPackSort.usage => a.uses.compareTo(b.uses),
    ChatPackSort.recent => a.lastUsed.compareTo(b.lastUsed),
    ChatPackSort.name => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    ChatPackSort.size => a.itemCount.compareTo(b.itemCount),
  };
  final indexed = [for (var i = 0; i < packs.length; i++) (i, packs[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    if (c != 0) return descending ? -c : c;
    return a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// Title filter plus an optional "not added yet" filter.
List<ChatUsedPack> filterPacks(
  List<ChatUsedPack> packs, {
  String query = '',
  bool onlyMissing = false,
}) {
  final needle = query.trim().toLowerCase();
  return [
    for (final pack in packs)
      if ((!onlyMissing || !pack.installed) &&
          (needle.isEmpty || pack.title.toLowerCase().contains(needle)))
        pack,
  ];
}
