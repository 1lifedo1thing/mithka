import '../tdlib/json_helpers.dart';
import 'chat_delete_policy.dart';

typedef ChatRemovalQuery =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> request);

class ChatRemovalUnavailable implements Exception {
  const ChatRemovalUnavailable();
}

/// Membership has already changed even though basic-group history cleanup
/// failed. Callers must not present this as a failed leave or retry the leave.
class ChatLeaveHistoryCleanupFailed implements Exception {
  const ChatLeaveHistoryCleanupFailed(this.cause);

  final Object cause;
}

Future<void> clearChatHistoryForSelf({
  required int chatId,
  required ChatRemovalQuery query,
  bool removeFromChatList = false,
}) async {
  final chat = await query({'@type': 'getChat', 'chat_id': chatId});
  if (!chatDeleteCapabilities(chat).canDeleteForSelf) {
    throw const ChatRemovalUnavailable();
  }
  await query(
    deleteChatHistoryRequest(
      chatId: chatId,
      scope: ChatDeleteScope.self,
      removeFromChatList: removeFromChatList,
    ),
  );
}

Future<void> leaveChatAndRemoveFromList({
  required int chatId,
  required ChatRemovalQuery query,
  required void Function() onLeft,
}) async {
  // ChatKind.group combines basic groups and supergroups. Only basic groups
  // need a separate history-deletion request after leaving.
  final chat = await query({'@type': 'getChat', 'chat_id': chatId});
  final type = chat.obj('type')?.type;
  if (type != 'chatTypeBasicGroup' && type != 'chatTypeSupergroup') {
    throw const ChatRemovalUnavailable();
  }
  await query({'@type': 'leaveChat', 'chat_id': chatId});
  onLeft();

  // Leaving a supergroup/channel removes membership and its chat-list entry.
  // deleteChatHistory(revoke: false) is not supported for a left supergroup.
  if (type == 'chatTypeBasicGroup') {
    try {
      await clearChatHistoryForSelf(
        chatId: chatId,
        query: query,
        removeFromChatList: true,
      );
    } catch (error) {
      throw ChatLeaveHistoryCleanupFailed(error);
    }
  }
}
