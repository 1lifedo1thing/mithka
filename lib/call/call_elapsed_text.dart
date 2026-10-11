//
//  call_elapsed_text.dart
//
//  Elapsed call time for the 1:1 and group call screens.
//

import 'dart:async';

import 'package:flutter/widgets.dart';

/// `mm:ss`, or `hh:mm:ss` from the first hour on, the way call timers and
/// call log entries read.
String formatCallDuration(int seconds) {
  final total = seconds < 0 ? 0 : seconds;
  String two(int value) => value.toString().padLeft(2, '0');
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final rest = total % 60;
  return hours > 0
      ? '${two(hours)}:${two(minutes)}:${two(rest)}'
      : '${two(minutes)}:${two(rest)}';
}

/// Elapsed time since [startedAt], ticking on its own. Owning the timer here
/// keeps the 1 Hz tick from rebuilding the whole call screen — video views,
/// backdrop and controls — once a second for the whole call.
class CallElapsedText extends StatefulWidget {
  const CallElapsedText({super.key, required this.startedAt, this.style});

  final DateTime? startedAt;
  final TextStyle? style;

  @override
  State<CallElapsedText> createState() => _CallElapsedTextState();
}

class _CallElapsedTextState extends State<CallElapsedText> {
  /// 99:59:59, the longest time the two-digit hour field can show.
  static const _maximumSeconds = 359999;

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant CallElapsedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startedAt != widget.startedAt) _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (widget.startedAt == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final startedAt = widget.startedAt;
    final seconds = startedAt == null
        ? 0
        : DateTime.now()
              .difference(startedAt)
              .inSeconds
              .clamp(0, _maximumSeconds);
    return Text(formatCallDuration(seconds), style: widget.style);
  }
}
