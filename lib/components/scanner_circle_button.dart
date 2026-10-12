//
//  scanner_circle_button.dart
//
//  The round control floated over a camera preview in the QR scanners.
//

import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';
import 'app_icons.dart';

/// A 44pt translucent circle over the camera feed; [active] fills it with
/// the brand color and a null [onTap] dims the icon.
class ScannerCircleButton extends StatelessWidget {
  const ScannerCircleButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  final AppIconData icon;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: active ? AppTheme.brand : const Color(0x66000000),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: Center(
          child: AppIcon(
            icon,
            size: 22,
            color: onTap == null
                ? const Color(0x66FFFFFF)
                : const Color(0xFFFFFFFF),
          ),
        ),
      ),
    );
  }
}
