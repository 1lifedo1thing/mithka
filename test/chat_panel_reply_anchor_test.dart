import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/chat/checklist_composer_view.dart';
import 'package:mithka/chat/gif_item.dart';
import 'package:mithka/chat/poll_composer_view.dart';
import 'package:mithka/chat/sticker_item.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Map<String, dynamic>> requests;
  late bool failSend;

  setUpAll(() {
    // In-memory transport only: these tests never access a Telegram account.
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(request);
          if (request['@type'] == 'getOption') {
            return {'@type': 'optionValueBoolean', 'value': false};
          }
          if (request['@type'] == 'sendMessage' ||
              request['@type'] == 'sendInlineQueryResultMessage') {
            if (failSend) throw StateError('synthetic send failure');
            return {'@type': 'message', 'id': 99};
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
    requests = [];
    failSend = false;
  });

  final target = ChatMessage(
    id: 7,
    isOutgoing: false,
    date: 1,
    text: 'reply anchor target',
    contentType: 'messageText',
  );
  const replyAnchor = {'@type': 'inputMessageReplyToMessage', 'message_id': 7};

  ChatViewModel model({bool withReply = true}) {
    final vm = ChatViewModel(chatId: 42, title: 'Panel', markReadOnOpen: false);
    addTearDown(vm.dispose);
    if (withReply) vm.setReply(target);
    return vm;
  }

  Map<String, dynamic> soleRequest() =>
      requests.where((r) => r['@type'] == 'sendMessage').single;

  test(
    'sticker send carries the reply anchor and consumes the reply',
    () async {
      final vm = model();
      final sent = await vm.sendSticker(
        const StickerItem(id: 5, width: 512, height: 512, emoji: '🙂'),
      );
      expect(sent, isTrue);
      expect(soleRequest()['reply_to'], replyAnchor);
      expect(vm.replyTo, isNull);
      expect(vm.replyToInput, isNull);
    },
  );

  test('saved GIF send carries the reply anchor', () async {
    final vm = model();
    final sent = await vm.sendGif(
      GifItem(
        id: 5,
        duration: 1,
        width: 8,
        height: 8,
        mimeType: 'video/mp4',
        file: TdFileRef(id: 5),
      ),
    );
    expect(sent, isTrue);
    expect(soleRequest()['reply_to'], replyAnchor);
    expect(vm.replyTo, isNull);
  });

  test('inline GIF send carries the reply anchor', () async {
    final vm = model();
    final sent = await vm.sendGif(
      GifItem(
        id: 5,
        inlineQueryId: 11,
        inlineResultId: 'RESULT',
        duration: 1,
        width: 8,
        height: 8,
        mimeType: 'video/mp4',
        file: TdFileRef(id: 5),
      ),
    );
    expect(sent, isTrue);
    final request = requests
        .where((r) => r['@type'] == 'sendInlineQueryResultMessage')
        .single;
    expect(request['reply_to'], replyAnchor);
    expect(vm.replyTo, isNull);
  });

  test('voice note send carries the reply anchor', () async {
    final vm = model();
    final sent = await vm.sendVoice('/synthetic/a.ogg', 3);
    expect(sent, isTrue);
    expect(soleRequest()['reply_to'], replyAnchor);
    expect(vm.replyTo, isNull);
  });

  test('video note send carries the reply anchor', () async {
    final vm = model();
    final sent = await vm.sendVideoNote('/synthetic/a.mp4', 3);
    expect(sent, isTrue);
    expect(soleRequest()['reply_to'], replyAnchor);
    expect(vm.replyTo, isNull);
  });

  test('location send carries the reply anchor', () async {
    final vm = model();
    vm.sendLocation(1.5, 2.5);
    await Future<void>.delayed(Duration.zero);
    expect(soleRequest()['reply_to'], replyAnchor);
    expect(vm.replyTo, isNull);
  });

  test('contact send carries the reply anchor', () async {
    final vm = model();
    final sent = await vm.sendContact(
      const MessageContactCard(
        phoneNumber: '+12345678901',
        firstName: 'Ada',
        lastName: '',
        vcard: '',
        userId: 0,
      ),
    );
    expect(sent, isTrue);
    expect(soleRequest()['reply_to'], replyAnchor);
    expect(vm.replyTo, isNull);
  });

  test('checklist send carries the reply anchor', () async {
    final vm = model();
    vm.sendChecklist(
      const ChecklistComposerResult(
        title: 'Tasks',
        tasks: ['first'],
        othersCanAddTasks: false,
        othersCanMarkTasksAsDone: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(soleRequest()['reply_to'], replyAnchor);
    expect(vm.replyTo, isNull);
  });

  test('poll send carries the reply anchor', () async {
    final vm = model();
    final sent = await vm.sendPoll(
      const PollComposerResult(
        question: 'Pick one',
        options: [
          PollOptionDraft(text: 'a'),
          PollOptionDraft(text: 'b'),
        ],
      ),
    );
    expect(sent, isTrue);
    expect(soleRequest()['reply_to'], replyAnchor);
    expect(vm.replyTo, isNull);
  });

  test('panel sends without a pending reply omit the reply field', () async {
    final vm = model(withReply: false);
    expect(
      await vm.sendSticker(
        const StickerItem(id: 5, width: 512, height: 512, emoji: '🙂'),
      ),
      isTrue,
    );
    expect(soleRequest().containsKey('reply_to'), isFalse);
  });

  test('failed panel send retains the reply for retry', () async {
    const sticker = StickerItem(id: 5, width: 512, height: 512, emoji: '🙂');
    final vm = model();
    failSend = true;
    expect(await vm.sendSticker(sticker), isFalse);
    expect(vm.replyTo, same(target));
    expect(vm.replyToInput, replyAnchor);
    failSend = false;
    expect(await vm.sendSticker(sticker), isTrue);
    expect(requests.where((r) => r['@type'] == 'sendMessage'), hasLength(2));
    expect(requests.last['reply_to'], replyAnchor);
    expect(vm.replyTo, isNull);
  });
}
