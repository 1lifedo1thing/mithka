import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chats/chat_list_view.dart';
import 'package:mithka/chats/chat_list_view_model.dart';
import 'package:mithka/tdlib/td_models.dart';

void main() {
  ChatSummary chat(
    int id, {
    int unread = 0,
    bool markedUnread = false,
    bool muted = false,
  }) => ChatSummary(
    id: id,
    title: 'Chat $id',
    lastMessage: 'hi',
    lastMessageId: 1,
    date: id,
    unreadCount: unread,
    isMarkedUnread: markedUnread,
    isMuted: muted,
    order: id,
  );

  testWidgets('folder badges count unread chats, not unread messages', (
    tester,
  ) async {
    final model = ChatListViewModel();
    addTearDown(model.dispose);

    // Folder 7 gains three chats: one read, one with 50 unread messages in a
    // single chat, one flagged unread without a count. Only two are unread
    // chats, so the badge must read 2.
    model.applyUpdateForTesting({
      '@type': 'updateChatFolders',
      'chat_folders': [
        {'id': 7, 'title': 'Work'},
      ],
    });
    model.seedChatForTesting(chat(1, unread: 50));
    model.seedChatForTesting(chat(2));
    model.seedChatForTesting(chat(3, markedUnread: true));
    model.seedChatForTesting(chat(9, unread: 4));
    model.applyUpdateForTesting({
      '@type': 'updateChatPosition',
      'chat_id': 1,
      'position': {
        '@type': 'chatPosition',
        'order': 10,
        'is_pinned': false,
        'list': {'@type': 'chatListFolder', 'chat_folder_id': 7},
      },
    });
    model.applyUpdateForTesting({
      '@type': 'updateChatPosition',
      'chat_id': 2,
      'position': {
        '@type': 'chatPosition',
        'order': 9,
        'is_pinned': false,
        'list': {'@type': 'chatListFolder', 'chat_folder_id': 7},
      },
    });
    model.applyUpdateForTesting({
      '@type': 'updateChatPosition',
      'chat_id': 3,
      'position': {
        '@type': 'chatPosition',
        'order': 8,
        'is_pinned': false,
        'list': {'@type': 'chatListFolder', 'chat_folder_id': 7},
      },
    });
    // chat 9 stays out of the folder: its unread must not leak in.
    await tester.pump(const Duration(milliseconds: 60));

    final work = model.filters.firstWhere((f) => f.folderId == 7);
    expect(work.unreadChatCount, 2);
    expect(work.hasUnmutedUnread, isTrue);
    expect(model.filters.first.unreadChatCount, 0);

    // Reading one chat drops the badge to 1.
    model.applyUpdateForTesting({
      '@type': 'updateChatReadInbox',
      'chat_id': 1,
      'last_read_inbox_message_id': 1,
      'unread_count': 0,
    });
    await tester.pump(const Duration(milliseconds: 60));
    expect(model.filters.firstWhere((f) => f.folderId == 7).unreadChatCount, 1);
  });

  testWidgets('an all-muted folder keeps its count but loses the accent', (
    tester,
  ) async {
    final model = ChatListViewModel();
    addTearDown(model.dispose);
    model.applyUpdateForTesting({
      '@type': 'updateChatFolders',
      'chat_folders': [
        {'id': 2, 'title': 'Quiet'},
      ],
    });
    model.seedChatForTesting(chat(5, unread: 3, muted: true));
    model.applyUpdateForTesting({
      '@type': 'updateChatPosition',
      'chat_id': 5,
      'position': {
        '@type': 'chatPosition',
        'order': 7,
        'is_pinned': false,
        'list': {'@type': 'chatListFolder', 'chat_folder_id': 2},
      },
    });
    await tester.pump(const Duration(milliseconds: 60));
    final quiet = model.filters.firstWhere((f) => f.folderId == 2);
    expect(quiet.unreadChatCount, 1);
    expect(quiet.hasUnmutedUnread, isFalse);
  });

  testWidgets('a folder that excludes muted chats skips them entirely', (
    tester,
  ) async {
    final model = ChatListViewModel();
    addTearDown(model.dispose);
    model.applyUpdateForTesting({
      '@type': 'updateChatFolders',
      'chat_folders': [
        {'id': 4, 'title': 'Loud only', 'exclude_muted': true},
      ],
    });
    model.seedChatForTesting(chat(6, unread: 2, muted: true));
    model.seedChatForTesting(chat(7, unread: 1));
    model.applyUpdateForTesting({
      '@type': 'updateChatPosition',
      'chat_id': 6,
      'position': {
        '@type': 'chatPosition',
        'order': 7,
        'is_pinned': false,
        'list': {'@type': 'chatListFolder', 'chat_folder_id': 4},
      },
    });
    model.applyUpdateForTesting({
      '@type': 'updateChatPosition',
      'chat_id': 7,
      'position': {
        '@type': 'chatPosition',
        'order': 6,
        'is_pinned': false,
        'list': {'@type': 'chatListFolder', 'chat_folder_id': 4},
      },
    });
    await tester.pump(const Duration(milliseconds: 60));
    final loudOnly = model.filters.firstWhere((f) => f.folderId == 4);
    expect(loudOnly.unreadChatCount, 1);
    expect(loudOnly.hasUnmutedUnread, isTrue);
  });

  testWidgets('folder tab strips and rails draw the badge next to the glyph', (
    tester,
  ) async {
    const filter = ChatFilterOption(
      title: 'Work',
      folderId: 7,
      unreadChatCount: 3,
      hasUnmutedUnread: true,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: ChatFolderRail(
          filters: [
            ChatFilterOption(title: 'All'),
            filter,
          ],
          selectedFolderId: null,
          showUnreadBadges: true,
        ),
      ),
    );
    expect(find.text('3'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(find.text('3'), findsNothing);
  });
}
