import 'dart:typed_data';

/// Growable typed arrays: millions of roads without boxed-list overhead.
class I64 {
  Int64List _d = Int64List(1024);
  int length = 0;
  void add(int v) {
    if (length == _d.length) _d = Int64List(_d.length * 2)..setRange(0, length, _d);
    _d[length++] = v;
  }

  Int64List view() => Int64List.sublistView(_d, 0, length);
}

class I32 {
  Int32List _d = Int32List(1024);
  int length = 0;
  void add(int v) {
    if (length == _d.length) _d = Int32List(_d.length * 2)..setRange(0, length, _d);
    _d[length++] = v;
  }

  Int32List view() => Int32List.sublistView(_d, 0, length);
}

class U8 {
  Uint8List _d = Uint8List(1024);
  int length = 0;
  void add(int v) {
    if (length == _d.length) _d = Uint8List(_d.length * 2)..setRange(0, length, _d);
    _d[length++] = v;
  }

  Uint8List view() => Uint8List.sublistView(_d, 0, length);
}

/// First index whose value is >= [v] in a sorted list.
int lowerBound(List<int> a, int v) {
  var lo = 0, hi = a.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (a[mid] < v) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

int lowerBound32(Int32List a, int v) => lowerBound(a, v);
