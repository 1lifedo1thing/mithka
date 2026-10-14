/// Canonical external link for a profile identity value.
///
/// Usernames become their `t.me` link; a numeric Telegram id falls back to the
/// resolvable `tg://user?id=` scheme so users without a username still open
/// something. Returns null when nothing resolvable can be built.
String? profileLinkForIdentity({
  List<String> usernames = const [],
  int userId = 0,
}) {
  if (usernames.isNotEmpty) {
    final username = usernames.first.trim().replaceFirst(RegExp(r'^@+'), '');
    if (username.isNotEmpty) return 'https://t.me/$username';
  }
  if (userId > 0) return 'tg://user?id=$userId';
  return null;
}
