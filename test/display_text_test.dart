import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/tdlib/display_text.dart';
import 'package:mithka/tdlib/td_models.dart';

void main() {
  test('keeps entities when nothing is trimmed', () {
    const entities = [
      MessageTextEntity(offset: 3, length: 2, type: 'textEntityTypeBold'),
    ];
    final result = trimTextForDisplay('abc de', entities);
    expect(result.text, 'abc de');
    expect(result.entities, same(entities));
  });

  test('shifts entities to the trimmed text', () {
    final result = trimTextForDisplay('\n\n  bold and italic  \n', const [
      MessageTextEntity(offset: 4, length: 4, type: 'textEntityTypeBold'),
      MessageTextEntity(offset: 13, length: 6, type: 'textEntityTypeItalic'),
    ]);
    expect(result.text, 'bold and italic');
    expect(result.entities.map((e) => (e.offset, e.length, e.type)), [
      (0, 4, 'textEntityTypeBold'),
      (9, 6, 'textEntityTypeItalic'),
    ]);
  });

  test('drops entities that trim away entirely', () {
    final result = trimTextForDisplay('   kept', const [
      MessageTextEntity(offset: 0, length: 2, type: 'textEntityTypeBold'),
      MessageTextEntity(offset: 3, length: 4, type: 'textEntityTypeItalic'),
    ]);
    expect(result.text, 'kept');
    expect(result.entities.map((e) => (e.offset, e.length, e.type)), [
      (0, 4, 'textEntityTypeItalic'),
    ]);
  });

  test('clips an entity straddling the trailing trim boundary', () {
    final result = trimTextForDisplay('word   ', const [
      MessageTextEntity(offset: 2, length: 4, type: 'textEntityTypeBold'),
    ]);
    expect(result.text, 'word');
    expect(result.entities.single.offset, 2);
    expect(result.entities.single.length, 2);
  });

  test('respects UTF-16 boundaries: surrogate pairs never split', () {
    // '😀' is one code point over two code units.
    final result = trimTextForDisplay('  😀 bold', const [
      MessageTextEntity(
        offset: 2,
        length: 2,
        type: 'textEntityTypeCustomEmoji',
      ),
    ]);
    expect(result.text, '😀 bold');
    expect(result.entities.single.offset, 0);
    expect(result.entities.single.length, 2);
    expect(result.entities.single.isCustomEmoji, isTrue);
  });

  test('returns empty text with no entities for whitespace-only input', () {
    final result = trimTextForDisplay('   ', const [
      MessageTextEntity(offset: 0, length: 1, type: 'textEntityTypeBold'),
    ]);
    expect(result.text, '');
    expect(result.entities, isEmpty);
  });
}
