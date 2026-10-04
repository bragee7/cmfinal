import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

/// On-device model bundle for the Zipformer keyword spotter.
///
/// KWS-ONLY (no speech-to-text stage): the spotter hears trigger WORDS
/// directly from the mic stream, so the download stays small (~13 MB) and
/// detection latency stays low. Full-fp32 CPU build — the mobile int8
/// variant SIGABRTs in Reshape/downsample, never use it.
class KwsModelPaths {
  const KwsModelPaths({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
}

typedef KwsProgress = void Function(String stage, int done, int total);

class KeywordModelManager {
  static const kwsUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/'
      'sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2';

  static const _wanted = <String>{
    'encoder-epoch-12-avg-2-chunk-16-left-64.onnx',
    'decoder-epoch-12-avg-2-chunk-16-left-64.onnx',
    'joiner-epoch-12-avg-2-chunk-16-left-64.onnx',
    'tokens.txt',
  };

  static const _encoderName = 'encoder-epoch-12-avg-2-chunk-16-left-64.onnx';
  static const _decoderName = 'decoder-epoch-12-avg-2-chunk-16-left-64.onnx';
  static const _joinerName = 'joiner-epoch-12-avg-2-chunk-16-left-64.onnx';
  static const _tokensName = 'tokens.txt';

  static Future<Directory> _bundleDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/sherpa_kws');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _p(Directory dir, String name) => '${dir.path}/$name';

  static bool _readyIn(Directory dir) {
    for (final name in _wanted) {
      if (!File(_p(dir, name)).existsSync()) return false;
    }
    return true;
  }

  static KwsModelPaths _pathsIn(Directory dir) => KwsModelPaths(
        encoder: _p(dir, _encoderName),
        decoder: _p(dir, _decoderName),
        joiner: _p(dir, _joinerName),
        tokens: _p(dir, _tokensName),
      );

  /// Previously downloaded bundle, or null when nothing is cached yet
  /// (first run — the background isolate downloads it on toggle-ON).
  static Future<KwsModelPaths?> cachedPaths() async {
    final dir = await _bundleDir();
    if (!_readyIn(dir)) return null;
    return _pathsIn(dir);
  }

  static Future<KwsModelPaths> ensureBundle({KwsProgress? onProgress}) async {
    final dir = await _bundleDir();

    String p(String name) => _p(dir, name);

    bool ready() => _readyIn(dir);

    KwsModelPaths paths() => _pathsIn(dir);

    // Cached from a previous run — no download, instant start.
    if (ready()) return paths();

    final tmp = File('${dir.path}/bundle.tar.bz2');
    try {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(kwsUrl));
        final resp = await req.close();
        if (resp.statusCode != 200) {
          throw 'KWS download HTTP ${resp.statusCode}';
        }
        final total = resp.contentLength;
        final sink = tmp.openWrite();
        int done = 0;
        await for (final chunk in resp) {
          done += chunk.length;
          sink.add(chunk);
          onProgress?.call('downloading', done, total <= 0 ? done : total);
        }
        await sink.close();
      } finally {
        client.close();
      }
      onProgress?.call('extracting', 0, 1);
      final raw = await tmp.readAsBytes();
      final tarBytes = BZip2Decoder().decodeBytes(raw);
      final archive = TarDecoder().decodeBytes(tarBytes);
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final base = entry.name.split('/').last;
        if (!_wanted.contains(base)) continue;
        await File(p(base)).writeAsBytes(entry.content as List<int>);
      }
      onProgress?.call('extracting', 1, 1);
    } finally {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }

    if (!ready()) throw 'KWS bundle incomplete after download';
    return paths();
  }

  /// First-column BPE tokens (e.g. `▁HELP`), uppercased. Used to validate
  /// custom trigger words BEFORE they reach the spotter — a word the
  /// bundle cannot tokenize could never fire, so it is rejected with a
  /// clear error instead of silently never working.
  static Future<Set<String>> loadTokenSet(String tokensPath) async {
    final lines = await File(tokensPath).readAsLines();
    final set = <String>{};
    for (final line in lines) {
      final token = line.split(' ').first.trim();
      if (token.isNotEmpty) set.add(token.toUpperCase());
    }
    return set;
  }
}
