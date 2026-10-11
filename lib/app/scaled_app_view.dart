//
//  scaled_app_view.dart
//
//  Applies the interface-size preference to a whole window: the subtree lays
//  out in a virtual viewport of `size / interfaceScale` and is scaled back up,
//  so geometry and text grow together.
//

import 'package:flutter/widgets.dart';

import '../components/keyboard_dismiss_on_tap.dart';

class ScaledAppView extends StatelessWidget {
  const ScaledAppView({
    super.key,
    required this.textScale,
    required this.interfaceScale,
    required this.child,
  });

  final double textScale;
  final double interfaceScale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scale = interfaceScale;
    final virtualSize = media.size / scale;
    final scaledMedia = media.copyWith(
      size: virtualSize,
      padding: media.padding / scale,
      viewPadding: media.viewPadding / scale,
      viewInsets: media.viewInsets / scale,
      systemGestureInsets: media.systemGestureInsets / scale,
      // Every surface reads this one scaler: Text applies it implicitly and
      // the chat's RichText widgets read it explicitly. The outer transform
      // scales geometry and text together for interface size, so the font
      // preference belongs here on its own — dividing by interfaceScale caused
      // normal Text widgets to stay small while noScaling text still grew.
      textScaler: TextScaler.linear(textScale),
    );

    return AppKeyboardDismissOnTap(
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: virtualSize.width,
          maxWidth: virtualSize.width,
          minHeight: virtualSize.height,
          maxHeight: virtualSize.height,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: virtualSize.width,
              height: virtualSize.height,
              child: MediaQuery(data: scaledMedia, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
