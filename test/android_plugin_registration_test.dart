import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual Android registry covers every generated production plugin', () {
    final generated = File(
      'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
    );
    expect(
      generated.existsSync(),
      isTrue,
      reason: 'Run flutter pub get to generate the Android plugin registry.',
    );
    final generatedClasses = RegExp(
      r'getPlugins\(\)\.add\(new ([\w.]+)\(\)\)',
    ).allMatches(generated.readAsStringSync()).map((m) => m[1]!).toSet();
    expect(generatedClasses, isNotEmpty);

    // The integration-test harness is intentionally not part of app startup.
    final productionClasses = generatedClasses.difference({
      'dev.flutter.plugins.integration_test.IntegrationTestPlugin',
    });
    final activity = File(
      'android/app/src/main/kotlin/ad/neko/mithka/MainActivity.kt',
    ).readAsStringSync();
    final manualClasses = RegExp(
      r'add\("([\w.]+)"\)',
    ).allMatches(activity).map((m) => m[1]!).toList();

    expect(
      manualClasses.toSet(),
      productionClasses,
      reason:
          'Keep MainActivity.registerPlugins in sync with native dependencies; '
          'missing entries cause MissingPluginException/channel-error in production.',
    );
    expect(manualClasses.toSet(), hasLength(manualClasses.length));
    expect(activity, contains('registerPlugins(flutterEngine)'));
    expect(
      activity,
      contains('.forName(className, false, javaClass.classLoader)'),
    );
    expect(activity, contains('.asSubclass(FlutterPlugin::class.java)'));
    expect(activity, contains('catch (e: Exception)'));
  });
}
