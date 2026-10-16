import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/api_exception.dart';

final profilePhotoServiceProvider = Provider((ref) => ProfilePhotoService());

class ProfilePhotoService {
  Future<String?> pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null) throw const ApiException('Không đọc được ảnh đã chọn.');
    return prepare(path);
  }

  Future<String> prepare(String path) async {
    final original = File(path);
    if (await original.length() > 10_000_000) {
      throw const ApiException('Vui lòng chọn ảnh tối đa 10 MB.');
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decoded;
    ui.Image? square;
    ui.Picture? picture;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(
        await original.readAsBytes(),
      );
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final scale = math.min(
        1.0,
        1024 / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      decoded = (await codec.getNextFrame()).image;
      final edge = math.min(decoded.width, decoded.height).toDouble();
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        decoded,
        ui.Rect.fromLTWH(
          (decoded.width - edge) / 2,
          (decoded.height - edge) / 2,
          edge,
          edge,
        ),
        const ui.Rect.fromLTWH(0, 0, 512, 512),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      picture = recorder.endRecording();
      square = await picture.toImage(512, 512);
      final png = await square.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) {
        throw const ApiException(
          'Không xử lý được ảnh. Vui lòng chọn ảnh khác.',
        );
      }
      final directory = Directory(
        '${(await getTemporaryDirectory()).path}/profile-drafts',
      );
      await directory.create(recursive: true);
      final file = File('${directory.path}/${const Uuid().v4()}.png');
      await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
      return file.path;
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('Ảnh chưa được hỗ trợ. Vui lòng chọn ảnh khác.');
    } finally {
      square?.dispose();
      picture?.dispose();
      decoded?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<void> discard(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // The OS may already have cleared this temporary draft.
    }
  }
}
