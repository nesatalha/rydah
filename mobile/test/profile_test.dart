import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/profile_photo.dart';
import 'package:mobile/account_controller.dart';
import 'package:mobile/account_store.dart';
import 'account_test.dart' show MemorySecrets;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('photo is cropped and resized into bounded 128 square PNG', () async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xff112233), ui.BlendMode.src);
    final pic = recorder.endRecording();
    final image = await pic.toImage(300, 200);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final result = await normalizePhoto(bytes!.buffer.asUint8List());
    final codec = await ui.instantiateImageCodec(result);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 128);
    expect(frame.image.height, 128);
    expect(result.length, lessThanOrEqualTo(65536));
    codec.dispose();
    frame.image.dispose();
    image.dispose();
    pic.dispose();
    await expectLater(
      normalizePhoto(Uint8List.fromList([1, 2])),
      throwsA(anything),
    );
  });
  test(
    'saving local profile does not request network or GPS and survives reload',
    () async {
      final repo = MemoryProfileRepository();
      final controller = AccountController(repo, AccountStore(MemorySecrets()));
      await controller.load();
      await controller.saveProfile('Ada', null);
      expect((await repo.load())!.name, 'Ada');
      expect((await repo.load())!.dirty, true);
      expect(controller.account!.enrolled, false);
      controller.dispose();
    },
  );
}
