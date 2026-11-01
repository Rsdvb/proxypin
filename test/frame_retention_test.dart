import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';

WebSocketFrame _frame(int id, {int size = 8}) {
  final payload = Uint8List(size);
  payload.buffer.asByteData().setInt32(0, id);
  return WebSocketFrame(fin: true, opcode: 2, mask: false, payloadLength: size, maskingKey: 0, payloadData: payload);
}

int _id(WebSocketFrame frame) => frame.payloadData.buffer.asByteData().getInt32(0);

void main() {
  test('frames below the limits are all kept', () {
    final request = HttpRequest(HttpMethod.get, '/ws');
    for (var i = 0; i < 100; i++) {
      request.addFrame(_frame(i));
    }
    expect(request.messages, hasLength(100));
  });

  test('the frame count stays bounded and keeps the newest frames', () {
    final request = HttpRequest(HttpMethod.get, '/ws');
    const total = HttpMessage.maxRetainedFrames * 3;
    for (var i = 0; i < total; i++) {
      request.addFrame(_frame(i));
      expect(request.messages.length, lessThanOrEqualTo(HttpMessage.maxRetainedFrames));
    }
    expect(_id(request.messages.last), total - 1);
    for (var i = 1; i < request.messages.length; i++) {
      expect(_id(request.messages[i]), _id(request.messages[i - 1]) + 1);
    }
  });

  test('payload bytes stay bounded', () {
    final response = HttpResponse(HttpStatus.ok);
    const size = 1024 * 1024;
    const total = HttpMessage.maxRetainedFrameBytes ~/ size * 3;
    for (var i = 0; i < total; i++) {
      response.addFrame(_frame(i, size: size));
      final bytes = response.messages.fold<int>(0, (sum, frame) => sum + frame.payloadData.length);
      expect(bytes, lessThanOrEqualTo(HttpMessage.maxRetainedFrameBytes));
    }
    expect(_id(response.messages.last), total - 1);
  });

  test('a single frame over the byte limit is kept', () {
    final response = HttpResponse(HttpStatus.ok);
    response.addFrame(_frame(1));
    response.addFrame(_frame(2, size: HttpMessage.maxRetainedFrameBytes + 1));
    expect(response.messages.map(_id), [2]);
  });
}
