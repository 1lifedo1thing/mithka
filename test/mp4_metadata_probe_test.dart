import 'package:flutter_test/flutter_test.dart';
import 'package:mithka/media/mp4_metadata_probe.dart';

import 'support/mp4_fixtures.dart';

/// A box whose size needs the 64-bit form: size32(4)=1 + type(4) + largesize(8).
List<int> _largeBox(String type, List<int> payload) => [
  ...isoU32(1),
  ...type.codeUnits,
  ...isoU32(0),
  ...isoU32(16 + payload.length),
  ...payload,
];

List<int> _mdhd({
  int version = 0,
  int timescale = 600,
  int duration = 300,
  int pad = 12,
  List<int>? rawPayload,
}) {
  if (rawPayload != null) return isoBox('mdhd', rawPayload);
  return isoBox('mdhd', [
    version,
    0,
    0,
    0, // version + flags
    if (version == 0) ...[
      ...isoU32(0), // creation
      ...isoU32(0), // modification
      ...isoU32(timescale),
      ...isoU32(duration),
    ] else ...[
      ...isoU32(0),
      ...isoU32(0), // creation (64-bit)
      ...isoU32(0),
      ...isoU32(0), // modification (64-bit)
      ...isoU32(timescale),
      ...isoU32(duration >> 32),
      ...isoU32(duration & 0xffffffff),
    ],
    ...List<int>.filled(pad, 0),
  ]);
}

List<int> _hdlr({
  String handler = 'vide',
  int version = 0,
  List<int>? rawPayload,
}) {
  if (rawPayload != null) return isoBox('hdlr', rawPayload);
  return isoBox('hdlr', [
    version,
    0,
    0,
    0, // version + flags
    ...isoU32(0), // pre_defined
    ...handler.codeUnits,
    0,
    0,
    0,
    0,
  ]);
}

/// A well-formed stsd: [entryCount] declared, one entry of [entrySize] bytes
/// present, its format fourcc first.
List<int> _stsd({
  String fourcc = 'avc1',
  int entryCount = 1,
  int entrySize = 16,
  int version = 0,
}) => isoBox('stsd', [
  version,
  0,
  0,
  0, // version + flags
  ...isoU32(entryCount),
  ...isoU32(entrySize),
  ...fourcc.codeUnits,
  ...List<int>.filled(entrySize - 8, 0),
]);

/// An stsd whose declared count and actual bytes disagree, which is what a
/// corrupt or half-written file looks like.
List<int> _bareStsd({
  required int entryCount,
  List<int> entry = const [],
  int version = 0,
}) => isoBox('stsd', [version, 0, 0, 0, ...isoU32(entryCount), ...entry]);

List<int> _stts(List<(int, int)> entries, {int version = 0}) => isoBox('stts', [
  version,
  0,
  0,
  0,
  ...isoU32(entries.length),
  // The table interleaves: sample_count then sample_delta, per entry.
  for (final entry in entries) ...[...isoU32(entry.$1), ...isoU32(entry.$2)],
]);

List<int> _trak({
  String handler = 'vide',
  String codec = 'avc1',
  int timescale = 600,
  int duration = 300,
  List<(int, int)> stts = const [(15, 20)],
  int mdhdVersion = 0,
  bool withStts = true,
  List<List<int>>? stblChildren,
  List<List<int>>? mdiaChildren,
  List<List<int>> mdiaTail = const [],
}) {
  final stbl =
      stblChildren ?? [_stsd(fourcc: codec), if (withStts) _stts(stts)];
  final mdia =
      mdiaChildren ??
      [
        _mdhd(version: mdhdVersion, timescale: timescale, duration: duration),
        _hdlr(handler: handler),
        isoBox('minf', [...isoBox('stbl', isoConcat(stbl))]),
        ...mdiaTail,
      ];
  return isoBox('trak', [...isoBox('mdia', isoConcat(mdia))]);
}

