import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/channels/topic_post_content.dart';
import 'package:mithka/tdlib/td_models.dart';

Iterable<TextSpan> spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* spans(child);
    }
  }
}

void main() {
  testWidgets('caption entities shift with the trimmed document caption', (
    tester,
  ) async {
    // The caption starts with a leading newline; TopicPostContent trims the
    // caption for the file card, so the entities must shift by 2 as well.
    const text = '\n\nfile.txt hint';
    final message = ChatMessage(
      id: 71,
      isOutgoing: false,
      text: text,
      date: 1,
      contentType: 'messageDocument',
      document: MessageDocument(
        fileName: 'file.txt',
        size: 10,
        ext: 'txt',
        file: null,
      ),
      textEntities: const [
        MessageTextEntity(offset: 2, length: 8, type: 'textEntityTypeBold'),
        MessageTextEntity(offset: 11, length: 4, type: 'textEntityTypeItalic'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopicPostContent(
            chatId: 1,
            message: message,
            text: text,
            textStyle: const TextStyle(fontSize: 15),
          ),
        ),
      ),
    );
    await tester.pump();

    final rich = tester
        .widgetList<RichText>(find.byType(RichText))
        .singleWhere((w) => w.text.toPlainText() == 'file.txt hint');
    final parts = spans(
      rich.text,
    ).where((s) => (s.text ?? '').isNotEmpty).toList();
    // The leading whitespace must not push the entities onto the wrong
    // characters: bold covers the file name, italic only the suffix.
    expect(parts.map((s) => s.text), ['file.txt', ' ', 'hint']);
    expect(parts[0].style?.fontWeight, isNotNull);
    expect(parts[2].style?.fontStyle, FontStyle.italic);
  });

  testWidgets(
    'post text entities keep their positions when the text is untrimmed',
    (tester) async {
      const text = 'file.txt hint';
      final message = ChatMessage(
        id: 72,
        isOutgoing: false,
        text: text,
        date: 1,
        contentType: 'messageDocument',
        document: MessageDocument(
          fileName: 'file.txt',
          size: 10,
          ext: 'txt',
          file: null,
        ),
        textEntities: const [
          MessageTextEntity(offset: 0, length: 8, type: 'textEntityTypeBold'),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TopicPostContent(
              chatId: 1,
              message: message,
              text: text,
              textStyle: const TextStyle(fontSize: 15),
            ),
          ),
        ),
      );
      await tester.pump();

      final rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .singleWhere((w) => w.text.toPlainText() == 'file.txt hint');
      final parts = spans(
        rich.text,
      ).where((s) => (s.text ?? '').isNotEmpty).toList();
      expect(parts.map((s) => s.text), ['file.txt', ' hint']);
      expect(parts[0].style?.fontWeight, isNotNull);
    },
  );
}
