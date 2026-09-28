import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Absolute paths of every sherpa-onnx model file. Valid after
/// [SherpaModelManager.ensureModels] completes.
class SherpaModelPaths {
  final String kwsEncoder;
  final String kwsDecoder;
  final String kwsJoiner;
  final String kwsTokens;
  final String sttPreprocessor;
  final String sttEncoder;
  final String sttUncachedDecoder;
  final String sttCachedDecoder;
  final String sttTokens;

  const SherpaModelPaths({
    required this.kwsEncoder,
    required this.kwsDecoder,
    required this.kwsJoiner,
    required this.kwsTokens,
    required this.sttPreprocessor,
    required this.sttEncoder,
    required this.sttUncachedDecoder,
    required this.sttCachedDecoder,
    required this.sttTokens,
  });
}

/// Downloads (on first run) and extracts the two sherpa-onnx model bundles
/// into the app support directory, so the APK stays small (~no bundled
/// models) and the phone fetches ~120 MB once.
///
/// Bundles (verified file layouts, Sept 2026):
/// - KWS: sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01 (full fp32;
///   the -mobile int8 variant hard-crashes the process with SIGABRT in
///   Reshape /downsample/Reshape_1 during streaming decode on-device)
/// - STT: sherpa-onnx-moonshine-tiny-en-int8
class SherpaModelManager {
  static const kwsUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/'
      'sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2';
  static const sttUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
      'sherpa-onnx-moonshine-tiny-en-int8.tar.bz2';

  static const _kwsTopDir =
      'sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01';
  static const _sttTopDir = 'sherpa-onnx-moonshine-tiny-en-int8';

  /// Exact filenames inside the KWS tarball (verified from the release).
  static const _kwsFiles = <String>[
    'encoder-epoch-12-avg-2-chunk-16-left-64.onnx',
    'decoder-epoch-12-avg-2-chunk-16-left-64.onnx',
    'joiner-epoch-12-avg-2-chunk-16-left-64.onnx',
    'tokens.txt',
  ];

  /// Exact filenames inside the Moonshine tarball (verified from release).
  static const _sttFiles = <String>[
    'preprocess.onnx',
    'encode.int8.onnx',
    'uncached_decode.int8.onnx',
    'cached_decode.int8.onnx',
    'tokens.txt',
  ];

  static String? _baseDir;

  static Future<String> _modelsDir() async {
    if (_baseDir != null) return _baseDir!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/sherpa_models');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _baseDir = dir.path;
  }

  /// Ensure both model bundles are on disk. Downloads + extracts only the
  /// bundles with missing files. Returns absolute paths for the engine.
  static Future<SherpaModelPaths> ensureModels({
    void Function(String stage, int downloadedBytes, int totalBytes)?
        onProgress,
  }) async {
    final base = await _modelsDir();

    if (_kwsFiles.any((f) => !File('$base/$_kwsTopDir/$f').existsSync())) {
      await _downloadAndExtract(
        url: kwsUrl,
        baseDir: base,
        topDir: _kwsTopDir,
        wanted: _kwsFiles,
        stage: 'kws',
        onProgress: onProgress,
      );
    } else {
      debugPrint('SherpaModelManager: KWS models cached');
    }

    if (_sttFiles.any((f) => !File('$base/$_sttTopDir/$f').existsSync())) {
      await _downloadAndExtract(
        url: sttUrl,
        baseDir: base,
        topDir: _sttTopDir,
        wanted: _sttFiles,
        stage: 'stt',
        onProgress: onProgress,
      );
    } else {
      debugPrint('SherpaModelManager: STT models cached');
    }

    return SherpaModelPaths(
      kwsEncoder: '$base/$_kwsTopDir/${_kwsFiles[0]}',
      kwsDecoder: '$base/$_kwsTopDir/${_kwsFiles[1]}',
      kwsJoiner: '$base/$_kwsTopDir/${_kwsFiles[2]}',
      kwsTokens: '$base/$_kwsTopDir/${_kwsFiles[3]}',
      sttPreprocessor: '$base/$_sttTopDir/${_sttFiles[0]}',
      sttEncoder: '$base/$_sttTopDir/${_sttFiles[1]}',
      sttUncachedDecoder: '$base/$_sttTopDir/${_sttFiles[2]}',
      sttCachedDecoder: '$base/$_sttTopDir/${_sttFiles[3]}',
      sttTokens: '$base/$_sttTopDir/${_sttFiles[4]}',
    );
  }

  static Future<void> _downloadAndExtract({
    required String url,
    required String baseDir,
    required String topDir,
    required List<String> wanted,
    required String stage,
    void Function(String stage, int downloadedBytes, int totalBytes)?
        onProgress,
  }) async {
    debugPrint('SherpaModelManager: downloading $stage models...');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException(
          'Model download failed: HTTP ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }
      final total = response.contentLength;
      final builder = BytesBuilder();
      var done = 0;
      var lastReported = 0;
      await for (final chunk in response) {
        builder.add(chunk);
        done += chunk.length;
        if (onProgress != null &&
            (done - lastReported > 1024 * 1024 || done == total)) {
          lastReported = done;
          onProgress(stage, done, total);
        }
      }
      debugPrint(
        'SherpaModelManager: $stage downloaded '
        '${(done / 1024 / 1024).toStringAsFixed(1)} MB, extracting...',
      );

      Uint8List compressed = builder.toBytes();
      Uint8List tarBytes = BZip2Decoder().decodeBytes(compressed);
      // Release the compressed buffer before the tar decode doubles memory.
      compressed = Uint8List(0);
      final archive = TarDecoder().decodeBytes(tarBytes);
      tarBytes = Uint8List(0);

      final wantedSet = wanted.map((f) => '$topDir/$f').toSet();
      final found = <String>{};
      for (final file in archive.files) {
        if (!file.isFile) continue;
        if (!wantedSet.contains(file.name)) continue;
        final content = file.content;
        if (content.isEmpty) continue;
        final out = File('$baseDir/${file.name}');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(content);
        found.add(file.name);
      }
      final missing =
          wantedSet.difference(found).toList(growable: false);
      if (missing.isNotEmpty) {
        throw StateError(
          'Model bundle $stage missing files after extract: $missing',
        );
      }
      debugPrint('SherpaModelManager: $stage models ready');
    } finally {
      client.close();
    }
  }
}
