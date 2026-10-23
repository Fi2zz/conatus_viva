import 'package:flutter_wanxiang/pipeline/drama/ids.dart';
import 'package:test/test.dart';

void main() {
  test('accepts 1..64 safe chars', () {
    expect(isDramaId('ep07'), isTrue);
    expect(isDramaId('ep-07_A'), isTrue);
    expect(isDramaId('a' * 64), isTrue);
  });

  test('rejects empty, traversal, dots and overlong ids', () {
    expect(isDramaId(''), isFalse);
    expect(isDramaId('../ep07'), isFalse);
    expect(isDramaId('ep.07'), isFalse);
    expect(isDramaId('ep/07'), isFalse);
    expect(isDramaId('a' * 65), isFalse);
  });

  test('requireDramaId throws ArgumentError with the field name', () {
    expect(
      () => requireDramaId('bad/id', 'series_id'),
      throwsA(isA<ArgumentError>()),
    );
    expect(requireDramaId('ep07', 'episode_id'), 'ep07');
  });
}
