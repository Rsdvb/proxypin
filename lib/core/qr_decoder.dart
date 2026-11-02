import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// 从图片里读二维码。不依赖相机和平台插件，手机和 Windows 用同一份代码
class QrDecoder {
  /// 没有二维码或读不出来时返回 null。解码慢，放在后台执行
  static Future<String?> decode(Uint8List bytes) => compute(_decode, bytes);

  static String? _decode(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) return null;
    final source = _luminance(image);
    // 混合二值化对截图效果好，纯黑白的图片用全局的更稳
    for (final bitmap in [BinaryBitmap(HybridBinarizer(source)), BinaryBitmap(GlobalHistogramBinarizer(source))]) {
      try {
        return QRCodeReader().decode(bitmap).text;
      } on ReaderException {
        // 换一种二值化再试
      }
    }
    return null;
  }

  static RGBLuminanceSource _luminance(img.Image image) {
    final pixels = Int32List(image.width * image.height);
    var index = 0;
    for (final pixel in image.convert(format: img.Format.uint8, numChannels: 4)) {
      pixels[index++] = (pixel.a.toInt() << 24) | (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt();
    }
    return RGBLuminanceSource(image.width, image.height, pixels);
  }

  /// Windows：截整个屏幕，二维码在哪都能找到，不用框选
  static Future<Uint8List?> captureScreen() async {
    final directory = await Directory.systemTemp.createTemp('rsproxy_screen_');
    final file = File('${directory.path}${Platform.pathSeparator}screen.png');
    try {
      final result = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', _captureScript(file.path)]);
      return result.exitCode == 0 && await file.exists() ? await file.readAsBytes() : null;
    } finally {
      await directory.delete(recursive: true);
    }
  }

  static String _captureScript(String path) => '''
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
\$screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
\$bitmap = New-Object System.Drawing.Bitmap \$screen.Width, \$screen.Height
\$graphics = [System.Drawing.Graphics]::FromImage(\$bitmap)
\$graphics.CopyFromScreen(\$screen.Left, \$screen.Top, 0, 0, \$bitmap.Size)
\$bitmap.Save('$path', [System.Drawing.Imaging.ImageFormat]::Png)
''';
}
