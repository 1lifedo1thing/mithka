import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _chatId = -42;

Map<String, dynamic> _message(int id) => {
  '@type': 'message',
  'id': id,
  'chat_id': _chatId,
  'date': 1700000000 + id,
  'is_outgoing': false,
  'content': {
    '@type': 'messageText',
    'text': {'@type': 'formattedText', 'text': 'Message $id'},
  },
};

Map<String, dynamic> _page(int first, int last) => {
  '@type': 'messages',
  'messages': [for (var id = last; id >= first; id--) _message(id)],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <Map<String, dynamic>>[];
  late Future<Map<String, dynamic>> Function(Map<String, dynamic>) history;

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(request);
          if (request['@type'] == 'getChatHistory') return history(request);
          if (request['@type'] == 'getMessage') {
            return _message(request['message_id'] as int);
          }
          return {'@type': 'ok'};
        },
        send: (_) async {},
        updates: const Stream.empty(),
      ),
    );
  });
  tearDownAll(TdClient.shared.closeProxy);
  setUp(() {
    requests.clear();
    history = (_) async => _page(104, 108);
  });

  ChatViewModel model() {
    final vm = ChatViewModel(
      chatId: _chatId,
      title: 'Paged history',
      markReadOnOpen: false,
      sessionAnchoredHistory: true,
      sessionMessages: [
        for (var id = 100; id <= 104; id++) TDParse.message(_message(id))!,
      ],
    );
    // A newer arrival is buffered while there is a gap after this window.
    vm.applyLiveUpdateForTesting({
      '@type': 'updateNewMessage',
      'message': _message(110),
    });
    addTearDown(vm.dispose);
    return vm;
  }

  test(
    'short newer pages append continuously without replacing history',
    () async {
      final vm = model();
      final revision = vm.historyWindowRevision;
      expect(await vm.loadNewer(), isTrue);
      expect(
        vm.messages.map((m) => m.id),
        orderedEquals(List.generate(9, (i) => 100 + i)),
      );
      expect(vm.historyReachesLatest, isFalse);
      expect(vm.anchoredHistory, isTrue);
      expect(vm.historyWindowRevision, revision);
      final request = requests.firstWhere(
        (r) => r['@type'] == 'getChatHistory',
      );
      expect(request['from_message_id'], 104);
      expect(request['offset'], -30);
      expect(request['limit'], 31);
      expect(request['only_local'], isFalse);

      history = (_) async => _page(108, 110);
      expect(await vm.loadNewer(), isTrue);
      expect(vm.historyReachesLatest, isTrue);
      expect(vm.anchoredHistory, isTrue);
      expect(vm.canLoadNewer, isFalse);
      vm.resumeLatestHistoryIfLoaded();
      expect(vm.anchoredHistory, isFalse);
      expect(
        vm.messages.map((m) => m.id),
        orderedEquals(List.generate(11, (i) => 100 + i)),
      );
      expect(vm.historyWindowRevision, revision);
      expect(requests.where((r) => r['@type'] == 'viewMessages'), isEmpty);
    },
  );

  test('an incomplete window cannot be resumed as latest', () {
    final vm = model();
    vm.resumeLatestHistoryIfLoaded();
    expect(vm.anchoredHistory, isTrue);
    expect(vm.historyReachesLatest, isFalse);
  });

  test(
    'empty, duplicate and failed pages allow retry without claiming latest',
    () async {
      final vm = model();
      for (final page in [_page(1, 0), _page(103, 104)]) {
        history = (_) async => page;
        expect(await vm.loadNewer(), isFalse);
        expect(vm.historyReachesLatest, isFalse);
        expect(vm.canLoadNewer, isTrue);
      }
      history = (_) async => throw StateError('test transport unavailable');
      expect(await vm.loadNewer(), isFalse);
      expect(vm.canLoadNewer, isTrue);
      history = (_) async => _page(104, 108);
      expect(await vm.loadNewer(), isTrue);
    },
  );

  test(
    'live arrivals do not skip the gap or falsely complete an in-flight page',
    () async {
      final vm = model();
      final response = Completer<Map<String, dynamic>>();
      history = (_) => response.future;
      final loading = vm.loadNewer();
      expect(await vm.loadNewer(), isFalse);
      vm.applyLiveUpdateForTesting({
        '@type': 'updateNewMessage',
        'message': _message(111),
      });
      response.complete(_page(104, 110));
      expect(await loading, isTrue);
      expect(vm.historyReachesLatest, isFalse);
      expect(vm.messages.last.id, 110);
      history = (_) async => _page(110, 111);
      expect(await vm.loadNewer(), isTrue);
      expect(vm.historyReachesLatest, isTrue);
      expect(
        vm.messages.map((m) => m.id),
        orderedEquals(List.generate(12, (i) => 100 + i)),
      );
    },
  );

  test('a deleted message is not resurrected by the in-flight page', () async {
    final vm = model();
    final response = Completer<Map<String, dynamic>>();
    history = (_) => response.future;
    final loading = vm.loadNewer();
    vm.applyLiveUpdateForTesting({
      '@type': 'updateDeleteMessages',
      'chat_id': _chatId,
      'message_ids': [106],
      'is_permanent': true,
    });
    response.complete(_page(104, 108));
    expect(await loading, isTrue);
    expect(vm.messages.map((m) => m.id), isNot(contains(106)));
  });

  for (final replacement in ['latest', 'target', 'clear']) {
    test('late newer page cannot overwrite $replacement navigation', () async {
      final vm = model();
      final response = Completer<Map<String, dynamic>>();
      history = (_) => response.future;
      final loading = vm.loadNewer();
      history = (_) async => _page(109, 110);
      if (replacement == 'latest') {
        expect(await vm.loadLatestHistory(), isTrue);
      } else if (replacement == 'target') {
        expect(await vm.loadAroundMessage(109), isTrue);
      } else {
        vm.applyLiveUpdateForTesting({
          '@type': 'mithkaChatHistoryCleared',
          'chat_id': _chatId,
        });
      }
      final ids = vm.messages.map((m) => m.id).toList();
      response.complete(_page(104, 108));
      expect(await loading, isFalse);
      expect(vm.messages.map((m) => m.id), orderedEquals(ids));
    });
  }
}
