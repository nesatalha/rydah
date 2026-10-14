import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;

Future<Uint8List> normalizePhoto(Uint8List source) async {
  if (source.isEmpty || source.length > 10 * 1024 * 1024) {
    throw const FormatException('Choose a photo smaller than 10 MB');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(source);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  ui.Picture? picture;
  ui.Image? output;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > 8192 ||
        descriptor.height > 8192 ||
        descriptor.width * descriptor.height > 24000000) {
      throw const FormatException('Photo dimensions are too large');
    }
    final scale = math.min(
      1.0,
      512 / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round().clamp(1, 512),
      targetHeight: (descriptor.height * scale).round().clamp(1, 512),
    );
    image = (await codec.getNextFrame()).image;
    final size = math.min(image.width, image.height).toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
        (image.width - size) / 2,
        (image.height - size) / 2,
        size,
        size,
      ),
      const ui.Rect.fromLTWH(0, 0, 128, 128),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    picture = recorder.endRecording();
    output = await picture.toImage(128, 128);
    final png = await output.toByteData(format: ui.ImageByteFormat.png);
    final bytes = png!.buffer.asUint8List();
    if (bytes.length > 65536) {
      throw const FormatException('Photo could not be reduced below 64 KiB');
    }
    return bytes;
  } finally {
    output?.dispose();
    picture?.dispose();
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
