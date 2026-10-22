import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal reader for OpenStreetMap .osm.pbf files (the format Geofabrik publishes).
/// Spec: https://wiki.openstreetmap.org/wiki/PBF_Format
class PbfReader {
  final String path;
  PbfReader(this.path);

  /// Replication timestamp from the file header (seconds), when present.
  int? timestamp;

  /// Walks every data block. [wantBlock] can skip blocks by file offset (e.g. a second pass over node blocks only).
  /// For each block, [onBlock] gets its offset and decoded contents.
  Future<void> read(void Function(int offset, PbfBlock block) onBlock, {bool Function(int offset)? wantBlock}) async {
    final f = await File(path).open();
    try {
      final len = await f.length();
      var pos = 0;
      while (pos < len) {
        final blockStart = pos;
        final hl = ByteData.sublistView(await f.read(4)).getUint32(0);
        final header = _Pb(await f.read(hl));
        var type = '';
        var size = 0;
        while (header.more) {
          switch (header.key()) {
            case (1, 2):
              type = utf8.decode(header.bytes());
            case (3, 0):
              size = header.varint();
            case (_, final w):
              header.skip(w);
          }
        }
        pos += 4 + hl + size;
        if (type == 'OSMHeader') {
          _readHeader(_blob(await f.read(size)));
        } else if (type == 'OSMData' && (wantBlock == null || wantBlock(blockStart))) {
          onBlock(blockStart, PbfBlock._(_blob(await f.read(size))));
        } else {
          await f.setPosition(pos);
        }
      }
    } finally {
      await f.close();
    }
  }

  void _readHeader(Uint8List b) {
    final p = _Pb(b);
    while (p.more) {
      switch (p.key()) {
        case (32, 0):
          timestamp = p.varint();
        case (_, final w):
          p.skip(w);
      }
    }
  }

  static Uint8List _blob(Uint8List b) {
    final p = _Pb(b);
    Uint8List? raw, zlib;
    while (p.more) {
      switch (p.key()) {
        case (1, 2):
          raw = p.bytes();
        case (3, 2):
          zlib = p.bytes();
        case (_, final w):
          p.skip(w);
      }
    }
    if (raw != null) return raw;
    if (zlib != null) return Uint8List.fromList(ZLibCodec().decode(zlib));
    throw const FormatException('Unsupported PBF blob compression (only raw and zlib)');
  }
}

/// One decoded primitive block: lazily iterates its nodes, ways and relations.
class PbfBlock {
  final List<String> strings = [];
  int _granularity = 100, _latOff = 0, _lonOff = 0;
  final List<Uint8List> _groups = [];

  PbfBlock._(Uint8List b) {
    final p = _Pb(b);
    while (p.more) {
      switch (p.key()) {
        case (1, 2):
          final st = _Pb(p.bytes());
          while (st.more) {
            switch (st.key()) {
              case (1, 2):
                strings.add(utf8.decode(st.bytes(), allowMalformed: true));
              case (_, final w):
                st.skip(w);
            }
          }
        case (2, 2):
          _groups.add(p.bytes());
        case (17, 0):
          _granularity = p.varint();
        case (19, 0):
          _latOff = p.varint();
        case (20, 0):
          _lonOff = p.varint();
        case (_, final w):
          p.skip(w);
      }
    }
  }

  /// Degrees ×1e7 from a raw PBF coordinate.
  int _e7(int raw, int off) => (off + _granularity * raw) ~/ 100;

  bool get hasNodes => _groupFields.contains(1) || _groupFields.contains(2);
  bool get hasWays => _groupFields.contains(3);
  bool get hasRelations => _groupFields.contains(4);

  late final Set<int> _groupFields = {
    for (final g in _groups)
      for (final f in _fieldsOf(g)) f,
  };

  static Iterable<int> _fieldsOf(Uint8List g) sync* {
    final p = _Pb(g);
    while (p.more) {
      final (f, w) = p.key();
      yield f;
      p.skip(w);
    }
  }

