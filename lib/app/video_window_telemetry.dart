import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../media/video_playback_reporting.dart';
import 'telemetry_config.dart';

/// Detached video windows have their own Dart isolate and skip app bootstrap.
/// They need a Dart hub, but must not reinitialize the process-wide native SDK
/// or overwrite the main window's native scope/session/performance settings.
Future<void> initializeVideoWindowTelemetry() async {
  if (!sentryEnabled) return;
  try {
    await SentryFlutter.init(configureVideoWindowTelemetry);
  } catch (_) {
    // An unavailable telemetry plugin must never prevent a video window opening.
  }
}

@visibleForTesting
void configureVideoWindowTelemetry(SentryFlutterOptions options) {
  options.dsn = sentryDsn;
  options.environment = sentryEnvironment;
  options.autoInitializeNativeSdk = false;
  options.enableScopeSync = false;
  options.enableNativeTraceSync = false;
  options.enableFramesTracking = false;
  options.enableAutoSessionTracking = false;
  options.enableAutoPerformanceTracing = false;
  // In this SDK, 0 still installs app-start tracing; null disables it entirely.
  options.tracesSampleRate = null;
  options.tracesSampler = null;
  options.sendDefaultPii = false;
  options.maxBreadcrumbs = 0;
  options.beforeSend = (event, hint) {
    // Keep this hub narrowly scoped to the explicit playback reports.
    if (event.logger != videoPlaybackLogger) return null;
    const commit = String.fromEnvironment('GIT_COMMIT');
    if (commit.isNotEmpty) {
      event.tags = {...?event.tags, 'git.commit': commit};
    }
    return sanitizeVideoPlaybackEvent(event);
  };
}
