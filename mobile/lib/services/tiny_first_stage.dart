// TinyFirstStage — Phase A harness for a microWakeWord-style TFLite first stage.
//
// Design: tiny always-on candidate detector in front of the authoritative
// sherpa KeywordSpotter. Until a trained model file lands (Phase C), the
// harness stays disabled and every call is a no-op bypass, so behavior is
// byte-identical to sherpa-only operation.
//
// Phase A (this file): full plumbing (config, init, ring buffer, energy gate,
// session inference, patience counting, candidate flag, reset/dispose) with
// `enabled: false` default. init() attempts to load the model asset; a missing
// asset (or any load/shape failure) leaves `available == false` and logs a
// bypass line. Nothing throws into the mic loop: feed() is fully guarded.
//
// Model contract (microWakeWord-compatible): single TFLite model, single audio
// input (16 kHz mono PCM; float32 or int8/uint8), single scalar score output.
// Threshold/patience semantics mirror microWakeWord manifests:
// score >= cutoff for `patience` consecutive frames => candidate.
import 'dart:async';
import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

/// Static configuration. `enabled` stays false until Phase C drops a model.
class TinyConfig {
  final String assetPath;
  final double cutoff;
  final int patience;
  final bool enabled;
  final double energyFloor;

  const TinyConfig({
    this.assetPath = 'assets/models/tiny_help_me.tflite',
    this.cutoff = 0.9,
    this.patience = 3,
    this.enabled = false,
    this.energyFloor = 0.01,
  });
}

typedef TinyLog = Future<void> Function(String tag, String msg);

class TinyFirstStage {
  static const int sampleRate = 16000;

  static bool available = false;

  static Interpreter? _interp;
  static List<int> _inShape = const [1, 1280];
  static bool _inputQuant = false;
  static double _inScale = 1.0;
  static int _inZero = 0;
  static int _inMin = 0;
  static int _inMax = 255;
  static bool _outInt = false;
  static double _outScale = 1.0;
  static int _outZero = 0;

  static TinyConfig _cfg = const TinyConfig();
  static TinyLog? _log;
  static final List<double> _ring = <double>[];
  static int _hits = 0;

  static Future<void> _l(String m) async {
    try {
      final l = _log;
      if (l != null) await l('tiny', m);
    } catch (_) {}
  }

  /// Idempotent: disposes any previous session, then (re)loads.
  static Future<void> init({
    TinyLog? log,
    TinyConfig config = const TinyConfig(),
  }) async {
    dispose();
    _cfg = config;
    _log = log;
    if (!_cfg.enabled) {
      available = false;
      await _l('first-stage disabled by config (sherpa-only bypass)');
      return;
    }
    try {
      final interp = await Interpreter.fromAsset(_cfg.assetPath);
      final inputs = interp.getInputTensors();
      if (inputs.length != 1) {
        throw StateError('need 1 input, got ${inputs.length}');
      }
      final inT = inputs.first;
      if (inT.shape.isEmpty) throw StateError('empty input shape');
      _inShape = List<int>.from(inT.shape);
      final frameLen = _inShape.last;
      if (frameLen <= 0 || frameLen > sampleRate * 2) {
        throw StateError('bad frame len $frameLen');
      }
      final inType = inT.type.value;
      if (inType == TfLiteType.kTfLiteFloat32) {
        _inputQuant = false;
      } else if (inType == TfLiteType.kTfLiteUInt8 || inType == TfLiteType.kTfLiteInt8) {
        final p = inT.params;
        if (p.scale <= 0) throw StateError('bad quant params');
        _inputQuant = true;
        _inScale = p.scale;
        _inZero = p.zeroPoint;
        if (inType == TfLiteType.kTfLiteInt8) {
          _inMin = -128;
          _inMax = 127;
        } else {
          _inMin = 0;
          _inMax = 255;
        }
      } else {
        throw StateError('unsupported input type $inType');
      }
      final outs = interp.getOutputTensors();
      if (outs.length != 1) {
        throw StateError('need 1 output, got ${outs.length}');
      }
      final outT = outs.first;
      if (outT.type.value == TfLiteType.kTfLiteUInt8 ||           outT.type.value == TfLiteType.kTfLiteInt8) {
        final p = outT.params;
        if (p.scale > 0) {
          _outInt = true;
          _outScale = p.scale;
          _outZero = p.zeroPoint;
        }
      } else {
        _outInt = false;
      }
      _interp = interp;
      // Fail-fast validation: dummy zeros through the graph. Any shape/type
      // mismatch throws HERE (boot, observed) instead of mid-loop (silent).
      _runFrame(List<double>.filled(frameLen, 0.0));
      available = true;
      await _l('ready cutoff=${_cfg.cutoff} patience=${_cfg.patience} '
          'frame=$frameLen quant=$_inputQuant');
    } catch (e) {
      try {
        _interp?.close();
      } catch (_) {}
      _interp = null;
      available = false;
      await _l('unavailable, bypass ($e)');
    }
  }

