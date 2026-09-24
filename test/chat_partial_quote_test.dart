import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/chat/message_text_quote.dart';
import 'package:mithka/chat/outgoing_attachment.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Map<String, dynamic>> requests;
  late bool failSend;
  late Object? limit;

  setUpAll(() {
    // In-memory transport only: these tests never access a Telegram account.
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(request);
          if (request['@type'] == 'getOption') {
            return {'@type': 'optionValueInteger', 'value': limit};
          }
          if (request['@type'] == 'sendMessage' ||
              request['@type'] == 'sendMessageAlbum') {
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
    limit = '1024';
  });

  final source = ChatMessage(
    id: 7,
    isOutgoing: false,
    date: 1,
    text: 'before selected after',
    contentType: 'messageText',
  );
  final quote = quoteMessageRange(source, start: 7, end: 15)!;
  ChatViewModel model() {
    final vm = ChatViewModel(chatId: 42, title: 'Quote', markReadOnOpen: false);
    addTearDown(vm.dispose);
    vm.setReply(source, quote: quote);
    return vm;
  }

  for (final kind in ['text', 'formatted', 'dice', 'attachment', 'album']) {
    test('$kind sends the partial quote in the shared reply payload', () async {
      final vm = model()..setDraft(kind == 'dice' ? '🎲' : 'reply');
      switch (kind) {
        case 'text':
          expect(await vm.send(), isTrue);
        case 'formatted':
        case 'dice':
          expect(await vm.sendFormatted(vm.draft, const []), isTrue);
        case 'attachment':
        case 'album':
          await vm.sendAttachments([
            const OutgoingAttachment(
              path: '/synthetic/a.jpg',
              kind: OutgoingAttachmentKind.photo,
            ),
            if (kind == 'album')
              const OutgoingAttachment(
                path: '/synthetic/b.jpg',
                kind: OutgoingAttachmentKind.photo,
              ),
          ]);
      }
      final sent = requests
          .where(
            (r) =>
                r['@type'] == 'sendMessage' || r['@type'] == 'sendMessageAlbum',
          )
          .single;
      expect(sent['reply_to'], {
        '@type': 'inputMessageReplyToMessage',
        'message_id': 7,
        'quote': quote.toInputJson(),
      });
      expect(vm.replyTo, isNull);
      expect(vm.replyQuote, isNull);
      expect(vm.replyToInput, isNull);
    });
  }

  test(
    'failed text send retains the selected quote and draft for retry',
    () async {
      final vm = model()..setDraft('retry me');
      failSend = true;
      expect(await vm.sendFormatted(vm.draft, const []), isFalse);
      expect(vm.replyQuote, same(quote));
      expect(vm.replyTo, same(source));
      expect(vm.draft, 'retry me');
      failSend = false;
      expect(await vm.sendFormatted(vm.draft, const []), isTrue);
      expect(vm.replyQuote, isNull);
    },
  );

  test('cancel, normal reply and message editing do not leak stale quotes', () {
    final vm = model()..setDraft('draft');
    vm.beginMessageEdit(
      ChatMessage(
        id: 8,
        isOutgoing: true,
        date: 1,
        text: 'edit',
        contentType: 'messageText',
      ),
    );
    expect(vm.replyQuote, isNull);
    vm.cancelMessageEdit();
    expect(vm.draft, 'draft');
    expect(vm.replyQuote, same(quote));
    vm.setReply(source);
    expect(vm.replyQuote, isNull);
    expect(vm.replyToInput!.containsKey('quote'), isFalse);
    vm.setReply(source, quote: quote);
    vm.setReply(null);
    expect(vm.replyQuote, isNull);
    expect(vm.replyToInput, isNull);
  });

  test('secret and protected chats do not offer quoting', () {
    final vm = model();
    expect(vm.canQuoteText, isTrue);
    vm.hasProtectedContent = true;
    expect(vm.canQuoteText, isFalse);
    vm.hasProtectedContent = false;
    vm.isSecretChat = true;
    expect(vm.canQuoteText, isFalse);
    expect(vm.replyToInput!.containsKey('quote'), isFalse);
    vm.setReply(source, quote: quote);
    expect(vm.replyQuote, isNull);
    vm.isSecretChat = false;
    vm.canSendMessages = false;
    expect(vm.canQuoteText, isFalse);
  });

  test('uses the server quote limit with a bounded fallback', () async {
    final vm = model();
    limit = '64';
    expect(await vm.messageQuoteLengthLimit(), 64);
    expect(requests.last['name'], 'message_reply_quote_length_max');
    limit = null;
    expect(await vm.messageQuoteLengthLimit(), defaultMessageQuoteLengthLimit);
  });
}
