import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/http/h2/h2_codec.dart';
import 'package:proxypin/network/http/h2/hpack/hpack.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/byte_buf.dart';

const _maxFrame = Http2Codec.maxFrameSize;
const _data = 0, _headers = 1, _rstStream = 3;
const _endStream = 1, _endHeaders = 4;

List<int> _frame(int type, int flags, int stream, List<int> payload) => [
      payload.length >> 16,
      (payload.length >> 8) & 255,
      payload.length & 255,
      type,
      flags,
      (stream >> 24) & 127,
      (stream >> 16) & 255,
      (stream >> 8) & 255,
      stream & 255,
      ...payload,
    ];

Uint8List _pattern(int length, [int seed = 0]) => Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed) & 255));

/// Parses (type, flags, payload) out of an encoded byte stream.
List<(int, int, List<int>)> _parseFrames(List<int> bytes) {
  final frames = <(int, int, List<int>)>[];
  var offset = 0;
  while (offset < bytes.length) {
    final length = (bytes[offset] << 16) | (bytes[offset + 1] << 8) | bytes[offset + 2];
    frames.add((bytes[offset + 3], bytes[offset + 4], bytes.sublist(offset + 9, offset + 9 + length)));
    offset += 9 + length;
  }
  return frames;
}

void main() {
  group('h2 body decode', () {
    late ChannelContext context;
    late Http2ResponseDecoder decoder;
    late HPackEncoder hpack;

    setUp(() {
      context = ChannelContext();
      decoder = Http2ResponseDecoder();
      hpack = HPackEncoder();
    });

    void open(int stream) {
      context.putStreamRequest(stream, HttpRequest(HttpMethod.get, '/$stream'));
      final block = hpack.encode([Header.ascii(':status', '200')]);
      final result = decoder.decode(context, ByteBuf(_frame(_headers, _endHeaders, stream, block)));
      expect(result.isDone, isFalse);
    }

    test('joins a body split over many DATA frames', () {
      open(1);
      final body = _pattern(_maxFrame * 40 + 123);

      final wire = ByteBuf();
      for (var offset = 0; offset < body.length; offset += _maxFrame) {
        final end = offset + _maxFrame < body.length ? offset + _maxFrame : body.length;
        wire.add(_frame(_data, end == body.length ? _endStream : 0, 1, body.sublist(offset, end)));
      }

      final result = decoder.decode(context, wire);
      expect(result.isDone, isTrue);
      expect(result.data!.body, body);
      expect(result.data!.packageSize, greaterThanOrEqualTo(body.length));
    });

    test('keeps interleaved streams apart', () {
      open(1);
      open(3);
      final a = _pattern(_maxFrame * 2, 1), b = _pattern(_maxFrame + 9, 2);

      expect(decoder.decode(context, ByteBuf(_frame(_data, 0, 1, a.sublist(0, _maxFrame)))).isDone, isFalse);
      expect(decoder.decode(context, ByteBuf(_frame(_data, 0, 3, b.sublist(0, _maxFrame)))).isDone, isFalse);

      final done3 = decoder.decode(context, ByteBuf(_frame(_data, _endStream, 3, b.sublist(_maxFrame))));
      expect(done3.data!.body, b);

      final done1 = decoder.decode(context, ByteBuf(_frame(_data, _endStream, 1, a.sublist(_maxFrame))));
      expect(done1.data!.body, a);
    });

    test('an empty DATA frame still yields an empty body, as before', () {
      open(1);
      final result = decoder.decode(context, ByteBuf(_frame(_data, _endStream, 1, [])));
      expect(result.isDone, isTrue);
      expect(result.data!.body, isEmpty);
    });

    test('strips padding from every frame', () {
      open(1);
      const padded = 8;
      final payload = [3, 1, 2, 3, 0, 0, 0];

      expect(decoder.decode(context, ByteBuf(_frame(_data, padded, 1, payload))).isDone, isFalse);
      final result = decoder.decode(context, ByteBuf(_frame(_data, padded | _endStream, 1, payload)));
      expect(result.data!.body, [1, 2, 3, 1, 2, 3]);
    });

    test('a reset stream leaves nothing behind for a later body on the same id', () {
      open(1);
      decoder.decode(context, ByteBuf(_frame(_data, 0, 1, [1, 2, 3])));
      decoder.decode(context, ByteBuf(_frame(_rstStream, 0, 1, [0, 0, 0, 8])));

      open(1);
      final result = decoder.decode(context, ByteBuf(_frame(_data, _endStream, 1, [9])));
      expect(result.data!.body, [9]);
    });
  });

  group('h2 body encode', () {
    List<(int, int, List<int>)> encodeData(List<int> body) {
      final response = HttpResponse(HttpStatus.ok, protocolVersion: 'HTTP/2')
        ..streamId = 1
        ..body = body;
      final bytes = Http2ResponseDecoder().encode(ChannelContext(), response);
      return _parseFrames(bytes).where((frame) => frame.$1 == _data).toList();
    }

    void expectBody(List<(int, int, List<int>)> frames, List<int> body) {
      expect(frames.expand((frame) => frame.$3).toList(), body);
      for (final frame in frames.take(frames.length - 1)) {
        expect(frame.$2 & _endStream, 0);
        expect(frame.$3.length, _maxFrame);
      }
      expect(frames.last.$2 & _endStream, _endStream);
    }

    for (final (name, length, frameCount) in [
      ('smaller than a frame', 10, 1),
      ('exactly one frame', _maxFrame, 1),
      ('one byte over a frame', _maxFrame + 1, 2),
      ('exactly two frames', _maxFrame * 2, 2),
      ('many frames with a tail', _maxFrame * 30 + 5, 31),
    ]) {
      test('splits a body $name', () {
        final body = _pattern(length);
        final frames = encodeData(body);
        expect(frames, hasLength(frameCount));
        expectBody(frames, body);
      });
    }

    test('accepts a body that is not a Uint8List', () {
      final body = _pattern(_maxFrame + 7).toList(growable: true);
      expectBody(encodeData(body), body);
    });

    test('a body decoded from frames survives re-encoding', () {
      final context = ChannelContext()..putStreamRequest(1, HttpRequest(HttpMethod.get, '/'));
      final decoder = Http2ResponseDecoder();
      final block = HPackEncoder().encode([Header.ascii(':status', '200')]);
      decoder.decode(context, ByteBuf(_frame(_headers, _endHeaders, 1, block)));
      decoder.decode(context, ByteBuf(_frame(_data, 0, 1, _pattern(_maxFrame))));
      final done = decoder.decode(context, ByteBuf(_frame(_data, _endStream, 1, _pattern(_maxFrame ~/ 2))));

      final expected = [..._pattern(_maxFrame), ..._pattern(_maxFrame ~/ 2)];
      expectBody(encodeData(done.data!.body!), expected);
    });
  });
}
