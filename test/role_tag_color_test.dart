import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/components/ui_components.dart';
import 'package:mithka/tdlib/td_models.dart';

void main() {
  testWidgets('plain member title tag uses the muted slate tint', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RoleTag(role: MemberRole.member, title: 'Helper'),
        ),
      ),
    );

    final container = tester.widget<Container>(
      find.descendant(
        of: find.byType(RoleTag),
        matching: find.byType(Container),
      ),
    );
    final decoration = container.decoration! as BoxDecoration;

    // Titled plain members are not staff: the tag must read as a neutral
    // caption, not the saturated purple used for accents.
    expect(decoration.color, const Color(0xFF8A93A0));
  });
}