  /// Every node as (id, lat ×1e7, lon ×1e7). Tags are not decoded (roads don't need node tags).
  void nodes(void Function(int id, int lat, int lon) on) {
    for (final g in _groups) {
      final p = _Pb(g);
      while (p.more) {
        switch (p.key()) {
          case (1, 2):
            final n = _Pb(p.bytes());
            var id = 0, lat = 0, lon = 0;
            while (n.more) {
              switch (n.key()) {
                case (1, 0):
                  id = n.sint();
                case (8, 0):
                  lat = n.sint();
                case (9, 0):
                  lon = n.sint();
                case (_, final w):
                  n.skip(w);
              }
            }
            on(id, _e7(lat, _latOff), _e7(lon, _lonOff));
          case (2, 2):
            final d = _Pb(p.bytes());
            List<int> ids = const [], lats = const [], lons = const [];
            while (d.more) {
              switch (d.key()) {
                case (1, 2):
                  ids = d.packedSint();
                case (8, 2):
                  lats = d.packedSint();
                case (9, 2):
                  lons = d.packedSint();
                case (_, final w):
                  d.skip(w);
              }
            }
            var id = 0, lat = 0, lon = 0;
            for (var i = 0; i < ids.length; i++) {
              id += ids[i];
              lat += lats[i];
              lon += lons[i];
              on(id, _e7(lat, _latOff), _e7(lon, _lonOff));
            }
          case (_, final w):
            p.skip(w);
        }
      }
    }
  }

  /// Every way as (id, tags, node ids).
  void ways(void Function(int id, Map<String, String> tags, List<int> refs) on) {
    for (final g in _groups) {
      final p = _Pb(g);
      while (p.more) {
        switch (p.key()) {
          case (3, 2):
            final w = _Pb(p.bytes());
            var id = 0;
            List<int> keys = const [], vals = const [], refs = const [];
            while (w.more) {
              switch (w.key()) {
                case (1, 0):
                  id = w.varint();
                case (2, 2):
                  keys = w.packed();
                case (3, 2):
                  vals = w.packed();
                case (8, 2):
                  refs = w.packedSint();
                case (_, final wt):
                  w.skip(wt);
              }
            }
            for (var i = 1; i < refs.length; i++) {
              refs[i] += refs[i - 1];
            }
            on(id, {for (var i = 0; i < keys.length; i++) strings[keys[i]]: strings[vals[i]]}, refs);
          case (_, final wt):
            p.skip(wt);
        }
      }
    }
  }

  /// Every relation as (id, tags, members as (type 0 node / 1 way / 2 relation, id, role)).
  void relations(void Function(int id, Map<String, String> tags, List<(int, int, String)> members) on) {
    for (final g in _groups) {
      final p = _Pb(g);
      while (p.more) {
        switch (p.key()) {
          case (4, 2):
            final r = _Pb(p.bytes());
            var id = 0;
            List<int> keys = const [], vals = const [], roles = const [], mem = const [], types = const [];
            while (r.more) {
              switch (r.key()) {
                case (1, 0):
                  id = r.varint();
                case (2, 2):
                  keys = r.packed();
                case (3, 2):
                  vals = r.packed();
                case (8, 2):
                  roles = r.packed();
                case (9, 2):
                  mem = r.packedSint();
                case (10, 2):
                  types = r.packed();
                case (_, final wt):
                  r.skip(wt);
              }
            }
            var mid = 0;
            final members = <(int, int, String)>[];
            for (var i = 0; i < mem.length; i++) {
              mid += mem[i];
              members.add((types[i], mid, strings[roles[i]]));
            }
            on(id, {for (var i = 0; i < keys.length; i++) strings[keys[i]]: strings[vals[i]]}, members);
          case (_, final wt):
            p.skip(wt);
        }
      }
    }
  }
}

/// Protobuf wire-format cursor.
class _Pb {
  final Uint8List b;
  int pos = 0;
  _Pb(this.b);

  bool get more => pos < b.length;

  (int, int) key() {
    final k = varint();
    return (k >> 3, k & 7);
  }

  int varint() {
    var r = 0, shift = 0;
    while (true) {
      final c = b[pos++];
      r |= (c & 0x7F) << shift;
      if (c < 0x80) return r;
      shift += 7;
    }
  }

  int sint() {
    final v = varint();
    return (v >>> 1) ^ -(v & 1);
  }

  Uint8List bytes() {
    final n = varint();
    final v = Uint8List.sublistView(b, pos, pos + n);
    pos += n;
    return v;
  }

  List<int> packed() {
    final sub = _Pb(bytes());
    final out = <int>[];
    while (sub.more) {
      out.add(sub.varint());
    }
    return out;
  }

  List<int> packedSint() {
    final sub = _Pb(bytes());
    final out = <int>[];
    while (sub.more) {
      out.add(sub.sint());
    }
    return out;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        pos += 8;
      case 2:
        // Read the length first: `pos += varint()` would add it to the position before the varint.
        final n = varint();
        pos += n;
      case 5:
        pos += 4;
      default:
        throw FormatException('Bad protobuf wire type $wire');
    }
  }
}
