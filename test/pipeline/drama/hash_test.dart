import 'package:flutter_wanxiang/pipeline/drama/hash.dart';
import 'package:test/test.dart';

void main() {
  test('canonical json sorts keys recursively', () {
    expect(
      canonicalJson(<String, Object?>{
        'b': 1,
        'a': <String, Object?>{'d': 2, 'c': 3},
        'list': <Object?>[
          <String, Object?>{'z': 1, 'y': 2},
        ],
      }),
      '{"a":{"c":3,"d":2},"b":1,"list":[{"y":2,"z":1}]}',
    );
  });

  test('hash is order independent and 64 hex chars', () {
    expect(dramaHash(<String, Object?>{'a': 1, 'b': 2}), dramaHash(<String, Object?>{'b': 2, 'a': 1}));
    expect(dramaHash(<String, Object?>{'a': 1}), hasLength(64));
    expect(dramaHash(<String, Object?>{'a': 1}), isNot(dramaHash(<String, Object?>{'a': 2})));
  });
}
