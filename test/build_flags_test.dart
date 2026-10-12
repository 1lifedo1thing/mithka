import 'package:flutter_test/flutter_test.dart';

import 'package:mithka/config/build_flags.dart';

void main() {
  // CI sets this separate expectation only for the explicitly opted-in build.
  const expectedEnabled = bool.fromEnvironment('EXPECT_TOS_VIOLATIONS');

  test('Telegram Section 1.4 exceptions require compile-time opt-in', () {
    expect(allowTelegramTosViolations, expectedEnabled);
  });
}
