//
//  mp4_fixtures.dart
//
//  Byte primitives for tests that need a real file on disk instead of a mock:
//  [isoBox] wraps a payload in an ISO-BMFF size+type header and
//  [writeTempMediaFile] puts the result somewhere a probe can open it.
//  Everything built here is synthetic — no real media is read or shipped.
//

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Big-endian 32-bit field bytes.
List<int> isoU32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

/// One box: size32(4) + type(4) + [payload].
List<int> isoBox(String type, List<int> payload) => [
  ...isoU32(8 + payload.length),
  ...type.codeUnits,
  ...payload,
];

/// Flattens a list of boxes into one byte run, for nesting.
List<int> isoConcat(Iterable<List<int>> boxes) => [
  for (final box in boxes) ...box,
];

/// Writes [bytes] into a fresh temp directory the test tears down, and returns
/// the file's path.
Future<String> writeTempMediaFile(
  List<int> bytes, {
  String name = 'clip.mp4',
}) async {
  final directory = await Directory.systemTemp.createTemp('mithka-mp4-fixture');
  addTearDown(() => directory.delete(recursive: true));
  final file = File('${directory.path}/$name');
  await file.writeAsBytes(bytes);
  return file.path;
}

/// The synchronous form. A `testWidgets` body runs in a fake-async zone, where
/// awaiting real file IO never resolves, so widget tests have to use this.
String writeTempMediaFileSync(List<int> bytes, {String name = 'clip.mp4'}) {
  final directory = Directory.systemTemp.createTempSync('mithka-mp4-fixture');
  addTearDown(() => directory.deleteSync(recursive: true));
  final file = File('${directory.path}/$name');
  file.writeAsBytesSync(bytes);
  return file.path;
}
