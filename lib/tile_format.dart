import 'dart:convert';
import 'dart:typed_data';

/// Bump when the layout below changes; the app refuses tiles of another version.
const tileFormat = 1;
const tileMagic = 0x42525431; // "BRT1"

/// One tile's roads, ready to write. Every way touching the tile is included whole (with its nodes outside the
/// tile), so the app can join tiles by OSM ids.
///
/// Layout (little-endian, each array padded to 4 bytes, whole file gzipped):
///   Int32 header: magic, format, nodes, ways, refs, restrictions, names, nameBytes
///   Int64 nodeIds[nodes] (sorted), Int32 lat[nodes], Int32 lon[nodes] (degrees ×1e7)
///   Int64 wayIds[ways], Int32 refStart[ways+1], Int32 refs[refs] (index into nodes, -1 = node missing)
///   Uint8 kind[ways], Uint8 speed[ways], Uint8 flags[ways], Int8 dir[ways], Int32 name[ways] (-1 = none)
///   Int32 restrFrom[r], Int32 restrVia[r], Int32 restrTo[r] (way, node, way indexes), Uint8 restrOnly[r]
///   UTF-8 names joined by '\n'
class TileData {
  final Int64List nodeIds;
  final Int32List lat, lon;
  final Int64List wayIds;
  final Int32List refStart, refs, name;
  final Uint8List kind, speed, flags;
  final Int8List dir;
  final Int32List restrFrom, restrVia, restrTo;
  final Uint8List restrOnly;
  final List<String> names;

  TileData({
    required this.nodeIds,
    required this.lat,
    required this.lon,
    required this.wayIds,
    required this.refStart,
    required this.refs,
    required this.kind,
    required this.speed,
    required this.flags,
    required this.dir,
    required this.name,
    required this.restrFrom,
    required this.restrVia,
    required this.restrTo,
    required this.restrOnly,
    required this.names,
  });

  Uint8List toBytes() {
    final nameBytes = utf8.encode(names.join('\n'));
    final parts = <TypedData>[
      Int32List.fromList([tileMagic, tileFormat, nodeIds.length, wayIds.length, refs.length, restrOnly.length, names.length, nameBytes.length]),
      nodeIds, lat, lon, wayIds, refStart, refs, kind, speed, flags, dir, name, restrFrom, restrVia, restrTo, restrOnly, nameBytes,
    ];
    final out = BytesBuilder(copy: false);
    for (final p in parts) {
      out.add(p.buffer.asUint8List(p.offsetInBytes, p.lengthInBytes));
      final pad = (4 - p.lengthInBytes % 4) % 4;
      if (pad > 0) out.add(Uint8List(pad));
    }
    return out.takeBytes();
  }
}
