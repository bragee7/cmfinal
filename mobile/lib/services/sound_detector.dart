import 'dart:math' as math;
import 'dart:typed_data';

/// Pure-Dart, dependency-free distress-sound detector.
///
/// No AI/ML models, no downloads, no native plugins: everything here is
/// classical DSP computed per 50 ms frame from the already-streaming
/// 16 kHz mono PCM floats (the same `record` stream the old engine used).
///
/// Two independent triggers (checked in this order per frame):
///
/// 1. WHISTLE — a sustained narrowband tone in 1800–2800 Hz (the range of a
///    loud human whistle). Detected with a bank of Goertzel filters: the
///    frame counts as "whistly" when the best ADJACENT BIN PAIR holds a
///    dominant share of the frame energy (exact tones sit in one bin,
///    wavering whistles smear across two neighbors — both pass), the frame
///    is above the silence floor, and the zero-crossing rate sits in the
///    tonal band. Sustained ~0.8 s (16 consecutive frames) fires
///    [labelWhistle].
///    A whistle is deliberate, so it is the low-false-positive trigger:
///    use it when the user can make noise on purpose.
///
/// 2. LOUD SOUND — sustained broadband loudness (scream/shout/gunshot-like
///    sustained blasts). Threshold = max(-22 dBFS absolute, adaptive noise
///    floor + 15 dB), so a quiet room keeps a fixed gate while a noisy
///    street raises it. Sustained ~1.5 s (30 consecutive frames) fires
///    [labelLoudSound]. Short transients (door slams, claps, single barks)
///    never reach the sustain count and are ignored.
///
/// Separation: a loud whistle trips BOTH sustain counters, but whistle
/// (0.8 s) always wins the race, so the label stays informative. A scream
/// is broadband, so its Goertzel energy spreads over all bins and the
/// dominance gate keeps it out of the whistle path.
///
/// TUNING (all constants below): raise [_absScreamDb] (e.g. -18) or
/// [_floorMarginDb] for fewer false alarms in loud places; lower them for
/// more sensitivity. Lengthen [_screamSustainSec]/[_whistleSustainSec] to
/// trade speed for confidence. Everything runs in O(frames) time —
/// ~20 kFLOP/s — negligible battery impact next to the old neural engine.
///
/// Returns the trigger label on the exact call where it fires, else null.
/// Create one instance per listening session (stateful: floor, counters).
class SoundDetector {
  SoundDetector({this.sampleRate = 16000});

  final int sampleRate;

  static const String labelWhistle = 'Whistle';
  static const String labelLoudSound = 'Loud sound';

  // ---- scream (sustained loud broadband) ----
  static const double _absScreamDb = -22.0; // never more sensitive than this
  static const double _floorMarginDb = 15.0; // adaptive: floor + margin
  static const double _screamSustainSec = 1.5;
  static const double _releaseDb = 6.0; // hysteresis before re-arming

  // ---- whistle (sustained narrowband tone) ----
  // Whistle band as CONSECUTIVE Goertzel bins: k = 29..45 at N = 256 is
  // an exact 62.5 Hz tiling of 1812.5–2812.5 Hz with no holes. (Rounded
  // "round-number" target freqs skip integers and leave ~125 Hz dead
  // zones where a tone returns near-zero response in every bin.)
  static const int _whistleKLo = 29;
  static const int _whistleKHi = 45;
  static const double _whistlePairRatio = 0.35; // best adjacent-pair share
  static const double _whistlePairDominance = 5.0; // pair vs avg-of-rest
  static const double _whistleSustainSec = 0.8;
  static const double _whistleFloorDb = -45.0; // ignore silence outright

  // ---- shared ----
  static const double _refractorySec = 3.0; // quiet period after any fire
  static const double _zcrLo = 0.10; // tonal band for 16 kHz audio
  static const double _zcrHi = 0.50;

  late final int _frameLen = sampleRate ~/ 20; // 50 ms frames
  late final int _screamFramesNeeded = (_screamSustainSec * 20).round();
  // Whistle sustain in 16 ms Goertzel blocks: 0.8 s ≈ 50 blocks.
  late final int _whistleBlocksNeeded =
      (_whistleSustainSec * sampleRate / _goertzelN).round();
  late final int _refractoryFrames = (_refractorySec * 20).round();

  double _noiseFloorDb = -55.0;
  final List<double> _pending = <double>[];
  int _loudStreak = 0;
  int _whistleStreak = 0;
  int _refractory = 0;
  bool _screamArmed = true;

  /// Feed mono float32 samples in [-1, 1] (any chunk size).
  /// Returns 'Whistle' / 'Loud sound' on the call where it fires, else null.
  String? processChunk(Float32List samples) {
    if (samples.isEmpty) return null;
    for (int i = 0; i < samples.length; i++) {
      _pending.add(samples[i]);
    }
    String? fired;
    while (_pending.length >= _frameLen) {
      final frame = _pending.sublist(0, _frameLen);
      _pending.removeRange(0, _frameLen);
      fired ??= _processFrame(frame);
    }
    return fired;
  }

