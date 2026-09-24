import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/chat/message_text_quote.dart';
import 'package:mithka/tdlib/td_models.dart';

ChatMessage _message(
  String text, {
  List<MessageTextEntity> entities = const [],
}) => ChatMessage(
  id: 7,
  isOutgoing: false,
  date: 1,
  text: text,
  textEntities: entities,
  contentType: 'messageText',
);

void main() {
  test(
    'quotes the selected occurrence, preserving UTF-16 position and spaces',
    () {
      final message = _message('😀 same same ');
      final quote = quoteMessageRange(message, start: 8, end: 13)!;
      expect(quote.text, 'same ');
      expect(quote.position, 8);
      expect(quote.toInputJson(), {
        '@type': 'inputTextQuote',
        'text': {
          '@type': 'formattedText',
          'text': 'same ',
          'entities': <Object>[],
        },
        'position': 8,
      });
    },
  );

  test('clips supported formatting and excludes links and code', () {
    final message = _message(
      'prefix selected suffix',
      entities: const [
        MessageTextEntity(offset: 2, length: 9, type: 'textEntityTypeBold'),
        MessageTextEntity(offset: 10, length: 9, type: 'textEntityTypeItalic'),
        MessageTextEntity(offset: 7, length: 8, type: 'textEntityTypeSpoiler'),
        MessageTextEntity(offset: 7, length: 8, type: 'textEntityTypeTextUrl'),
        MessageTextEntity(offset: 7, length: 8, type: 'textEntityTypeCode'),
      ],
    );
    final quote = quoteMessageRange(message, start: 7, end: 15)!;
    expect(quote.text, 'selected');
    expect(quote.entities.map((e) => (e.offset, e.length, e.type)), [
      (0, 4, 'textEntityTypeBold'),
      (3, 5, 'textEntityTypeItalic'),
      (0, 8, 'textEntityTypeSpoiler'),
    ]);
  });

  test('rejects invalid ranges, surrogate splits and over-limit quotes', () {
    final message = _message('a😀b');
    for (final range in [(-1, 1), (0, 5), (1, 1), (3, 1), (1, 2), (2, 3)]) {
      expect(
        quoteMessageRange(message, start: range.$1, end: range.$2),
        isNull,
      );
    }
    expect(quoteMessageRange(message, start: 1, end: 3)!.text, '😀');
    expect(quoteMessageRange(message, start: 0, end: 4, maxLength: 3), isNull);
    expect(
      quoteMessageRange(message, start: 0, end: 4, maxLength: 4),
      isNotNull,
    );
  });

  test('retains whole custom emoji but rejects a partial custom emoji', () {
    final message = _message(
      'a❤️b',
      entities: const [
        MessageTextEntity(
          offset: 1,
          length: 2,
          type: 'textEntityTypeCustomEmoji',
          customEmojiId: 123,
        ),
      ],
    );
    expect(quoteMessageRange(message, start: 1, end: 2), isNull);
    final entity = quoteMessageRange(
      message,
      start: 1,
      end: 3,
    )!.entities.single;
    expect(entity.offset, 0);
    expect(entity.length, 2);
    expect(entity.toTdJson()['type'], {
      '@type': 'textEntityTypeCustomEmoji',
      'custom_emoji_id': '123',
    });
  });

  test('supports media captions, not synthetic media or service labels', () {
    for (final type in [
      'messagePhoto',
      'messageVideo',
      'messageAnimation',
      'messageAudio',
      'messageDocument',
    ]) {
      final message = TDParse.message({
        'id': 7,
        'date': 1,
        'content': {
          '@type': type,
          'caption': {'@type': 'formattedText', 'text': 'a caption'},
        },
      })!;
      expect(quoteMessageRange(message, start: 2, end: 9)!.text, 'caption');
    }
    expect(canQuoteMessageText(_message('')), isFalse);
    expect(
      canQuoteMessageText(
        ChatMessage(
          id: 7,
          isOutgoing: false,
          date: 1,
          text: 'Photo',
          contentType: 'messageSticker',
        ),
      ),
      isFalse,
    );
    expect(
      canQuoteMessageText(
        ChatMessage(
          id: -1,
          isOutgoing: true,
          date: 1,
          text: 'pending',
          contentType: 'messageText',
        ),
      ),
      isFalse,
    );
  });

  test(
    'quotes original source even when markdown table rendering extracts it',
    () {
      const source =
          'before\n\n| A | B |\n| --- | --- |\n| one | two |\n\nafter';
      final message = TDParse.message({
        'id': 7,
        'date': 1,
        'content': {
          '@type': 'messageText',
          'text': {'@type': 'formattedText', 'text': source},
        },
      })!;
      expect(message.quoteSourceText, source);
      final start = source.indexOf('two');
      expect(
        quoteMessageRange(message, start: start, end: start + 3)!.text,
        'two',
      );
    },
  );

  test(
    'incoming quote remains authoritative after original-message hydration',
    () {
      final message = TDParse.message({
        'id': 42,
        'date': 2,
        'reply_to': {
          '@type': 'messageReplyToMessage',
          'message_id': 7,
          'quote': {
            '@type': 'textQuote',
            'text': {
              '@type': 'formattedText',
              'text': 'selected',
              'entities': [
                {
                  '@type': 'textEntity',
                  'offset': 0,
                  'length': 8,
                  'type': {'@type': 'textEntityTypeBold'},
                },
              ],
            },
            'position': 7,
            'is_manual': true,
          },
        },
        'content': {
          '@type': 'messageText',
          'text': {'text': 'reply'},
        },
      })!;
      expect(message.replyToMessageId, 7);
      expect(message.replyPreviewText, 'selected');
      expect(message.replyToQuote!.position, 7);
      expect(message.replyToQuote!.isManual, isTrue);
      message.replyToPreview = 'prefix selected suffix';
      message.replyToEntities = const [];
      expect(message.replyPreviewText, 'selected');
      expect(message.replyPreviewEntities.single.type, 'textEntityTypeBold');
    },
  );
}