List<int> _mp4({
  List<List<int>>? traks,
  bool longSize = false,
  bool moovFirst = false,
  List<List<int>> moovFiller = const [],
}) {
  final tracks = traks ?? [_trak()];
  final moov = isoBox('moov', isoConcat([...moovFiller, ...tracks]));
  final media = longSize
      ? _largeBox('mdat', List<int>.filled(64, 7))
      : isoBox('mdat', List<int>.filled(64, 7));
  // moov before mdat when asked, otherwise the classic metadata-at-the-end
  // file a phone records.
  final boxes = <List<int>>[if (moovFirst) moov, media, if (!moovFirst) moov];
  return isoConcat([
    isoBox('ftyp', [...'isom'.codeUnits, ...isoU32(0), ...'isom'.codeUnits]),
    ...boxes,
  ]);
}

/// [count] empty `free` boxes: filler a traversal has to walk past.
List<List<int>> _filler(int count) => [
  for (var index = 0; index < count; index++) isoBox('free', const []),
];

void main() {
  test('cancellation stops a probe before more file reads', () async {
    final path = await writeTempMediaFile(_mp4());
    debugMp4ProbeReadCount = 0;
    final track = await probeMp4VideoTrack(
      path,
      cancelled: () => debugMp4ProbeReadCount >= 2,
    );
    expect(track, isNull);
    expect(debugMp4ProbeReadCount, 2);
    // Cancellation still closes the descriptor and leaves a later probe usable.
    expect((await probeMp4VideoTrack(path))?.codec, 'H.264');
  });

  test('many bounded tracks still share a whole-probe IO budget', () async {
    final tracks = [
      for (var index = 0; index < 64; index++)
        isoBox(
          'trak',
          isoConcat([
            ..._filler(64),
            isoBox('mdia', isoConcat([..._filler(64), _hdlr(handler: 'soun')])),
          ]),
        ),
    ];
    final path = await writeTempMediaFile(_mp4(traks: tracks));
    expect(await probeMp4VideoTrack(path), isNull);
    expect(debugMp4ProbeReadCount, lessThan(4096));
  });

  test('reads the codec and frame rate of an mdat-first file', () async {
    final path = await writeTempMediaFile(_mp4());
    final track = await probeMp4VideoTrack(path);
    expect(track?.codec, 'H.264');
    expect(track?.frameRate, closeTo(30, 0.001));
  });

  test('reads a file whose moov sits at the front', () async {
    final path = await writeTempMediaFile(_mp4(moovFirst: true));
    expect((await probeMp4VideoTrack(path))?.codec, 'H.264');
  });

  test('walks past a 64-bit box header', () async {
    final path = await writeTempMediaFile(_mp4(longSize: true));
    expect((await probeMp4VideoTrack(path))?.codec, 'H.264');
  });

  test('skips an audio track and reads the video track after it', () async {
    final path = await writeTempMediaFile(
      _mp4(
        traks: [
          _trak(handler: 'soun', codec: 'mp4a', withStts: false),
          _trak(codec: 'hvc1', timescale: 900, duration: 450, stts: [(30, 30)]),
        ],
      ),
    );
    final track = await probeMp4VideoTrack(path);
    expect(track?.codec, 'HEVC');
    expect(track?.frameRate, closeTo(60, 0.001));
  });

  test('handles the 64-bit mdhd time fields', () async {
    final path = await writeTempMediaFile(_mp4(traks: [_trak(mdhdVersion: 1)]));
    final track = await probeMp4VideoTrack(path);
    expect(track?.codec, 'H.264');
    expect(track?.frameRate, closeTo(30, 0.001));
  });

  test('reports the codec without a frame rate when stts is missing', () async {
    final path = await writeTempMediaFile(
      _mp4(traks: [_trak(withStts: false)]),
    );
    final track = await probeMp4VideoTrack(path);
    expect(track?.codec, 'H.264');
    expect(track?.frameRate, isNull);
  });

  test('sums every stts entry', () async {
    final path = await writeTempMediaFile(
      _mp4(
        traks: [
          _trak(duration: 600, stts: [(10, 20), (20, 20)]),
        ],
      ),
    );
    // 30 samples over one second.
    expect((await probeMp4VideoTrack(path))?.frameRate, closeTo(30, 0.001));
  });

  test('fails closed on a truncated download', () async {
    final whole = _mp4();
    final path = await writeTempMediaFile(whole.sublist(0, whole.length - 12));
    expect(await probeMp4VideoTrack(path), isNull);
  });

  test('fails closed on files that are not ISO-BMFF', () async {
    final junk = await writeTempMediaFile([
      ...'1A45DFA3'.codeUnits,
      ...List<int>.filled(64, 0),
    ], name: 'clip.webm');
    expect(await probeMp4VideoTrack(junk), isNull);

    final tiny = await writeTempMediaFile(const [
      0,
      0,
      0,
      8,
    ], name: 'empty.mp4');
    expect(await probeMp4VideoTrack(tiny), isNull);

    expect(await probeMp4VideoTrack('/no/such/file.mp4'), isNull);
  });

  test('names the known sample formats', () {
    expect(mp4CodecName('avc3'), 'H.264');
    expect(mp4CodecName('hev1'), 'HEVC');
    expect(mp4CodecName('av01'), 'AV1');
    expect(mp4CodecName('vp09'), 'VP9');
    expect(mp4CodecName('zzzz'), 'ZZZZ');
  });

  // A leaf read that runs past its own box lands in the next one, and the bytes
  // there are a plausible-looking codec or handler. Every case below pairs a
  // malformed inner box with well-formed neighbours, which is the shape a
  // hostile or half-written file actually has.
  group('malformed inner boxes', () {
    test('an stsd declaring no sample entry is not a codec', () async {
      // The old unbounded 16-byte read ran into the empty `free` sibling and
      // reported its type as the codec.
      final path = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(
              stblChildren: [
                _bareStsd(entryCount: 0),
                isoBox('free', const []),
              ],
            ),
          ],
        ),
      );
      expect(await probeMp4VideoTrack(path), isNull);
    });

    test('a sample entry that claims more bytes than stsd holds', () async {
      final path = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(
              stblChildren: [
                _bareStsd(
                  entryCount: 1,
                  entry: [...isoU32(4096), ...'avc1'.codeUnits],
                ),
                isoBox('free', const []),
              ],
            ),
          ],
        ),
      );
      expect(await probeMp4VideoTrack(path), isNull);
    });

    test('an empty hdlr is not a handler, whatever follows it', () async {
      // The sibling's payload spells `vide`, which is exactly where an
      // unbounded read would have found a handler type.
      final path = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(
              mdiaChildren: [
                _mdhd(),
                _hdlr(rawPayload: const []),
                isoBox('free', [...'vide'.codeUnits, ...isoU32(0)]),
                isoBox('minf', [
                  ...isoBox(
                    'stbl',
                    isoConcat([
                      _stsd(),
                      _stts([(15, 20)]),
                    ]),
                  ),
                ]),
              ],
            ),
          ],
        ),
      );
      expect(await probeMp4VideoTrack(path), isNull);
    });

    test('a future fullbox version is refused', () async {
      // stsd claiming a version this parser does not know.
      final stsdVersion = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(
              stblChildren: [
                _stsd(version: 1),
                _stts([(15, 20)]),
              ],
            ),
          ],
        ),
      );
      expect(await probeMp4VideoTrack(stsdVersion), isNull);

      // Same for the handler box.
      final hdlrVersion = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(
              mdiaChildren: [
                _mdhd(),
                _hdlr(version: 3),
                isoBox('minf', [
                  ...isoBox(
                    'stbl',
                    isoConcat([
                      _stsd(),
                      _stts([(15, 20)]),
                    ]),
                  ),
                ]),
              ],
            ),
          ],
        ),
      );
      expect(await probeMp4VideoTrack(hdlrVersion), isNull);

      // The control file, so the two rejections above are not both passing for
      // an unrelated reason.
      final control = await writeTempMediaFile(_mp4());
      expect((await probeMp4VideoTrack(control))?.codec, 'H.264');
    });

    test('an mdhd too short for its version yields no frame rate', () async {
      // 16 bytes: enough for the v0 timescale, not for the duration after it.
      final shortV0 = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(
              mdiaChildren: [
                _mdhd(rawPayload: [0, 0, 0, 0, ...isoU32(0), ...isoU32(600)]),
                _hdlr(),
                isoBox('minf', [
                  ...isoBox(
                    'stbl',
                    isoConcat([
                      _stsd(),
                      _stts([(15, 20)]),
                    ]),
                  ),
                ]),
              ],
            ),
          ],
        ),
      );
      final track = await probeMp4VideoTrack(shortV0);
      expect(track?.codec, 'H.264');
      expect(track?.frameRate, isNull);

      // A v1 header needs 32 bytes; 20 is a v0-shaped payload lying about it.
      final shortV1 = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(
              mdiaChildren: [
                _mdhd(
                  rawPayload: [
                    1,
                    0,
                    0,
                    0,
                    ...isoU32(0),
                    ...isoU32(0),
                    ...isoU32(600),
                    ...isoU32(300),
                  ],
                ),
                _hdlr(),
                isoBox('minf', [
                  ...isoBox(
                    'stbl',
                    isoConcat([
                      _stsd(),
                      _stts([(15, 20)]),
                    ]),
                  ),
                ]),
              ],
            ),
          ],
        ),
      );
      expect((await probeMp4VideoTrack(shortV1))?.frameRate, isNull);

      // An unknown version is not something to guess a layout for.
      final oddVersion = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(
              mdiaChildren: [
                _mdhd(rawPayload: [7, 0, 0, 0, ...List<int>.filled(28, 0)]),
                _hdlr(),
                isoBox('minf', [
                  ...isoBox(
                    'stbl',
                    isoConcat([
                      _stsd(),
                      _stts([(15, 20)]),
                    ]),
                  ),
                ]),
              ],
            ),
          ],
        ),
      );
      expect((await probeMp4VideoTrack(oddVersion))?.frameRate, isNull);
    });

    test('an stts too short for its header is skipped', () async {
      final path = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(
              stblChildren: [
                _stsd(),
                isoBox('stts', const [0, 0, 0, 0]),
              ],
            ),
          ],
        ),
      );
      final track = await probeMp4VideoTrack(path);
      expect(track?.codec, 'H.264');
      expect(track?.frameRate, isNull);
    });

    test('a fourcc that is not a box type is not a codec', () async {
      final path = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(
              stblChildren: [
                _bareStsd(entryCount: 1, entry: [...isoU32(8), 0, 0, 0, 0]),
              ],
            ),
          ],
        ),
      );
      expect(await probeMp4VideoTrack(path), isNull);
    });
  });

  // Opening the sheet on someone else's file must not turn into an open-ended
  // walk, whether or not anything matches.
  group('traversal budget', () {
    test('gives up on a level of filler instead of walking all of it', () async {
      final path = await writeTempMediaFile(_mp4(moovFiller: _filler(2048)));
      expect(await probeMp4VideoTrack(path), isNull);
      // 2048 children would be 2048 header reads; the budget caps the level at
      // 512 boxes visited, so the whole probe stays in the hundreds.
      expect(debugMp4ProbeReadCount, lessThan(600));
    });

    test('still finds a track inside the budget', () async {
      final path = await writeTempMediaFile(_mp4(moovFiller: _filler(8)));
      final track = await probeMp4VideoTrack(path);
      expect(track?.codec, 'H.264');
      expect(track?.frameRate, closeTo(30, 0.001));
    });

    test('a lookup stops at the child it wanted', () async {
      // Every box mdia needs sits at the front, so 400 trailing fillers are
      // only reachable by a lookup that lists the whole level.
      final path = await writeTempMediaFile(
        _mp4(traks: [_trak(mdiaTail: _filler(400))]),
      );
      final track = await probeMp4VideoTrack(path);
      expect(track?.codec, 'H.264');
      expect(track?.frameRate, closeTo(30, 0.001));
      expect(debugMp4ProbeReadCount, lessThan(100));
    });

    test('a level with nothing matching still terminates', () async {
      final path = await writeTempMediaFile(
        _mp4(
          traks: [
            _trak(mdiaChildren: [_hdlr(), ..._filler(1024)]),
          ],
        ),
      );
      // hdlr is found, but there is no minf at all: every lookup scans to the
      // budget and comes back empty.
      expect(await probeMp4VideoTrack(path), isNull);
      expect(debugMp4ProbeReadCount, lessThan(2000));
    });
  });
}
