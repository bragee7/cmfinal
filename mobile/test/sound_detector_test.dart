/// Host-runnable self-test for [SoundDetector]: synthetic waveforms only,
/// no device, no mic, no plugins. Run with:
///   dart test/sound_detector_test.dart   (from mobile/)
/// Exits non-zero on the first failed expectation.
import 'dart:math' as math;
import 'dart:typed_data';

import '../lib/services/sound_detector.dart';

const int sr = 16000;

double dbToAmp(double db) => math.pow(10.0, db / 20.0).toDouble();

Float32List sine(double freqHz, double secs, double dbFS) {
  final n = (secs * sr).round();
  final out = Float32List(n);
  final amp = dbToAmp(dbFS);
  for (int i = 0; i < n; i++) {
    out[i] = amp * math.sin(2 * math.pi * freqHz * i / sr);
  }
  return out;
}

Float32List sweep(double f0, double f1, double secs, double dbFS) {
  final n = (secs * sr).round();
  final out = Float32List(n);
  final amp = dbToAmp(dbFS);
  double phase = 0.0;
  for (int i = 0; i < n; i++) {
    final f = f0 + (f1 - f0) * i / n;
    phase += 2 * math.pi * f / sr;
    out[i] = amp * math.sin(phase);
  }
  return out;
}

Float32List whiteNoise(double secs, double dbFS, int seed) {
  final rng = math.Random(seed);
  final n = (secs * sr).round();
  final out = Float32List(n);
  // Uniform noise has RMS = peak/sqrt(3); scale so RMS hits target dBFS.
  final peak = dbToAmp(dbFS) * math.sqrt(3.0);
  for (int i = 0; i < n; i++) {
    out[i] = peak * (rng.nextDouble() * 2.0 - 1.0);
  }
  return out;
}

Float32List mix(List<Float32List> parts) {
  int n = 0;
  for (final p in parts) {
    n = math.max(n, p.length);
  }
  final out = Float32List(n);
  for (final p in parts) {
    for (int i = 0; i < p.length; i++) {
      out[i] += p[i];
    }
  }
  return out;
}

/// Scale mix so its RMS equals target dBFS.
Float32List norm(Float32List x, double dbFS) {
  double sumSq = 0.0;
  for (int i = 0; i < x.length; i++) {
    sumSq += x[i] * x[i];
  }
  final rms = math.sqrt(sumSq / x.length);
  final target = dbToAmp(dbFS);
  final g = target / (rms + 1e-9);
  final out = Float32List(x.length);
  for (int i = 0; i < x.length; i++) {
    out[i] = (x[i] * g).clamp(-1.0, 1.0);
  }
  return out;
}

Float32List silence(double secs) => Float32List((secs * sr).round());

Float32List concat(List<Float32List> parts) {
  int n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final out = Float32List(n);
  int o = 0;
  for (final p in parts) {
    out.setRange(o, o + p.length, p);
    o += p.length;
  }
  return out;
}

class Fire {
  Fire(this.timeSec, this.label);
  final double timeSec;
  final String label;
}

/// Feed [audio] in record-like chunks, collect fires with timestamps.
List<Fire> run(SoundDetector d, Float32List audio, {int chunk = 2048}) {
  final fires = <Fire>[];
  int consumed = 0;
  while (consumed < audio.length) {
    final end = math.min(consumed + chunk, audio.length);
    final piece = Float32List.fromList(audio.sublist(consumed, end));
    final label = d.processChunk(piece);
    if (label != null) fires.add(Fire(end / sr, label));
    consumed = end;
  }
  return fires;
}

void check(bool cond, String name, [String detail = '']) {
  if (!cond) {
    throw StateError('FAIL: $name ${detail.isEmpty ? '' : '— $detail'}');
  }
  print('ok: $name${detail.isEmpty ? '' : ' ($detail)'}');
}

