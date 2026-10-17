final RegExp _usernameLink = RegExp(
  r'(?:https?://)?(?:t\.me|telegram\.me)/(@?[A-Za-z0-9_]+)',
  caseSensitive: false,
);
final RegExp _publicUsername = RegExp(r'^[A-Za-z0-9_]{3,32}$');

/// Whether [value] has the shape of a public Telegram username (no `@`).
bool isPublicTelegramUsername(String value) => _publicUsername.hasMatch(value);

/// The username a search query names — `@name`, `name`, or a `t.me/name`
/// link — or null when it does not name one.
String? telegramUsernameFromQuery(String query) {
  var value = query.trim();
  final link = _usernameLink.firstMatch(value);
  if (link != null) value = link.group(1)!;
  if (value.startsWith('@')) value = value.substring(1);
  return isPublicTelegramUsername(value) ? value : null;
}

final RegExp _userIdPrefix = RegExp(
  r'^(?:user(?:_?id)?|uid|id)\s*[:=#]?\s*(\d+)$',
  caseSensitive: false,
);
final RegExp _digitsOnly = RegExp(r'^\d+$');

/// Extracts a positive Telegram user ID from a numeric query, an `id:`/`uid:`
/// prefix, or a `tg://user?id=...` / `tg://openmessage?user_id=...` link.
///
/// Queries beginning with `+` (such as E.164 phone numbers) or evaluating to
/// non-positive integers return null.
int? telegramUserIdFromQuery(String query) {
  final value = query.trim();
  if (value.isEmpty || value.startsWith('+')) return null;

  int? validUserId(String? raw) {
    if (raw == null || !_digitsOnly.hasMatch(raw)) return null;
    final parsed = int.tryParse(raw);
    return parsed != null && parsed > 0 ? parsed : null;
  }

  final direct = validUserId(value);
  if (direct != null) return direct;

  final prefixed = _userIdPrefix.firstMatch(value);
  if (prefixed != null) return validUserId(prefixed.group(1));

  final link = normalizeTelegramLink(value);
  if (link == null) return null;
  final uri = Uri.tryParse(link);
  if (uri == null || uri.scheme.toLowerCase() != 'tg') return null;
  final host = uri.host.toLowerCase();
  try {
    if (host == 'user') {
      return validUserId(uri.queryParameters['id']);
    }
    if (host == 'openmessage') {
      return validUserId(
        uri.queryParameters['user_id'] ?? uri.queryParameters['id'],
      );
    }
  } on FormatException {
    // Uri.tryParse accepts escaped bytes whose UTF-8 decoding can still fail
    // when queryParameters is read. Search input must never throw on them.
    return null;
  }
  return null;
}

/// Returns the canonical web form understood by Mithka's Telegram link
/// handler, or null when [raw] is not a Telegram deep link.
String? normalizeTelegramLink(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('tg:')) return trimmed;
  // The app's own schemes carry tg:// grammar too. Keep the normalization in
  // one place so search candidates and tapped message links agree on what is
  // an in-app Telegram destination.
  if (lower.startsWith('mk:')) return 'tg:${trimmed.substring(3)}';
  if (lower.startsWith('mithka:')) return 'tg:${trimmed.substring(7)}';

  var candidate = trimmed;
  if (!candidate.contains('://')) candidate = 'https://$candidate';
  final uri = Uri.tryParse(candidate);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  if (host == 't.me' ||
      host == 'telegram.me' ||
      host == 'telegram.dog' ||
      host == 'www.t.me' ||
      host == 'www.telegram.me' ||
      host == 'www.telegram.dog') {
    return uri.replace(scheme: 'https').toString();
  }
  return null;
}
