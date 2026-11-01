/*
 * Copyright 2026 Hongen Wang All rights reserved.
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
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Win32 FFI bindings used to look up the local process that owns a TCP
/// socket and the executable path of a PID, without spawning child processes.
///
/// Previously this was done with `cmd /c netstat -ano | findstr` and
/// `cmd /c wmic process where ...`, both awaited on the request path before
/// the upstream connection is opened. Those cost roughly 30 ms and 300 ms per
/// lookup, against well under a millisecond here, and `wmic` no longer ships
/// by default on Windows 11 24H2.

// FFI signatures
typedef _GetExtendedTcpTableC = Uint32 Function(Pointer<Void>, Pointer<Uint32>, Int32, Uint32, Int32, Uint32);
typedef _GetExtendedTcpTableDart = int Function(Pointer<Void>, Pointer<Uint32>, int, int, int, int);

typedef _OpenProcessC = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);

typedef _QueryFullProcessImageNameC = Int32 Function(IntPtr, Uint32, Pointer<Uint16>, Pointer<Uint32>);
typedef _QueryFullProcessImageNameDart = int Function(int, int, Pointer<Uint16>, Pointer<Uint32>);

typedef _CloseHandleC = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

class WindowsProcessInfo {
  // Win32 constants (from <iprtrmib.h> / <winerror.h> / <winnt.h>)
  static const int _kAfInet = 2;
  static const int _kTcpTableOwnerPidConnections = 4;
  static const int _kErrorInsufficientBuffer = 122;
  static const int _kProcessQueryLimitedInformation = 0x1000;
  static const int _kMaxPathChars = 32768;

  // MIB_TCPTABLE_OWNER_PID layout, in DWORDs: dwNumEntries, then rows of
  // { dwState, dwLocalAddr, dwLocalPort, dwRemoteAddr, dwRemotePort, dwOwningPid }.
  static const int _kRowDwords = 6;
  static const int _kOffLocalAddr = 1;
  static const int _kOffLocalPort = 2;
  static const int _kOffOwningPid = 5;

  // The table can grow between the size query and the read.
  static const int _kInitialTableSize = 64 * 1024;
  static const int _kMaxAttempts = 4;

  static final DynamicLibrary _iphlpapi = DynamicLibrary.open('iphlpapi.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _getExtendedTcpTable =
      _iphlpapi.lookupFunction<_GetExtendedTcpTableC, _GetExtendedTcpTableDart>('GetExtendedTcpTable');
  static final _openProcess = _kernel32.lookupFunction<_OpenProcessC, _OpenProcessDart>('OpenProcess');
  static final _queryFullProcessImageName = _kernel32
      .lookupFunction<_QueryFullProcessImageNameC, _QueryFullProcessImageNameDart>('QueryFullProcessImageNameW');
  static final _closeHandle = _kernel32.lookupFunction<_CloseHandleC, _CloseHandleDart>('CloseHandle');

  /// Returns the PID that owns the connected IPv4 TCP socket whose local
  /// endpoint is [address]:[port], or null if there is none.
  ///
  /// Only local endpoints are matched, so a client on another device simply
  /// finds no row.
  static int? findPidByLocalTcpEndpoint(InternetAddress address, int port) {
    assert(Endian.host == Endian.little, 'MIB_TCPROW parsing requires little-endian host');
    if (address.type != InternetAddressType.IPv4) return null;

    // Address and port are stored in network byte order, so compare them the
    // way those bytes read back as a little-endian DWORD.
    final raw = address.rawAddress;
    final localAddr = raw[0] | raw[1] << 8 | raw[2] << 16 | raw[3] << 24;
    final localPort = (port & 0xFF) << 8 | port >> 8;

    final sizePtr = calloc<Uint32>();
    try {
      var size = _kInitialTableSize;
      for (var attempt = 0; attempt < _kMaxAttempts; attempt++) {
        final buffer = calloc<Uint8>(size);
        try {
          sizePtr.value = size;
          final status =
              _getExtendedTcpTable(buffer.cast(), sizePtr, 0, _kAfInet, _kTcpTableOwnerPidConnections, 0);
          if (status == 0) {
            return _findOwner(buffer, localAddr, localPort);
          }
          if (status != _kErrorInsufficientBuffer) {
            return null;
          }
          size = sizePtr.value + _kInitialTableSize;
        } finally {
          calloc.free(buffer);
        }
      }
      return null;
    } finally {
      calloc.free(sizePtr);
    }
  }

  static int? _findOwner(Pointer<Uint8> buffer, int localAddr, int localPort) {
    final count = buffer.cast<Uint32>().value;
    final table = buffer.cast<Uint32>().asTypedList(1 + count * _kRowDwords);

    for (var row = 1; row < table.length; row += _kRowDwords) {
      if (table[row + _kOffLocalPort] == localPort && table[row + _kOffLocalAddr] == localAddr) {
        final pid = table[row + _kOffOwningPid];
        // PID 0 marks a TIME_WAIT socket that no longer has an owner.
        return pid == 0 ? null : pid;
      }
    }
    return null;
  }

  /// Returns the absolute executable path of [pid], or null if it is not
  /// accessible (e.g. protected process, process gone).
  static String? getProcessPath(int pid) {
    final handle = _openProcess(_kProcessQueryLimitedInformation, 0, pid);
    if (handle == 0) return null;

    final buffer = calloc<Uint16>(_kMaxPathChars);
    final length = calloc<Uint32>();
    try {
      length.value = _kMaxPathChars;
      if (_queryFullProcessImageName(handle, 0, buffer, length) == 0) return null;
      return buffer.cast<Utf16>().toDartString(length: length.value);
    } finally {
      calloc.free(length);
      calloc.free(buffer);
      _closeHandle(handle);
    }
  }
}
