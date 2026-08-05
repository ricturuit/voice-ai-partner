import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '../models/learning_level.dart';

/// Persists the learner's current level in browser `localStorage`.
///
/// **This assumes a single user on their own device** — the app has no
/// accounts and no per-user server state, which is a deliberate, recorded
/// decision by its owner (it is a personal tool, not a product). Practical
/// consequences, so a future reader doesn't mistake them for oversights:
/// progress is per-browser, does not follow the user to another device, and
/// is lost if site data is cleared. Moving to server-side progress would
/// mean introducing accounts first; the level value itself would carry over
/// trivially, so nothing here forecloses that.
class LearningProgressStore {
  static const _levelKey = 'voice_ai_partner.learning_level';

  /// Reads the stored level, defaulting to the floor for a first run (or if
  /// storage is unavailable — Safari private mode can throw on access).
  LearningLevel load() {
    try {
      return LearningLevel.fromCode(web.window.localStorage.getItem(_levelKey));
    } catch (e) {
      debugPrint('Reading stored learning level failed, defaulting to A1: $e');
      return LearningLevel.a1;
    }
  }

  void save(LearningLevel level) {
    try {
      web.window.localStorage.setItem(_levelKey, level.code);
    } catch (e) {
      // Losing persistence must never break the lesson in progress — the
      // level still applies for the rest of this session, it just won't
      // survive a reload.
      debugPrint('Persisting learning level failed: $e');
    }
  }

  static const _volumeKey = 'voice_ai_partner.volume_boost';

  PlaybackVolume loadVolume() {
    try {
      return PlaybackVolume.fromId(web.window.localStorage.getItem(_volumeKey));
    } catch (e) {
      debugPrint('Reading stored volume failed, defaulting: $e');
      return PlaybackVolume.boosted;
    }
  }

  void saveVolume(PlaybackVolume volume) {
    try {
      web.window.localStorage.setItem(_volumeKey, volume.id);
    } catch (e) {
      debugPrint('Persisting volume failed: $e');
    }
  }

  static const _speedKey = 'voice_ai_partner.playback_speed';

  PlaybackSpeed loadSpeed() {
    try {
      return PlaybackSpeed.fromId(web.window.localStorage.getItem(_speedKey));
    } catch (e) {
      debugPrint('Reading stored playback speed failed, defaulting: $e');
      return PlaybackSpeed.normal;
    }
  }

  void saveSpeed(PlaybackSpeed speed) {
    try {
      web.window.localStorage.setItem(_speedKey, speed.id);
    } catch (e) {
      debugPrint('Persisting playback speed failed: $e');
    }
  }
}

/// How fast 名取's replies are read back, as five fixed steps.
///
/// Applied client-side via `HTMLMediaElement.playbackRate` rather than by
/// asking the TTS service to synthesise at a different speed. That choice
/// matters for a learner: the same clip can be replayed slower after the
/// fact, and the setting takes effect instantly on audio already playing,
/// neither of which is possible once a speed is baked into the generated
/// file. Pitch is preserved (`preservesPitch`, on by default and Baseline
/// since Dec 2023), so a slowed reply doesn't drop into a growl.
/// Steps run 0.5x–1.0x only: normal speed is the *fastest* setting, because
/// the need this exists for is "the reply is too fast to follow", and nothing
/// above 1.0x serves that. 0.5x is the floor because browsers stop
/// time-stretching and may mute playback entirely below roughly that point.
enum PlaybackSpeed {
  half(id: 'x0.5', rate: 0.5, label: 'いちばんゆっくり'),
  x06(id: 'x0.6', rate: 0.6, label: 'とてもゆっくり'),
  x07(id: 'x0.7', rate: 0.7, label: 'かなりゆっくり'),
  x08(id: 'x0.8', rate: 0.8, label: 'ゆっくり'),
  x09(id: 'x0.9', rate: 0.9, label: 'すこしゆっくり'),
  normal(id: 'x1.0', rate: 1.0, label: 'ふつう');

  const PlaybackSpeed({required this.id, required this.rate, required this.label});

  final String id;
  final double rate;
  final String label;

  /// e.g. `0.85x` — the compact form shown in the toolbar.
  String get display => '${rate}x';

  static PlaybackSpeed fromId(String? id) => PlaybackSpeed.values.firstWhere(
        (s) => s.id == id,
        orElse: () => PlaybackSpeed.normal,
      );
}


/// Output loudness for reply audio.
///
/// Anything above `original` is applied with a compressor plus make-up gain
/// in [AudioPlaybackService], not with `HTMLMediaElement.volume`, which
/// cannot exceed 1.0 and is read-only on iOS anyway. `original` is kept as
/// an option because it is the only setting that leaves the element off the
/// Web Audio graph entirely — the fallback if boosting ever misbehaves.
enum PlaybackVolume {
  original(id: 'v1.0', gain: 1.0, label: 'そのまま'),
  boosted(id: 'v1.5', gain: 1.5, label: '大きめ'),
  loud(id: 'v2.0', gain: 2.0, label: 'とても大きめ');

  const PlaybackVolume({required this.id, required this.gain, required this.label});

  final String id;
  final double gain;
  final String label;

  String get display => '${gain}x';

  static PlaybackVolume fromId(String? id) => PlaybackVolume.values.firstWhere(
        (v) => v.id == id,
        orElse: () => PlaybackVolume.boosted,
      );
}
