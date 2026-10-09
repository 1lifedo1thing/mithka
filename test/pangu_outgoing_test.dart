import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/chat_view_model.dart';
import 'package:mithka/chat/outgoing_attachment.dart';
import 'package:mithka/tdlib/td_client.dart';
import 'package:mithka/tdlib/td_models.dart';

/// The text TDLib was asked to store, whether it rides a message body or a
/// media caption.
String outgoingText(Map<String, dynamic> request) {
  final content = (request['input_message_content'] as Map)
      .cast<String, dynamic>();
  final text = (content['text'] ?? content['caption']) as Map;
  return text['text'] as String;
}

List<Map<String, dynamic>> outgoingEntities(Map<String, dynamic> request) {
  final content = (request['input_message_content'] as Map)
      .cast<String, dynamic>();
  final text = (content['text'] ?? content['caption']) as Map;
  return (text['entities'] as List? ?? const [])
      .cast<Map>()
      .map((entity) => entity.cast<String, dynamic>())
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Map<String, dynamic>> requests;

  setUpAll(() {
    // In-memory transport only: these tests never touch a Telegram account.
    TdClient.shared.configureProxy(
      TdClientProxyTransport(
        accountSlot: 0,
        query: (request) async {
          requests.add(request);
          if (request['@type'] == 'sendMessage' ||
              request['@type'] == 'sendMessageAlbum') {
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
  setUp(() => requests = []);

  ChatViewModel model({bool send = false, bool edit = false}) {
    final vm = ChatViewModel(chatId: 42, title: 'Pangu', markReadOnOpen: false)
      ..panguOnSend = send
      ..panguOnEdit = edit;
    addTearDown(vm.dispose);
    return vm;
  }

  Map<String, dynamic> sent([String type = 'sendMessage']) =>
      requests.where((request) => request['@type'] == type).single;

  test('a draft keeps its own spacing while the switch is off', () async {
    final vm = model()..setDraft('中文English');
    expect(await vm.send(), isTrue);
    expect(outgoingText(sent()), '中文English');
  });

  test('a spaced draft goes out with one space per boundary', () async {
    final vm = model(send: true)..setDraft('中文English中文100');
    expect(await vm.send(), isTrue);
    expect(outgoingText(sent()), '中文 English 中文 100');
  });

  test('formatted text moves its entities onto the spaced text', () async {
    final vm = model(send: true);
    final ok = await vm.sendFormatted('中文code中文', [
      {
        '@type': 'textEntity',
        'offset': 2,
        'length': 4,
        'type': {'@type': 'textEntityTypeCode'},
      },
    ]);
    expect(ok, isTrue);
    final request = sent();
    final text = outgoingText(request);
    expect(text, '中文 code 中文');
    final entities = outgoingEntities(request);
    expect(entities, hasLength(1));
    final offset = entities.single['offset'] as int;
    final length = entities.single['length'] as int;
    expect(offset, 3);
    expect(length, 4);
    expect(text.substring(offset, offset + length), 'code');
  });

  test('a formatting entity grows over an insertion inside it', () async {
    final vm = model(send: true);
    final ok = await vm.sendFormatted('中文English中文', [
      {
        '@type': 'textEntity',
        'offset': 0,
        'length': 9,
        'type': {'@type': 'textEntityTypeBold'},
      },
    ]);
    expect(ok, isTrue);
    final request = sent();
    final text = outgoingText(request);
    expect(text, '中文 English 中文');
    final entities = outgoingEntities(request);
    final offset = entities.single['offset'] as int;
    final length = entities.single['length'] as int;
    expect(offset, 0);
    expect(length, 10);
    expect(text.substring(offset, offset + length), '中文 English');
  });

  test('a media caption is spaced like a body', () async {
    final vm = model(send: true);
    await vm.sendAttachments(const [
      OutgoingAttachment(
        path: '/synthetic/a.jpg',
        kind: OutgoingAttachmentKind.photo,
      ),
    ], caption: '中文photo');
    expect(outgoingText(sent()), '中文 photo');
  });

  test('editing spaces only when the edit switch is on', () async {
    final message = ChatMessage(
      id: 7,
      isOutgoing: true,
      date: 1,
      contentType: 'messageText',
      text: '中文English',
    );

    final sendOnly = model(send: true)..beginMessageEdit(message);
    expect(await sendOnly.submitMessageEdit('中文English'), isTrue);
    expect(outgoingText(sent('editMessageText')), '中文English');

    requests.clear();
    final both = model(send: true, edit: true)..beginMessageEdit(message);
    expect(await both.submitMessageEdit('中文English'), isTrue);
    expect(outgoingText(sent('editMessageText')), '中文 English');
  });

  test('editing a caption spaces the caption payload', () async {
    final message = ChatMessage(
      id: 8,
      isOutgoing: true,
      date: 1,
      contentType: 'messagePhoto',
      text: '中文photo',
      image: TdFileRef(id: 3),
    );
    final vm = model(edit: true)..beginMessageEdit(message);
    expect(await vm.submitMessageEdit('中文photo'), isTrue);
    final request = sent('editMessageCaption');
    final caption = (request['caption'] as Map).cast<String, dynamic>();
    expect(caption['text'], '中文 photo');
  });

  test('a dice emoji is still sent as a dice', () async {
    final vm = model(send: true);
    expect(await vm.sendFormatted('🎲', const []), isTrue);
    final request = sent();
    final content = (request['input_message_content'] as Map)
        .cast<String, dynamic>();
    expect(content['@type'], 'inputMessageDice');
  });
  test('plain CJK text is left alone', () async {
    final vm = model(send: true)..setDraft('今天天气不错');
    expect(await vm.send(), isTrue);
    expect(outgoingText(sent()), '今天天气不错');
  });
}
