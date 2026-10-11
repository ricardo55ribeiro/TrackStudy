import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android returns content URIs, not writable filesystem paths. Use its system
/// document creator; keep the existing desktop save dialog and file semantics.
Future<bool> saveJsonFile(String data, String name) async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return await const MethodChannel(
          'dev.trackstudy/files',
        ).invokeMethod<bool>('saveJson', {'name': name, 'data': data}) ??
        false;
  }
  final destination = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: [
      const XTypeGroup(label: 'JSON backup', extensions: ['json']),
    ],
  );
  if (destination == null) return false;
  await File(destination.path).writeAsString(data, flush: true);
  return true;
}
