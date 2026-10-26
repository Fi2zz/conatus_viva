import 'dart:io';

import 'package:flutter_wanxiang/pipeline/ffmpeg.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_ffmpeg_test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// Generate a real clip via lavfi (`testsrc` [+ `sine`]) so ffprobe-based
  /// assertions run against actual media. ffmpeg 9.x is available locally.
  Future<File> makeClip(
    String name, {
    double seconds = 3,
    bool withAudio = true,
  }) async {
    final out = File('${tmp.path}/$name');
    await runFfmpeg([
      '-v',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=640x360:rate=24,format=yuv420p',
      if (withAudio) ...[
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:sample_rate=44100',
      ],
      '-t',
      '$seconds',
      if (withAudio) '-shortest',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      if (withAudio) ...['-c:a', 'aac', '-b:a', '128k'],
      out.path,
    ]);
    return out;
  }

  Future<File> makeImage(String name, {int w = 1600, int h = 1000}) async {
    final out = File('${tmp.path}/$name');
    await runFfmpeg([
      '-v',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=${w}x$h:rate=1',
      '-frames:v',
      '1',
      out.path,
    ]);
    return out;
  }

  /// `width,height,avg_frame_rate` of the first video stream.
  Future<List<String>> probeVideo(File f) async {
    final r = await Process.run('ffprobe', [
      '-v',
      'quiet',
      '-select_streams',
      'v:0',
      '-show_entries',
      'stream=width,height,avg_frame_rate',
      '-of',
      'csv=p=0',
      f.path,
    ]);
    expect(r.exitCode, 0, reason: 'ffprobe failed: ${r.stderr}');
    return (r.stdout as String).trim().split(',');
  }

  Future<Set<String>> probeCodecs(File f) async {
    final r = await Process.run('ffprobe', [
      '-v',
      'quiet',
      '-show_entries',
      'stream=codec_name',
      '-of',
      'csv=p=0',
      f.path,
    ]);
    expect(r.exitCode, 0, reason: 'ffprobe failed: ${r.stderr}');
    return (r.stdout as String)
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  /// `mean_volume` in dB of the first audio stream (via `volumedetect`).
  Future<double> meanVolumeDb(File f) async {
    final r = await Process.run('ffmpeg', [
      '-i',
      f.path,
      '-map',
      '0:a',
      '-af',
      'volumedetect',
      '-f',
      'null',
      '-',
    ]);
    expect(r.exitCode, 0, reason: 'ffmpeg failed: ${r.stderr}');
    final m = RegExp(
      r'mean_volume:\s*(-?[\d.]+)\s*dB',
    ).firstMatch('${r.stderr}');
    expect(m, isNotNull, reason: 'no volumedetect output: ${r.stderr}');
    return double.parse(m!.group(1)!);
  }

  group('duration probe and process runner', () {
    test('mediaDurationSeconds parses ffprobe output', () async {
      final clip = await makeClip('probe3s.mp4', seconds: 3);
      final seconds = await mediaDurationSeconds(clip);
      expect(seconds, closeTo(3.0, 0.1));
    });

    test('mediaDurationSeconds throws on missing file', () async {
      final missing = File('${tmp.path}/nope.mp4');
      await expectLater(
        mediaDurationSeconds(missing),
        throwsA(
          isA<FfmpegException>().having(
            (e) => e.exitCode,
            'exitCode',
            isNot(0),
          ),
        ),
      );
    });

    test('runFfmpeg throws FfmpegException on bad input', () async {
      final missing = File('${tmp.path}/does_not_exist.mp4');
      await expectLater(
        runFfmpeg([
          '-v',
          'error',
          '-y',
          '-i',
          missing.path,
          '${tmp.path}/out.mp4',
        ]),
        throwsA(
          isA<FfmpegException>()
              .having((e) => e.exitCode, 'exitCode', isNot(0))
              .having((e) => e.stderr, 'stderr', isNotEmpty),
        ),
      );
    });
  });

  group('command builders (args only, no binary name)', () {
    test('kenBurnsArgs pins 720p/24fps/zoompan duration', () {
      final args = kenBurnsArgs(
        img: File('/tmp/in.png'),
        durationS: 3,
        out: File('/tmp/kb.mp4'),
      );
      final joined = args.join(' ');
      expect(joined, contains('zoompan'));
      expect(joined, contains('scale=1280:720'));
      expect(joined, contains('fps=24'));
      expect(joined, contains('d=${3 * 24}')); // 3 s × 24 fps → 72 frames
      expect(args, containsAllInOrder(['-t', '3'])); // duration pinned
      expect(joined, contains('libx264'));
      expect(joined, contains('yuv420p'));
      expect(args.last, '/tmp/kb.mp4');
      expect(args, isNot(contains('ffmpeg')));
    });

    test('normalizeArgs pins scale+pad 720p/24fps h264 silent aac', () {
      final args = normalizeArgs(
        input: File('/tmp/in.mp4'),
        out: File('/tmp/norm.mp4'),
      );
      final joined = args.join(' ');
      expect(joined, contains('scale=1280:720'));
      expect(joined, contains('pad=1280:720'));
      expect(joined, contains('fps=24'));
      expect(joined, contains('libx264'));
      expect(joined, contains('anullsrc')); // silent aac track (保持无声)
      expect(args, containsAllInOrder(['-c:a', 'aac']));
      expect(args.last, '/tmp/norm.mp4');
    });

    test('kenBurnsArgsFor emits 1080x1920/24fps and keeps duration', () {
      final args = kenBurnsArgsFor(
        img: File('/tmp/in.png'),
        durationS: 3,
        out: File('/tmp/vertical.mp4'),
        width: 1080,
        height: 1920,
      );
      final joined = args.join(' ');
      expect(joined, contains('scale=1080:1920'));
      expect(joined, contains('s=1080x1920'));
      expect(joined, contains('fps=24'));
      expect(joined, contains('d=${3 * 24}'));
    });

    test('microArgsFor uses a gentler zoom than kenburns', () {
      final args = microArgsFor(
        img: File('/tmp/in.png'),
        durationS: 3,
        out: File('/tmp/micro.mp4'),
        width: 1080,
        height: 1920,
      );
      final joined = args.join(' ');
      expect(joined, contains('1.08'));
      expect(joined, contains('scale=1080:1920'));
    });

    test('normalizeToDurationArgs pins duration and tpad', () {
      final args = normalizeToDurationArgs(
        input: File('/tmp/in.mp4'),
        out: File('/tmp/out.mp4'),
        durationS: 2.5,
        width: 1080,
        height: 1920,
      );
      final joined = args.join(' ');
      expect(joined, contains('tpad=stop_mode=clone'));
      expect(args, containsAllInOrder(['-t', '2.5']));
      expect(joined, contains('scale=1080:1920'));
    });

    test('normalizeArgsFor emits 1080x1920', () {
      final args = normalizeArgsFor(
        input: File('/tmp/in.mp4'),
        out: File('/tmp/vertical-norm.mp4'),
        width: 1080,
        height: 1920,
      );
      final joined = args.join(' ');
      expect(joined, contains('scale=1080:1920'));
      expect(joined, contains('pad=1080:1920'));
    });

    test('muxArgs trims and pads audio to clip duration', () {
      final shortAudio = muxArgs(
        video: File('/tmp/v.mp4'),
        audio: File('/tmp/a.wav'),
        audioS: 2.0,
        durationS: 3,
        out: File('/tmp/m.mp4'),
      );
      final joined = shortAudio.join(' ');
      expect(joined, contains('atrim=end=2.0')); // measured audio length
      expect(joined, contains('apad=whole_dur=3')); // padded to clip length
      expect(shortAudio, containsAllInOrder(['-c:v', 'copy']));
      expect(shortAudio, containsAllInOrder(['-c:a', 'aac']));
      expect(shortAudio, containsAllInOrder(['-b:a', '128k']));
      expect(shortAudio, containsAllInOrder(['-map', '0:v:0']));
      expect(shortAudio, containsAllInOrder(['-map', '1:a:0']));

      final longAudio = muxArgs(
        video: File('/tmp/v.mp4'),
        audio: File('/tmp/a.wav'),
        audioS: 6.0,
        durationS: 5,
        out: File('/tmp/m.mp4'),
      );
      final longJoined = longAudio.join(' ');
      expect(longJoined, contains('atrim=end=5')); // capped at clip length
      expect(longJoined, contains('apad=whole_dur=5'));
    });

    test('concatArgs uses concat demuxer with -c copy', () {
      final out = File('/tmp/final.mp4');
      final args = concatArgs(
        parts: [File('/tmp/p1.mp4'), File('/tmp/p2.mp4')],
        out: out,
      );
      expect(args, containsAllInOrder(['-f', 'concat']));
      expect(args, containsAllInOrder(['-safe', '0']));
      expect(args, containsAllInOrder(['-c', 'copy']));
      expect(args, contains(concatListFileFor(out).path));
      expect(args.last, '/tmp/final.mp4');
      expect(() => concatArgs(parts: const [], out: out), throwsArgumentError);
    });

    test('writeConcatList writes the list concatArgs reads', () async {
      final p1 = File('${tmp.path}/p1.mp4');
      final p2 = File('${tmp.path}/p2.mp4');
      final out = File('${tmp.path}/final.mp4');
      await writeConcatList(parts: [p1, p2], out: out);
      final list = concatListFileFor(out);
      expect(list.existsSync(), isTrue);
      expect(
        await list.readAsString(),
        "file '${p1.path}'\nfile '${p2.path}'\n",
      );
      // concatArgs references exactly that file.
      expect(concatArgs(parts: [p1, p2], out: out), contains(list.path));
    });

    test('overlayAvatarArgs rounds + scales the avatar and keeps audio', () {
      final args = overlayAvatarArgs(
        video: File('/tmp/v.mp4'),
        avatar: File('/tmp/a.jpg'),
        out: File('/tmp/o.mp4'),
      );
      final joined = args.join(' ');
      expect(joined, contains('overlay'));
      expect(joined, contains('scale2ref'));
      expect(joined, contains('geq')); // 圆角 alpha
      expect(args, containsAllInOrder(['-c:a', 'copy']));
      expect(joined, contains('libx264'));
      expect(joined, contains('yuv420p'));
      expect(joined, contains('[v]'));
      expect(args, containsAllInOrder(['-i', '/tmp/v.mp4']));
      expect(args, containsAllInOrder(['-i', '/tmp/a.jpg']));
      expect(args.last, '/tmp/o.mp4');
    });
  });

  group('builders end-to-end (real ffmpeg)', () {
    test('kenBurnsArgs output is a 3s 1280x720/24fps clip', () async {
      final img = await makeImage('src.png');
      final out = File('${tmp.path}/kb.mp4');
      await runFfmpeg(kenBurnsArgs(img: img, durationS: 3, out: out));
      expect(await mediaDurationSeconds(out), closeTo(3.0, 0.1));
      final v = await probeVideo(out);
      expect(v[0], '1280');
      expect(v[1], '720');
      expect(v[2], '24/1');
    });

    test('normalizeArgs output is 720p/24fps with silent aac', () async {
      final clip = await makeClip('small3s.mp4');
      final out = File('${tmp.path}/norm.mp4');
      await runFfmpeg(normalizeArgs(input: clip, out: out));
      expect(await mediaDurationSeconds(out), closeTo(3.0, 0.1));
      final v = await probeVideo(out);
      expect(v[0], '1280');
      expect(v[1], '720');
      expect(v[2], '24/1');
      final codecs = await probeCodecs(out);
      expect(codecs, contains('h264'));
      expect(codecs, contains('aac'));
      expect(await meanVolumeDb(out), lessThan(-50)); // 保持无声
    });

    test('kenBurnsArgsFor output is a 2s 1080x1920/24fps clip', () async {
      final img = await makeImage('vertical-src.png');
      final out = File('${tmp.path}/vertical.mp4');
      await runFfmpeg(
        kenBurnsArgsFor(
          img: img,
          durationS: 2,
          out: out,
          width: 1080,
          height: 1920,
        ),
      );
      expect(await mediaDurationSeconds(out), closeTo(2.0, 0.1));
      final v = await probeVideo(out);
      expect(v[0], '1080');
      expect(v[1], '1920');
      expect(v[2], '24/1');
    });

    test('normalizeToDurationArgs output is exact-duration 1080x1920', () async {
      final clip = await makeClip('short-src.mp4');
      final out = File('${tmp.path}/duration.mp4');
      await runFfmpeg(
        normalizeToDurationArgs(
          input: clip,
          out: out,
          durationS: 1.5,
          width: 1080,
          height: 1920,
        ),
      );
      expect(await mediaDurationSeconds(out), closeTo(1.5, 0.2));
      final v = await probeVideo(out);
      expect(v[0], '1080');
      expect(v[1], '1920');
    });

    test('normalizeArgsFor output is 1080x1920 with silent aac', () async {
      final clip = await makeClip('vertical-norm-src.mp4');
      final out = File('${tmp.path}/vertical-norm.mp4');
      await runFfmpeg(
        normalizeArgsFor(
          input: clip,
          out: out,
          width: 1080,
          height: 1920,
        ),
      );
      expect(await mediaDurationSeconds(out), closeTo(3.0, 0.1));
      final v = await probeVideo(out);
      expect(v[0], '1080');
      expect(v[1], '1920');
      expect(v[2], '24/1');
    });

    test('muxArgs output is clip-length with trimmed+padded audio', () async {
      final video = await makeClip('v3s.mp4');
      final audio = File('${tmp.path}/a2s.wav');
      await runFfmpeg([
        '-v',
        'error',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:sample_rate=44100',
        '-t',
        '2',
        audio.path,
      ]);
      final out = File('${tmp.path}/mux.mp4');
      await runFfmpeg(
        muxArgs(
          video: video,
          audio: audio,
          audioS: 2.0,
          durationS: 3,
          out: out,
        ),
      );
      // 2 s audio padded to the 3 s clip, video stream-copied.
      expect(await mediaDurationSeconds(out), closeTo(3.0, 0.1));
      final codecs = await probeCodecs(out);
      expect(codecs, contains('h264'));
      expect(codecs, contains('aac'));
    });

    test('concatArgs joins parts into one clip', () async {
      final p1 = await makeClip('part1.mp4', seconds: 1.5);
      final p2 = await makeClip('part2.mp4', seconds: 1.5);
      final out = File('${tmp.path}/final.mp4');
      await writeConcatList(parts: [p1, p2], out: out);
      await runFfmpeg(concatArgs(parts: [p1, p2], out: out));
      expect(await mediaDurationSeconds(out), closeTo(3.0, 0.1));
      final codecs = await probeCodecs(out);
      expect(codecs, contains('h264'));
      expect(codecs, contains('aac'));
    });

    test('overlayAvatarArgs output keeps duration and an audio track', () async {
      final video = await makeClip('host3s.mp4'); // 640x360 + 440Hz sine
      final avatar = await makeImage('avatar.png', w: 512, h: 512);
      final out = File('${tmp.path}/overlaid.mp4');
      await runFfmpeg(overlayAvatarArgs(video: video, avatar: avatar, out: out));
      expect(await mediaDurationSeconds(out), closeTo(3.0, 0.3));
      final codecs = await probeCodecs(out);
      expect(codecs, contains('h264'));
      expect(codecs, contains('aac'));
    });
  });
}