  /// Feeds 16 kHz mono float samples. Returns true once per candidate.
  /// Never throws.
  static bool feed(Float32List samples) {
    final interp = _interp;
    if (!_cfg.enabled || !available || interp == null) return false;
    try {
      for (var i = 0; i < samples.length; i++) {
        _ring.add(samples[i]);
      }
      final frameLen = _inShape.last;
      var fired = false;
      while (_ring.length >= frameLen) {
        final frame = _ring.sublist(0, frameLen);
        _ring.removeRange(0, frameLen);
        var energy = 0.0;
        for (final v in frame) {
          energy += v * v;
        }
        energy /= frame.length;
        if (energy < _cfg.energyFloor) {
          _hits = 0;
          continue;
        }
        final score = _runFrame(frame);
        if (score >= _cfg.cutoff) {
          _hits++;
          if (_hits >= _cfg.patience) {
            _hits = 0;
            unawaited(_l('candidate score=${score.toStringAsFixed(3)}'));
            fired = true;
          }
        } else {
          _hits = 0;
        }
      }
      return fired;
    } catch (_) {
      return false;
    }
  }

  static double _runFrame(List<double> frame) {
    final interp = _interp;
    if (interp == null) return 0.0;
    Object input;
    if (_inputQuant) {
      final q = List<int>.filled(frame.length, 0);
      for (var i = 0; i < frame.length; i++) {
        var v = (frame[i] / _inScale).round() + _inZero;
        if (v < _inMin) v = _inMin;
        if (v > _inMax) v = _inMax;
        q[i] = v;
      }
      input = _nest(q, _inShape);
    } else {
      input = _nest(frame, _inShape);
    }
    final outT = interp.getOutputTensors().first;
    final output = _zeros(outT.shape, _outInt);
    interp.run(input, output);
    var s = _unwrap(output);
    if (_outInt) s = (s - _outZero) * _outScale;
    if (!s.isFinite) return 0.0;
    return s;
  }

  static Object _nest(List<Object?> flat, List<int> shape) {
    if (shape.length <= 1) return flat;
    final inner = shape.sublist(1);
    var size = 1;
    for (final d in inner) {
      size *= d;
    }
    if (flat.length != shape[0] * size) {
      throw StateError('shape mismatch ${flat.length} vs $shape');
    }
    final out = <Object?>[];
    for (var i = 0; i < shape[0]; i++) {
      out.add(_nest(flat.sublist(i * size, (i + 1) * size), inner));
    }
    return out;
  }

  static Object _zeros(List<int> shape, bool ints) {
    if (shape.isEmpty) return ints ? 0 : 0.0;
    if (shape.length == 1) {
      return ints
          ? List<int>.filled(shape[0], 0)
          : List<double>.filled(shape[0], 0.0);
    }
    return List<Object>.generate(
        shape[0], (_) => _zeros(shape.sublist(1), ints));
  }

  static double _unwrap(Object? o) {
    if (o is num) return o.toDouble();
    if (o is List && o.isNotEmpty) return _unwrap(o.first);
    return 0.0;
  }

  static void reset() {
    _ring.clear();
    _hits = 0;
  }

  static void dispose() {
    try {
      _interp?.close();
    } catch (_) {}
    _interp = null;
    available = false;
  }
}
