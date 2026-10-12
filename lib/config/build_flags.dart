/// Allows contributions that violate Telegram API Terms of Service §1.4 only
/// in explicitly opted-in, self-built binaries.
///
/// Gate both their UI and every execution path with this compile-time constant.
/// Official builds explicitly set the declaration to false; omitted or invalid
/// values also leave it disabled. Never expose a runtime switch for this gate.
const allowTelegramTosViolations = bool.fromEnvironment(
  'I_DONT_FUCKING_CARE_ABOUT_TOS',
);
