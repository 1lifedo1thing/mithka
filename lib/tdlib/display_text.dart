import 'td_models.dart';

/// Message text prepared for display together with its re-addressed entities.
///
/// Renderers routinely trim the raw message text (leading newlines in channel
/// posts, padded captions, comments). Pairing the shortened string with
/// entities that still address the original shifted every format marker onto
/// the wrong characters — overlapping other entities or falling outside the
/// visible message entirely.
({String text, List<MessageTextEntity> entities}) trimTextForDisplay(
  String text,
  List<MessageTextEntity> entities,
) {
  final trimmed = text.trim();
  if (trimmed == text) {
    return (text: text, entities: entities);
  }
  if (trimmed.isEmpty) {
    return (text: '', entities: const []);
  }
  // The boundaries come from the framework's own trimLeft/trimRight, so the
  // substring always matches `text.trim()` exactly.
  final start = text.length - text.trimLeft().length;
  final end = text.trimRight().length;
  final shifted = <MessageTextEntity>[];
  for (final entity in entities) {
    final entityStart = entity.offset.clamp(start, end).toInt();
    final entityEnd = entity.end.clamp(start, end).toInt();
    if (entityEnd <= entityStart) continue;
    shifted.add(
      MessageTextEntity(
        offset: entityStart - start,
        length: entityEnd - entityStart,
        type: entity.type,
        url: entity.url,
        userId: entity.userId,
        customEmojiId: entity.customEmojiId,
        language: entity.language,
        button: entity.button,
        typeData: entity.typeData,
      ),
    );
  }
  return (text: trimmed, entities: shifted);
}
