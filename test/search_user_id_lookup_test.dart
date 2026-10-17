import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/app/chat_deep_link_controller.dart';
import 'package:mithka/chat/chat_members_view.dart';
import 'package:mithka/chat/chat_message_search_bar.dart';
import 'package:mithka/chat/chat_message_search_controller.dart';
import 'package:mithka/chat/chat_picker_view.dart';
import 'package:mithka/chat/telegram_link.dart';
import 'package:mithka/chats/search_view.dart';
import 'package:mithka/components/keyboard_dismiss_on_tap.dart';
import 'package:mithka/contacts/add_people_view.dart';
import 'package:mithka/contacts/contacts_view.dart';
import 'package:mithka/l10n/app_localizations.dart';
import 'package:mithka/profile/profile_detail_view.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:mithka/theme/app_theme.dart';
import 'package:mithka/theme/theme_controller.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _targetUserId = 777000;
const _targetPrivateChatId = 777000;
const _groupChatId = -100200;
const _supergroupId = 200;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StreamController<Map<String, dynamic>> updates;
  late List<Map<String, dynamic>> requests;
  late Future<Map<String, dynamic>> Function(Map<String, dynamic>) handler;
  late SharedPreferences prefs;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
    updates = StreamController<Map<String, dynamic>>.broadcast();
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) {
          requests.add(Map<String, dynamic>.from(request));
          return handler(request);
        },
        send: (_) async {},
        updates: updates.stream,
      ),
    );
  });

  setUp(() {
    requests = [];
    handler = _defaultResponse;
    ChatDeepLinkController.shared.consumePending();
  });

  tearDownAll(() async {
    await TdClient.shared.closeProxy();
    await updates.close();
  });

  group('telegramUserIdFromQuery', () {
    test('parses positive user IDs, prefixed forms, and tg user links', () {
      expect(telegramUserIdFromQuery('777000'), 777000);
      expect(telegramUserIdFromQuery('  1234567890123  '), 1234567890123);
      expect(telegramUserIdFromQuery('id:777000'), 777000);
      expect(telegramUserIdFromQuery('ID: 777000'), 777000);
      expect(telegramUserIdFromQuery('uid=777000'), 777000);
      expect(telegramUserIdFromQuery('user_id:777000'), 777000);
      expect(telegramUserIdFromQuery('id#777000'), 777000);
      expect(telegramUserIdFromQuery('tg://user?id=777000'), 777000);
      expect(telegramUserIdFromQuery('mk://user?id=777000'), 777000);
      expect(
        telegramUserIdFromQuery('tg://openmessage?user_id=777000'),
        777000,
      );
    });

    test('rejects non-positive IDs, phone numbers, and chat links', () {
      expect(telegramUserIdFromQuery(''), isNull);
      expect(telegramUserIdFromQuery('0'), isNull);
      expect(telegramUserIdFromQuery('000'), isNull);
      expect(telegramUserIdFromQuery('-100123456'), isNull);
      expect(telegramUserIdFromQuery('+8613800138000'), isNull);
      expect(telegramUserIdFromQuery('@username'), isNull);
      expect(telegramUserIdFromQuery('https://t.me/durov'), isNull);
    });

    test(
      'review: malformed percent-encoded user links are rejected safely',
      () {
        for (final input in [
          'tg://user?id=%FF',
          'tg://user?id=%C3%28',
          'tg://openmessage?user_id=%FF',
          'mk://user?id=%FF',
          'mithka://user?id=%FF',
        ]) {
          expect(telegramUserIdFromQuery(input), isNull, reason: input);
        }
      },
    );
  });

  testWidgets('review: disposed AddPeople lookup issues no numeric follow-up', (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    handler = (request) {
      if (request['@type'] == 'searchContacts') return gate.future;
      return _defaultResponse(request);
    };
    await tester.pumpWidget(_appHarness(prefs, const AddPeopleView()));
    await tester.enterText(find.byType(TextField), 'id:$_targetUserId');
    await tester.pump(const Duration(milliseconds: 450));
    expect(requests.where((r) => r['@type'] == 'searchContacts'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete({'@type': 'users', 'user_ids': <int>[]});
    await tester.pump();
    expect(
      requests.where(
        (r) => r['@type'] == 'getUser' && r['user_id'] == _targetUserId,
      ),
      isEmpty,
    );
  });

  testWidgets('cleared AddPeople query cancels a pending numeric follow-up', (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    handler = (request) {
      if (request['@type'] == 'searchContacts') return gate.future;
      return _defaultResponse(request);
    };
    await tester.pumpWidget(_appHarness(prefs, const AddPeopleView()));
    await tester.enterText(find.byType(TextField), 'id:$_targetUserId');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.enterText(find.byType(TextField), '');
    gate.complete({'@type': 'users', 'user_ids': <int>[]});
    await tester.pump();
    expect(requests.where((r) => r['@type'] == 'getUser'), isEmpty);
    expect(find.text('Lookup Alice'), findsNothing);
  });

  testWidgets('ContactsView ignores a cleared query pending user response', (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    handler = (request) {
      if (request['@type'] == 'getUser' &&
          request['user_id'] == _targetUserId) {
        return gate.future;
      }
      return _defaultResponse(request);
    };
    await tester.pumpWidget(
      _appHarness(prefs, const Scaffold(body: ContactsView())),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'id:$_targetUserId');
    await tester.pump(const Duration(milliseconds: 250));
    expect(requests.where((r) => r['@type'] == 'getUser'), hasLength(1));
    await tester.enterText(find.byType(TextField), '');
    gate.complete(
      await _defaultResponse({'@type': 'getUser', 'user_id': _targetUserId}),
    );
    await tester.pump();
    expect(find.text('Lookup Alice'), findsNothing);
  });

  testWidgets('SearchView drops a numeric lookup after the view closes', (
    tester,
  ) async {
    final gate = Completer<Map<String, dynamic>>();
    handler = (request) {
      if (request['@type'] == 'getUser' &&
          request['user_id'] == _targetUserId) {
        return gate.future;
      }
      return _defaultResponse(request);
    };
    await tester.pumpWidget(_appHarness(prefs, const SearchView()));
    await tester.enterText(
      find.byType(CupertinoTextField),
      'id:$_targetUserId',
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(requests.where((r) => r['@type'] == 'getUser'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    gate.complete(
      await _defaultResponse({'@type': 'getUser', 'user_id': _targetUserId}),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(requests.where((r) => r['@type'] == 'createPrivateChat'), isEmpty);
    expect(ChatDeepLinkController.shared.consumePending(), isNull);
  });

  for (final status in [
    {'@type': 'chatMemberStatusLeft'},
    {'@type': 'chatMemberStatusBanned'},
    {'@type': 'chatMemberStatusRestricted', 'is_member': false},
  ]) {
    testWidgets('numeric member lookup excludes ${status['@type']}', (
      tester,
    ) async {
      handler = (request) async {
        if (request['@type'] == 'getChatMember' &&
            (request['member_id'] as Map?)?['user_id'] == _targetUserId) {
          return {
            '@type': 'chatMember',
            'member_id': {
              '@type': 'messageSenderUser',
              'user_id': _targetUserId,
            },
            'status': status,
          };
        }
        return _defaultResponse(request);
      };
      await tester.pumpWidget(
        _appHarness(
          prefs,
          const ChatMembersView(chatId: _groupChatId, title: 'Group'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'id:$_targetUserId');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Lookup Alice'), findsNothing);
      expect(
        requests.where(
          (r) => r['@type'] == 'getUser' && r['user_id'] == _targetUserId,
        ),
        isEmpty,
      );
    });
  }

  testWidgets(
    'SearchView resolves a user ID via getUser and opens their private chat',
    (tester) async {
      final deepLinks = _DeepLinkHost();
      addTearDown(deepLinks.dispose);

      await tester.pumpWidget(_appHarness(prefs, const SearchView()));
      await tester.pump();

      await tester.enterText(find.byType(CupertinoTextField), '$_targetUserId');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(
        requests.where(
          (r) => r['@type'] == 'getUser' && r['user_id'] == _targetUserId,
        ),
        isNotEmpty,
      );
      expect(find.text('Lookup Alice'), findsOneWidget);
      expect(find.text('@alice_lookup · ID: $_targetUserId'), findsOneWidget);

      await tester.tap(find.text('Lookup Alice'));
      await tester.pumpAndSettle();

      expect(
        requests.where(
          (r) =>
              r['@type'] == 'createPrivateChat' &&
              r['user_id'] == _targetUserId,
        ),
        hasLength(1),
      );
      final pending = ChatDeepLinkController.shared.consumePending();
      expect(pending?.chatId, _targetPrivateChatId);
      expect(pending?.title, 'Lookup Alice');
    },
  );

  testWidgets(
    'DesktopInlineSearch resolves a user ID in Chats section and opens chat on tap',
    (tester) async {
      final controller = DesktopInlineSearchController(
        miniAppSearch: (_) async => const [],
      );
      addTearDown(controller.dispose);
      final deepLinks = _DeepLinkHost();
      addTearDown(deepLinks.dispose);

      await tester.pumpWidget(_desktopSearchHarness(controller));

      await tester.enterText(
        find.byKey(const ValueKey('desktop-title-bar-search-input')),
        'id:$_targetUserId',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('desktop-inline-search-section-chats')),
        findsOneWidget,
      );
      expect(find.text('Lookup Alice', findRichText: true), findsOneWidget);
      expect(
        find.text('@alice_lookup · ID: $_targetUserId', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(find.text('Lookup Alice', findRichText: true));
      await tester.pumpAndSettle();

      expect(
        requests.where(
          (r) =>
              r['@type'] == 'createPrivateChat' &&
              r['user_id'] == _targetUserId,
        ),
        hasLength(1),
      );
    },
  );

  testWidgets('SearchView skips deleted users when looking up by user ID', (
    tester,
  ) async {
    handler = (request) async {
      if (request['@type'] == 'getUser' &&
          request['user_id'] == _targetUserId) {
        return {
          '@type': 'user',
          'id': _targetUserId,
          'first_name': '',
          'last_name': '',
          'type': {'@type': 'userTypeDeleted'},
        };
      }
      return _defaultResponse(request);
    };

    await tester.pumpWidget(_appHarness(prefs, const SearchView()));
    await tester.pump();

    await tester.enterText(find.byType(CupertinoTextField), '$_targetUserId');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(find.textContaining('ID: $_targetUserId'), findsNothing);
  });

  testWidgets(
    'AddPeopleView resolves a user ID and opens ProfileDetailView on tap',
    (tester) async {
      await tester.pumpWidget(_appHarness(prefs, const AddPeopleView()));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '$_targetUserId');
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();

      expect(
        requests.where(
          (r) => r['@type'] == 'getUser' && r['user_id'] == _targetUserId,
        ),
        isNotEmpty,
      );
      expect(find.text('Lookup Alice'), findsOneWidget);
      expect(find.text('@alice_lookup'), findsOneWidget);

      await tester.tap(find.text('Lookup Alice'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byType(ProfileDetailView), findsOneWidget);
    },
  );

  testWidgets(
    'ContactsView matches existing contacts by ID and resolves unindexed user IDs via getUser',
    (tester) async {
      final contact = Contact(
        id: 123456,
        name: 'Saved Friend',
        username: 'saved_friend',
        usernames: const ['saved_friend'],
        statusText: 'online',
      );
      expect(contactMatchesQuery(contact, '123456'), isTrue);
      expect(contactMatchesQuery(contact, 'id:123456'), isTrue);
      expect(contactMatchesQuery(contact, '999999'), isFalse);

      Widget? openedDetail;
      await tester.pumpWidget(
        _appHarness(
          prefs,
          Scaffold(
            body: ContactsView(onOpenDetail: (detail) => openedDetail = detail),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(find.byType(TextField), '$_targetUserId');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();

      expect(
        requests.where(
          (r) => r['@type'] == 'getUser' && r['user_id'] == _targetUserId,
        ),
        isNotEmpty,
      );
      expect(find.text('Lookup Alice'), findsOneWidget);

      await tester.tap(find.text('Lookup Alice'));
      await tester.pump();
      expect(openedDetail, isA<ProfileDetailView>());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
    },
  );

  testWidgets(
    'from:<user_id> token suggests the user by ID and filters in-chat messages by sender_id',
    (tester) async {
      final controller = ChatMessageSearchController(chatId: _groupChatId);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_inChatSearchHarness(controller));
      controller.open();
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'from:$_targetUserId');
      await tester.pump(const Duration(milliseconds: 290));
      await tester.pumpAndSettle();

      final suggestionRow = find.byKey(
        const ValueKey('searchTokenSuggestion-$_targetUserId'),
      );
      expect(suggestionRow, findsOneWidget);
      expect(
        find.descendant(of: suggestionRow, matching: find.text('Lookup Alice')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: suggestionRow,
          matching: find.text('@alice_lookup · ID: $_targetUserId'),
        ),
        findsOneWidget,
      );

      final search = requests.lastWhere(
        (r) => r['@type'] == 'searchChatMessages',
      );
      expect(search['chat_id'], _groupChatId);
      expect(search['sender_id'], {
        '@type': 'messageSenderUser',
        'user_id': _targetUserId,
      });
    },
  );

  testWidgets(
    'ChatMembersView resolves a supergroup member by user ID when searchChatMembers misses',
    (tester) async {
      await tester.pumpWidget(
        _appHarness(
          prefs,
          const ChatMembersView(chatId: _groupChatId, title: 'Group'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '$_targetUserId');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      expect(
        requests.where(
          (r) =>
              r['@type'] == 'getChatMember' &&
              r['chat_id'] == _groupChatId &&
              (r['member_id'] as Map<String, dynamic>?)?['user_id'] ==
                  _targetUserId,
        ),
        isNotEmpty,
      );
      expect(find.text('Lookup Alice'), findsOneWidget);
    },
  );

  testWidgets('ChatPickerView matches contacts and private chats by user ID', (
    tester,
  ) async {
    handler = (request) async {
      if (request['@type'] == 'getContacts') {
        return {
          '@type': 'users',
          'user_ids': [_targetUserId],
        };
      }
      return _defaultResponse(request);
    };

    await tester.pumpWidget(
      _appHarness(prefs, const ChatPickerView(title: 'Pick')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Lookup Alice'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '$_targetUserId');
    await tester.pump();
    expect(find.text('Lookup Alice'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '999999');
    await tester.pump();
    expect(find.text('Lookup Alice'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });
}

Widget _appHarness(SharedPreferences prefs, Widget home) =>
    ChangeNotifierProvider<ThemeController>(
      create: (_) => ThemeController(prefs),
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: [AppColors.light]),
        home: home,
      ),
    );

Widget _desktopSearchHarness(DesktopInlineSearchController controller) =>
    MaterialApp(
      builder: (context, child) =>
          AppKeyboardDismissOnTap(child: child ?? const SizedBox.shrink()),
      theme: ThemeData(extensions: [AppColors.light]),
      home: Scaffold(
        body: Column(
          children: [
            DesktopInlineSearchField(
              controller: controller,
              onSearchAll: (_) {},
            ),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: DesktopInlineSearchPanel(
                  controller: controller,
                  onSearchAll: (_) {},
                ),
              ),
            ),
          ],
        ),
      ),
    );

Widget _inChatSearchHarness(ChatMessageSearchController controller) =>
    MaterialApp(
      builder: (context, child) =>
          AppKeyboardDismissOnTap(child: child ?? const SizedBox.shrink()),
      locale: const Locale('en'),
      localizationsDelegates: const [AppLocalizations.delegate],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(extensions: [AppColors.light]),
      home: Scaffold(
        body: Column(
          children: [
            ChatSearchHeaderBar(
              controller: controller,
              height: 44,
              onClose: controller.close,
            ),
            Expanded(
              child: ChatSearchResultsPane(
                controller: controller,
                peerTitle: 'Group',
                onSelect: (_) {},
              ),
            ),
          ],
        ),
      ),
    );

class _DeepLinkHost {
  _DeepLinkHost() {
    ChatDeepLinkController.shared.addListener(_noop);
  }

  void _noop() {}

  void dispose() {
    ChatDeepLinkController.shared.removeListener(_noop);
    ChatDeepLinkController.shared.consumePending();
  }
}

Future<Map<String, dynamic>> _defaultResponse(
  Map<String, dynamic> request,
) async {
  switch (request['@type']) {
    case 'getMe':
      return {
        '@type': 'user',
        'id': 1,
        'first_name': 'Self',
        'last_name': '',
        'type': {'@type': 'userTypeRegular'},
      };
    case 'searchChats':
    case 'searchPublicChats':
    case 'getChats':
      return {'@type': 'chats', 'chat_ids': <int>[]};
    case 'loadChats':
      throw TdError(const {'code': 404, 'message': 'Not Found'});
    case 'searchContacts':
    case 'getContacts':
      return {'@type': 'users', 'user_ids': <int>[]};
    case 'searchPublicChat':
      throw TdError(const {'code': 404, 'message': 'Not Found'});
    case 'searchMessages':
    case 'searchChatMessages':
      return {
        '@type': 'foundMessages',
        'total_count': 0,
        'messages': <Map<String, dynamic>>[],
        'next_from_message_id': 0,
      };
    case 'getUser':
      final userId = request['user_id'] as int?;
      if (userId == _targetUserId) {
        return {
          '@type': 'user',
          'id': _targetUserId,
          'first_name': 'Lookup',
          'last_name': 'Alice',
          'usernames': {
            '@type': 'usernames',
            'active_usernames': ['alice_lookup'],
            'disabled_usernames': <String>[],
            'editable_username': 'alice_lookup',
          },
          'status': {'@type': 'userStatusOnline', 'expires': 9999999999},
          'type': {'@type': 'userTypeRegular'},
        };
      }
      throw TdError(const {'code': 400, 'message': 'User not found'});
    case 'getUserFullInfo':
      return {
        '@type': 'userFullInfo',
        'bio': {'@type': 'formattedText', 'text': ''},
        'group_in_common_count': 0,
      };
    case 'createPrivateChat':
      final userId = request['user_id'] as int?;
      if (userId == _targetUserId) {
        return {
          '@type': 'chat',
          'id': _targetPrivateChatId,
          'title': 'Lookup Alice',
          'type': {'@type': 'chatTypePrivate', 'user_id': _targetUserId},
          'positions': <Map<String, dynamic>>[],
          'unread_count': 0,
        };
      }
      throw TdError(const {'code': 400, 'message': 'Chat info not found'});
    case 'getChat':
      final chatId = request['chat_id'] as int?;
      if (chatId == _groupChatId) {
        return {
          '@type': 'chat',
          'id': _groupChatId,
          'title': 'Group',
          'type': {
            '@type': 'chatTypeSupergroup',
            'supergroup_id': _supergroupId,
            'is_channel': false,
          },
          'positions': <Map<String, dynamic>>[],
          'unread_count': 0,
        };
      }
      return {
        '@type': 'chat',
        'id': chatId ?? _targetPrivateChatId,
        'title': 'Lookup Alice',
        'type': {'@type': 'chatTypePrivate', 'user_id': _targetUserId},
        'positions': <Map<String, dynamic>>[],
        'unread_count': 0,
      };
    case 'getSupergroupFullInfo':
      return {'@type': 'supergroupFullInfo', 'member_count': 1};
    case 'getSupergroupMembers':
      return {
        '@type': 'chatMembers',
        'total_count': 1,
        'members': [
          {
            '@type': 'chatMember',
            'member_id': {'@type': 'messageSenderUser', 'user_id': 1},
            'status': {'@type': 'chatMemberStatusCreator', 'is_member': true},
          },
        ],
      };
    case 'searchChatMembers':
      return {
        '@type': 'chatMembers',
        'total_count': 0,
        'members': <Map<String, dynamic>>[],
      };
    case 'getChatMember':
      final memberId = request['member_id'] as Map<String, dynamic>?;
      final userId = memberId?['user_id'] as int?;
      if (userId == _targetUserId) {
        return {
          '@type': 'chatMember',
          'member_id': {'@type': 'messageSenderUser', 'user_id': _targetUserId},
          'status': {'@type': 'chatMemberStatusMember'},
        };
      }
      return {
        '@type': 'chatMember',
        'member_id': {'@type': 'messageSenderUser', 'user_id': userId ?? 1},
        'status': {'@type': 'chatMemberStatusCreator', 'is_member': true},
      };
  }
  return {'@type': 'ok'};
}
