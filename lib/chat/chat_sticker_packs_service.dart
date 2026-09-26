//
//  chat_sticker_packs_service.dart
//
//  Finds the sticker packs and custom-emoji packs used in one chat, or across
//  all of the user's chats. A [ChatPackScanner] walks messages newest first a
//  batch at a time — for the global finder, every chat's history merged into
//  one timeline by date — so a list can load more as the user scrolls.
//  Each batch collects sticker set ids (sticker messages) and custom_emoji_ids
//  (text/caption entities, single custom-emoji messages, reactions), resolves
//  the new ones to their sets, and dedupes by set id.
//

import 'dart:collection';
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
    required this.lastUsed,
    required this.installed,
    this.previews = const [],
  });

  final int id;
  final String title;
  final bool isCustomEmoji;
  final int itemCount;

  /// Uses in the messages scanned so far; grows as the scan goes back.
  int uses;

  /// Unix time of the newest message that used this pack.
  int lastUsed;

  /// The first items of the set, for the row's preview strip.
  final List<StickerItem> previews;
  bool installed;
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

  /// One chat's history, newest first.
  ChatPackScanner chatScanner(int chatId) =>
      ChatPackScanner._(_query, cursors: [_ChatCursor(chatId, _unknownDate)]);

  /// Every chat in the main list and the archive, merged by message date.
  ChatPackScanner globalScanner() => ChatPackScanner._(
    _query,
    sources: [
      _ChatListSource({'@type': 'chatListMain'}),
      _ChatListSource({'@type': 'chatListArchive'}),
    ],
  );

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

/// Upper bound for a chat whose newest message date is not known yet.
const int _unknownDate = 1 << 62;

class _ChatCursor {
  _ChatCursor(this.chatId, this.upperBound);

  final int chatId;

  /// No unread message in this chat is newer than this.
  int upperBound;
  int fromMessageId = 0;
  bool exhausted = false;
  final Queue<Map<String, dynamic>> buffer = Queue();

  bool get live => buffer.isNotEmpty || !exhausted;
  int get head =>
      buffer.isNotEmpty ? (buffer.first.integer('date') ?? 0) : upperBound;
}

class _ChatListSource {
  _ChatListSource(this.chatList);

  final Map<String, dynamic> chatList;
  int loaded = 0;
  bool exhausted = false;

  /// Every chat not loaded yet had its last message at or before this.
  int boundary = _unknownDate;
}

/// Walks messages newest first and keeps the packs found so far.
class ChatPackScanner {
  ChatPackScanner._(
    this._query, {
    List<_ChatCursor> cursors = const [],
    List<_ChatListSource> sources = const [],
  }) : _cursors = [...cursors],
       _sources = [...sources];

  static const int batchSize = 400;
  static const int previewCount = 16;
  static const int _pageSize = 100;
  static const int _chatPage = 50;
  static const int _fetchConcurrency = 6;
  static const int _setConcurrency = 12;

  final TdQuery _query;
  final List<_ChatCursor> _cursors;
  final List<_ChatListSource> _sources;
  final Set<int> _knownChats = {};
  final ChatPackReferences _refs = ChatPackReferences();
  final LinkedHashMap<int, ChatUsedPack> _packs = LinkedHashMap();
  final Set<int> _unresolvableSets = {};
  final Map<int, int> _emojiSets = {};
  final Set<int> _unresolvableEmoji = {};

  int scannedMessages = 0;

  /// True once every chat's history has been read to the start.
  bool exhausted = false;

  /// Packs found so far, in discovery order (newest use first).
  List<ChatUsedPack> get stickers => [
    for (final p in _packs.values)
      if (!p.isCustomEmoji) p,
  ];
  List<ChatUsedPack> get emoji => [
    for (final p in _packs.values)
      if (p.isCustomEmoji) p,
  ];

  /// Scans the next [messages] messages and folds them into the packs.
  Future<void> loadMore({int messages = batchSize}) async {
    if (exhausted) return;
    final batch = await _nextMessages(messages);
    for (final message in batch) {
      _refs.addMessage(message);
    }
    scannedMessages += batch.length;
    await _resolveNew();
    _recount();
  }

  Future<List<Map<String, dynamic>>> _nextMessages(int count) async {
    final out = <Map<String, dynamic>>[];
    while (out.length < count) {
      await _loadChatsIfNeeded();
      final newest = _newest();
      if (newest == null) {
        exhausted = true;
        break;
      }
      if (newest.buffer.isEmpty) {
        await _fetchAround(newest);
        continue;
      }
      final message = newest.buffer.removeFirst();
      newest.upperBound = message.integer('date') ?? 0;
      out.add(message);
    }
    return out;
  }

  _ChatCursor? _newest() {
    _ChatCursor? best;
    for (final cursor in _cursors) {
      if (!cursor.live) continue;
      if (best == null || cursor.head > best.head) best = cursor;
    }
    return best;
  }