void main() {
  // 1. Exact whistle: 2200 Hz @ -12 dBFS for 1.5 s -> Whistle, fast.
  var fires = run(SoundDetector(), sine(2200, 1.5, -12));
  check(fires.isNotEmpty, 'whistle_exact fires');
  check(fires.first.label == SoundDetector.labelWhistle,
      'whistle_exact label is Whistle', fires.first.label);
  check(fires.first.timeSec <= 1.2, 'whistle_exact within 1.2 s',
      '${fires.first.timeSec.toStringAsFixed(2)}s');

  // 2b. Strong human-like vibrato: 2200 ± 60 Hz at 5 Hz -> Whistle.
  final vib = (() {
    const secs = 1.5;
    final n = (secs * sr).round();
    final out = Float32List(n);
    final amp = dbToAmp(-12);
    double phase = 0.0;
    for (int i = 0; i < n; i++) {
      final t = i / sr;
      final f = 2200.0 + 60.0 * math.sin(2 * math.pi * 5.0 * t);
      phase += 2 * math.pi * f / sr;
      out[i] = amp * math.sin(phase);
    }
    return out;
  })();
  fires = run(SoundDetector(), vib);
  check(fires.isNotEmpty, 'whistle_vibrato fires');
  check(fires.first.label == SoundDetector.labelWhistle,
      'whistle_vibrato label is Whistle', fires.first.label);

  // 2c. Monotonic drift 2050 -> 2350 Hz (6.7 Hz per frame) -> Whistle.
  fires = run(SoundDetector(), sweep(2050, 2350, 1.5, -12));
  check(fires.isNotEmpty, 'whistle_waver fires');
  check(fires.first.label == SoundDetector.labelWhistle,
      'whistle_waver label is Whistle', fires.first.label);

  // 3. Broadband scream 2.5 s @ -10 dBFS -> Loud sound first, never Whistle.
  final scream = norm(
      mix([sine(300, 2.5, -16), sine(700, 2.5, -16), sine(1500, 2.5, -16),
        whiteNoise(2.5, -16, 7)]),
      -10);
  fires = run(SoundDetector(), scream);
  check(fires.isNotEmpty, 'scream fires');
  check(fires.first.label == SoundDetector.labelLoudSound,
      'scream label is Loud sound', fires.first.label);
  check(fires.first.timeSec >= 1.4 && fires.first.timeSec <= 2.3,
      'scream timing ~1.5-2.2 s', '${fires.first.timeSec.toStringAsFixed(2)}s');
  check(!fires.any((f) => f.label == SoundDetector.labelWhistle),
      'scream never labeled Whistle');

  // 4. Quiet room tone: 440 Hz @ -42 dBFS for 4 s -> silence.
  fires = run(SoundDetector(), sine(440, 4.0, -42));
  check(fires.isEmpty, 'quiet never fires');

  // 5. Single door-slam transient (0.1 s @ -8 dBFS) + silence -> silence.
  fires = run(
      SoundDetector(), concat([norm(whiteNoise(0.1, -8, 9), -8), silence(2.0)]));
  check(fires.isEmpty, 'transient never fires');

  // 6. Loud vowel-like harmonic buzz @ -25 dBFS (below scream gate) ->
  //    must NOT fire Whistle (dominance gate rejects harmonic stacks).
  final harm = <Float32List>[];
  for (int h = 1; h <= 20; h++) {
    harm.add(sine(150.0 * h, 2.0, -25.0 - h));
  }
  fires = run(SoundDetector(), norm(mix(harm), -25));
  check(!fires.any((f) => f.label == SoundDetector.labelWhistle),
      'harmonic buzz never labeled Whistle');

  // 7. Moderate street noise @ -32 dBFS for 6 s -> silence (absolute gate).
  fires = run(SoundDetector(), whiteNoise(6.0, -32, 21));
  check(fires.isEmpty, 'moderate noise never fires');

  // 8. Edge: empty + tiny chunks never throw, never fire.
  final d = SoundDetector();
  check(d.processChunk(Float32List(0)) == null, 'empty chunk safe');
  check(d.processChunk(Float32List.fromList([0.1, -0.1])) == null,
      'tiny chunk safe');

  print('\nALL SOUND DETECTOR TESTS PASSED');
}