  String? _processFrame(List<double> frame) {
    final n = frame.length;
    double sumSq = 0.0;
    for (int i = 0; i < n; i++) {
      final x = frame[i];
      sumSq += x * x;
    }
    final meanSq = sumSq / n;
    final rms = math.sqrt(meanSq);
    final db = 20.0 * (math.log(rms + 1e-9) / math.ln10);

    // Adaptive noise floor: falls fast toward quiet, rises very slowly
    // toward loud, so a noisy street lifts the gate over minutes while a
    // sudden scream never drags the floor up with it.
    if (db < _noiseFloorDb + 3.0) {
      _noiseFloorDb += (db - _noiseFloorDb) * 0.02;
    } else {
      _noiseFloorDb += (db - _noiseFloorDb) * 0.0002;
    }
    _noiseFloorDb = _noiseFloorDb.clamp(-60.0, -25.0);

    if (_refractory > 0) {
      _refractory--;
      _loudStreak = 0;
      _whistleStreak = 0;
      return null;
    }

    // ---- whistle first: specific beats loud in the race ----
    // Per 16 ms Goertzel blocks (62.5 Hz bins): short windows tolerate the
    // pitch drift of a real wavering whistle, which would smear across the
    // bins of one long window. A block is "whistly" when the best adjacent
    // bin pair dominates the block spectrum; ~50 consecutive blocks
    // (~0.8 s) fire.
    final whistleDbGate = math.max(_whistleFloorDb, _noiseFloorDb + 6.0);
    for (int s = 0; s + _goertzelN <= frame.length; s += _goertzelN) {
      if (_isWhistleBlock(frame, s, whistleDbGate)) {
        _whistleStreak++;
        if (_whistleStreak >= _whistleBlocksNeeded) {
          _resetStreaks();
          return labelWhistle;
        }
      } else {
        _whistleStreak = 0;
      }
    }

    // ---- scream: sustained loud, with hysteresis re-arm ----
    final screamThr =
        math.max(_absScreamDb, _noiseFloorDb + _floorMarginDb);
    if (_screamArmed && db >= screamThr) {
      _loudStreak++;
      if (_loudStreak >= _screamFramesNeeded) {
        _resetStreaks();
        return labelLoudSound;
      }
    } else {
      _loudStreak = 0;
      // Re-arm only after the level dips well below the gate, so one
      // continuous blast cannot machine-gun triggers back to back.
      if (db < screamThr - _releaseDb) _screamArmed = true;
    }
    // Latch disarm right after firing so a continuing scream does not
    // machine-gun: it must dip below (threshold - hysteresis) to re-arm.
    return null;
  }

  void _resetStreaks() {
    _loudStreak = 0;
    _whistleStreak = 0;
    _screamArmed = false;
    _refractory = _refractoryFrames;
  }

  /// One 16 ms block verdict: true when a narrowband tone dominates it.
  /// Pure tone at bin center -> best pair ~0.5; broadband -> ~0.016/pair.
  static const int _goertzelN = 256;

  bool _isWhistleBlock(List<double> frame, int offset, double dbGate) {
    const int n = _goertzelN;
    double sumSq = 0.0;
    int zc = 0;
    for (int i = 0; i < n; i++) {
      final x = frame[offset + i];
      sumSq += x * x;
      if (i > 0 && (x >= 0) != (frame[offset + i - 1] >= 0)) zc++;
    }
    final meanSq = sumSq / n;
    final db = 20.0 * (math.log(math.sqrt(meanSq) + 1e-9) / math.ln10);
    if (db <= dbGate) return false;
    final zcr = zc / n;
    if (zcr <= _zcrLo || zcr >= _zcrHi) return false;
    final denom = meanSq + 1e-9;
    final int nbins = _whistleKHi - _whistleKLo + 1;
    final ratios = List<double>.filled(nbins, 0.0);
    double total = 0.0;
    for (int bi = 0; bi < nbins; bi++) {
      final k = _whistleKLo + bi;
      final omega = 2.0 * math.pi * k / n;
      final coeff = 2.0 * math.cos(omega);
      double q0 = 0.0, q1 = 0.0, q2 = 0.0;
      for (int i = 0; i < n; i++) {
        q0 = coeff * q1 - q2 + frame[offset + i];
        q2 = q1;
        q1 = q0;
      }
      final ratio = ((q1 * q1 + q2 * q2 - q1 * q2 * coeff) / (n * n)) / denom;
      ratios[bi] = ratio;
      total += ratio;
    }
    double bestPair = 0.0;
    int bestI = 0;
    for (int b = 0; b + 1 < ratios.length; b++) {
      final pair = ratios[b] + ratios[b + 1];
      if (pair > bestPair) {
        bestPair = pair;
        bestI = b;
      }
    }
    final restAvg =
        (total - ratios[bestI] - ratios[bestI + 1]) / (ratios.length - 2);
    return bestPair > _whistlePairRatio &&
        bestPair > _whistlePairDominance * restAvg;
  }
}
