import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

Future<String?> saveSchedulePng(Uint8List data, String name) async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return const MethodChannel(
      'dev.trackstudy/files',
    ).invokeMethod<String>('savePng', {'name': name, 'data': data});
  }
  final destination = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: [
      const XTypeGroup(label: 'PNG image', extensions: ['png']),
    ],
  );
  if (destination == null) return null;
  final file = File(destination.path);
  await file.writeAsBytes(data, flush: true);
  return file.path;
}
