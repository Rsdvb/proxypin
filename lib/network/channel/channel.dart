/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/components/manager/client_cert_manager.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/socket_address.dart';

import 'channel_dispatcher.dart';

///处理I/O事件或截获I/O操作
///[T] 读取的数据类型
///@author wanghongen
abstract class ChannelHandler<T> {
  var log = logger;

  ///连接建立
  void channelActive(ChannelContext context, Channel channel) {}

  ///读取数据事件
  Future<void> channelRead(ChannelContext channelContext, Channel channel, T msg) async {}

  ///连接断开
  void channelInactive(ChannelContext channelContext, Channel channel) {
    //log.i("[${channel.id}] close $channel");
  }

  void exceptionCaught(ChannelContext channelContext, Channel channel, dynamic error, {StackTrace? trace}) {
    HostAndPort? host = channelContext.host;
    log.e("[${channel.id}] exceptionCaught $host $channel", error: error, stackTrace: trace);
    channel.close();
  }
}

///与网络套接字或组件的连接，能够进行读、写、连接和绑定等I/O操作。
class Channel {
  /// 待写出的数据超过该字节数时，暂停读取数据来源，等写出后再恢复
  static const int writeHighWaterMark = 2 * 1024 * 1024;

  final int _id;
  final ChannelDispatcher dispatcher = ChannelDispatcher();
  Socket _socket;
  StreamSubscription<Uint8List>? _readSubscription;
  int _unflushedBytes = 0;
  Future<void>? _flushing;

  //是否打开
  bool isOpen = true;

  //此通道连接到的远程地址
  final InetSocketAddress remoteSocketAddress;

  //是否写入中
  bool isWriting = false;

  Object? error; //异常
  //是否使用代理
  bool useProxy = false;

  Channel(this._socket)
      : _id = DateTime.now().millisecondsSinceEpoch + Random().nextInt(999999),
        remoteSocketAddress = InetSocketAddress(_socket.remoteAddress, _socket.remotePort);

  ///返回此channel的全局唯一标识符。
  late final String id = _id.toRadixString(36);

  Socket get socket => _socket;

  /// 当前读取 [socket] 的订阅，[throttle] 通过它暂停读取
  set readSubscription(StreamSubscription<Uint8List> subscription) => _readSubscription = subscription;

  void serverSecureSocket(SecureSocket secureSocket, ChannelContext channelContext) {
    _socket = secureSocket;
    _socket.done.then((value) => isOpen = false, onError: (_) => isOpen = false);
    dispatcher.listen(this, channelContext);
  }

  //向远程发起ssl连接
  Future<SecureSocket> secureSocket(ChannelContext channelContext,
      {String? host, List<String>? supportedProtocols}) async {
    SecurityContext? context = await ClientCertManager.securityContextForHost(host);
    SecureSocket secureSocket = await SecureSocket.secure(socket,
        host: host, context: context, supportedProtocols: supportedProtocols, onBadCertificate: (certificate) => true);

    _socket = secureSocket;
    //done 以错误完成时（如 Broken pipe）也要置位关闭；不挂 onError 这条派生 Future 会冒到 VM 顶层
    _socket.done.then((value) => isOpen = false, onError: (_) => isOpen = false);
    dispatcher.listen(this, channelContext);

    return secureSocket;
  }

  Future<SecureSocket> startSecureSocket(ChannelContext channelContext,
      {String? host, List<String>? supportedProtocols}) async {
    SecurityContext? context = await ClientCertManager.securityContextForHost(host);
    SecureSocket secureSocket = await SecureSocket.secure(socket,
        host: host, context: context, supportedProtocols: supportedProtocols, onBadCertificate: (certificate) => true);

    _socket = secureSocket;
    //done 以错误完成时（如 Broken pipe）也要置位关闭；不挂 onError 这条派生 Future 会冒到 VM 顶层
    _socket.done.then((value) => isOpen = false, onError: (_) => isOpen = false);
    return secureSocket;
  }

  void listen(ChannelContext channelContext) {
    dispatcher.listen(this, channelContext);
  }

  String? get selectedProtocol => isSsl && isOpen ? (_socket as SecureSocket).selectedProtocol : null;

  ///是否是ssl链接
  bool get isSsl => _socket is SecureSocket;

  ///远程服务器证书(仅ssl链接有效)
  X509Certificate? get peerCertificate => _socket is SecureSocket ? (_socket as SecureSocket).peerCertificate : null;

  Future<void> write(ChannelContext channelContext, Object obj) async {
    var data = dispatcher.encoder.encode(channelContext, obj);
    await writeBytes(data);
  }

  Future<void> writeBytes(List<int> bytes) async {
    if (isClosed) {
      logger.w("[$id] $remoteSocketAddress channel is closed", stackTrace: StackTrace.current);
    }

    // flush 期间 socket 不接受写入
    while (_flushing != null) {
      await _flushing;
    }

    //只能有一个写入
    int retry = 0;
    while (isWriting && retry++ < 30) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (isWriting) {
      logger.d("[$id] write busy");
    }

    isWriting = true;
    try {
      if (!isClosed) {
        _socket.add(bytes);
        _unflushedBytes += bytes.length;
      }
    } catch (e, t) {
      if (e is StateError && e.message == "StreamSink is closed") {
        logger.w("[$id] $remoteSocketAddress write error channel is closed $e", stackTrace: t);
      } else {
        logger.e("[$id] write error", error: e, stackTrace: t);
      }
    } finally {
      isWriting = false;
    }
  }

  /// 本通道写不过来时暂停读取 [source]，等已写入的数据写出后恢复。
  /// socket 写入没有上限，快的一端读多少就在内存里堆多少，大文件遇到慢客户端会撑爆内存。
  Future<void> throttle(Channel source) async {
    if (_unflushedBytes < writeHighWaterMark || isClosed) {
      return;
    }

    source._readSubscription?.pause();
    try {
      await _flush();
    } finally {
      source._readSubscription?.resume();
    }
  }

  Future<void> _flush() async {
    while (_flushing != null) {
      await _flushing;
    }

    final done = Completer<void>();
    _flushing = done.future;
    try {
      await _socket.flush();
    } catch (_) {
      // 连接已断开，关闭流程由读事件一侧处理
    } finally {
      _flushing = null;
      _unflushedBytes = 0;
      done.complete();
    }
  }

  ///写入并关闭此channel
  Future<void> writeAndClose(ChannelContext channelContext, Object obj) async {
    await write(channelContext, obj);
    close();
  }

  ///关闭此channel
  void close() async {
    if (isClosed) {
      return;
    }

    //写入中，延迟关闭
    int retry = 0;
    while (isWriting && retry++ < 10) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
    isOpen = false;
    // flush 期间 socket 不接受关闭
    while (_flushing != null) {
      await _flushing;
    }
    // if (!isWriting) {
    //   await _socket.flush();
    // }
    await _socket.close();
    // _socket.destroy();
  }

  ///返回此channel是否打开
  bool get isClosed => !isOpen;

  @override
  String toString() {
    return 'Channel($id $remoteSocketAddress';
  }
}