  /// Loads more of each chat list while an unloaded chat could hold a message
  /// newer than every loaded one.
  Future<void> _loadChatsIfNeeded() async {
    for (final source in _sources) {
      while (!source.exhausted && (_newest()?.head ?? -1) < source.boundary) {
        await _loadChats(source);
      }
    }
  }

  Future<void> _loadChats(_ChatListSource source) async {
    final limit = source.loaded + _chatPage;
    try {
      final res = await _query({
        '@type': 'getChats',
        'chat_list': source.chatList,
        'limit': limit,
      });
      final ids = res.int64Array('chat_ids') ?? const <int>[];
      final fresh = ids.skip(source.loaded).toList();
      source.loaded = ids.length;
      if (ids.length < limit || fresh.isEmpty) source.exhausted = true;
      final dates = await Future.wait(fresh.map(_lastMessageDate));
      for (var i = 0; i < fresh.length; i++) {
        if (!_knownChats.add(fresh[i])) continue;
        final cursor = _ChatCursor(fresh[i], dates[i]);
        if (dates[i] <= 0) cursor.exhausted = true;
        _cursors.add(cursor);
      }
      // Pinned chats lead the list whatever their dates, so the list's tail
      // is the one that bounds the chats still to come.
      if (dates.isNotEmpty) source.boundary = dates.last;
    } catch (_) {
      source.exhausted = true;
    }
  }

  Future<int> _lastMessageDate(int chatId) async {
    try {
      final chat = await _query({'@type': 'getChat', 'chat_id': chatId});
      return chat.obj('last_message')?.integer('date') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Fetches the next page for [cursor] and, in parallel, for the other
  /// empty chats likely to be needed next, so a merge does not wait on one
  /// round trip per chat.
  Future<void> _fetchAround(_ChatCursor cursor) async {
    final waiting =
        _cursors
            .where((c) => c != cursor && c.buffer.isEmpty && !c.exhausted)
            .toList()
          ..sort((a, b) => b.head.compareTo(a.head));
    await Future.wait(
      [cursor, ...waiting.take(_fetchConcurrency - 1)].map(_fetch),
    );
  }

  Future<void> _fetch(_ChatCursor cursor) async {
    try {
      final page = await _query({
        '@type': 'getChatHistory',
        'chat_id': cursor.chatId,
        'from_message_id': cursor.fromMessageId,
        'offset': 0,
        'limit': _pageSize,
        'only_local': false,
      });
      final messages =
          page.objects('messages') ?? const <Map<String, dynamic>>[];
      var added = 0;
      for (final message in messages) {
        final id = message.int64('id');
        if (id == null) continue;
        // The page can repeat the message it started from.
        if (cursor.fromMessageId != 0 && id >= cursor.fromMessageId) continue;
        cursor.buffer.add(message);
        cursor.fromMessageId = id;
        added += 1;
      }
      if (added == 0) cursor.exhausted = true;
    } catch (_) {
      cursor.exhausted = true;
    }
  }

  Future<void> _resolveNew() async {
    final emojiIds = [
      for (final id in _refs.customEmoji.keys)
        if (!_emojiSets.containsKey(id) && !_unresolvableEmoji.contains(id)) id,
    ];
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
          _emojiSets[emojiId] = setId;
        }
      } catch (_) {}
      for (final id in batch) {
        if (!_emojiSets.containsKey(id)) _unresolvableEmoji.add(id);
      }
    }

    final setIds = <int>{..._refs.stickerSets.keys, ..._emojiSets.values}
        .where(
          (id) => !_packs.containsKey(id) && !_unresolvableSets.contains(id),
        )
        .toList();
    for (var i = 0; i < setIds.length; i += _setConcurrency) {
      final batch = setIds.sublist(
        i,
        math.min(i + _setConcurrency, setIds.length),
      );
      final packs = await Future.wait(batch.map(_loadSet));
      for (var j = 0; j < batch.length; j++) {
        final pack = packs[j];
        if (pack == null) {
          _unresolvableSets.add(batch[j]);
        } else {
          _packs[pack.id] = pack;
        }
      }
    }
  }

  Future<ChatUsedPack?> _loadSet(int id) async {
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
        uses: 0,
        lastUsed: 0,
        installed: set.boolean('is_installed') ?? false,
        previews: items.take(previewCount).toList(growable: false),
      );
    } catch (_) {
      return null;
    }
  }

  /// Recomputes every pack's totals from the cumulative references.
  void _recount() {
    final uses = Map<int, int>.of(_refs.stickerSets);
    final dates = Map<int, int>.of(_refs.stickerSetDates);
    _refs.customEmoji.forEach((emojiId, count) {
      final setId = _emojiSets[emojiId];
      if (setId == null) return;
      uses[setId] = (uses[setId] ?? 0) + count;
      dates[setId] = math.max(
        dates[setId] ?? 0,
        _refs.customEmojiDates[emojiId] ?? 0,
      );
    });
    for (final pack in _packs.values) {
      pack.uses = uses[pack.id] ?? 0;
      pack.lastUsed = dates[pack.id] ?? 0;
    }
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
