import 'dart:io';

import 'package:flutter_wanxiang/pipeline/artifacts.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/steps/ingest.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Workdir work;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_ingest_test');
    work = Workdir(tmp.path, 'content1');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  const jpegBytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46];

  test('url input downloaded into 00_inputs with last-modified', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response.bytes(
        jpegBytes,
        200,
        headers: <String, String>{
          'last-modified': HttpDate.format(DateTime.utc(2026, 9, 30, 12, 0, 0)),
        },
      );
    });

    // The ?token= query must not leak into the on-disk file name.
    final photos = await runIngest(
      photos: <String>['https://cdn.example.test/albums/p1.jpg?token=abc'],
      work: work,
      client: client,
    );

    expect(calls, 1);
    expect(photos, hasLength(1));
    final first = photos.single;
    expect(first.source, 'url');
    expect(first.id, '001_p1');
    expect(
      first.file.path,
      work.file('00_inputs/001_p1.jpg').path,
      reason: 'URL downloads land in 00_inputs/<序号>_<文件名>',
    );
    expect(work.exists('00_inputs/001_p1.jpg'), isTrue);
    expect(first.file.readAsBytesSync(), jpegBytes);
    expect(first.capturedAt, DateTime.utc(2026, 9, 30, 12, 0, 0));
  });

  test('local path passes through without copy requirement', () async {
    final local = File('${tmp.path}/raw/photo.jpg');
    local.parent.createSync(recursive: true);
    local.writeAsBytesSync(jpegBytes);

    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response('unexpected', 200);
    });

    final photos = await runIngest(
      photos: <String>[local.path],
      work: work,
      client: client,
    );

    expect(calls, 0, reason: 'local input must not trigger any request');
    expect(photos, hasLength(1));
    final first = photos.single;
    expect(first.source, 'local');
    expect(first.file.path, local.path, reason: 'file reference as-is');
    expect(first.id, '001_photo');
    expect(
      first.capturedAt,
      isNull,
      reason: 'no Last-Modified for local files',
    );
    expect(work.exists('00_inputs'), isFalse, reason: 'no copy is made');
  });

  test('empty photos list is fatal', () async {
    await expectLater(
      runIngest(photos: const <String>[], work: work),
      throwsA(
        isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal),
      ),
    );
  });

  test('re-run with existing copies is idempotent', () async {
    final existing = work.file('00_inputs/001_p1.jpg');
    existing.parent.createSync(recursive: true);
    existing.writeAsBytesSync(const <int>[0x01, 0x02]);

    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response.bytes(jpegBytes, 200);
    });

    final photos = await runIngest(
      photos: <String>['https://cdn.example.test/albums/p1.jpg'],
      work: work,
      client: client,
    );

    expect(calls, 0, reason: 'existing copy means no HTTP request at all');
    expect(photos.single.file.path, existing.path);
    expect(existing.readAsBytesSync(), const <int>[0x01, 0x02]);
    expect(
      photos.single.capturedAt,
      isNull,
      reason: 'no response on a skip, so no Last-Modified to read',
    );
  });

  test('url download failure is transient', () async {
    await expectLater(
      runIngest(
        photos: <String>['https://cdn.example.test/p1.jpg'],
        work: work,
        client: MockClient((_) async => http.Response('busy', 503)),
      ),
      throwsA(
        isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.transient),
      ),
    );

    await expectLater(
      runIngest(
        photos: <String>['https://cdn.example.test/p2.jpg'],
        work: work,
        client: MockClient(
          (_) async => throw http.ClientException('connection reset'),
        ),
      ),
      throwsA(
        isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.transient),
      ),
    );
  });
}
