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
enum PlaybackSpeed {
  slowest(id: 'x0.7', rate: 0.7, label: 'とてもゆっくり'),
  slow(id: 'x0.85', rate: 0.85, label: 'ゆっくり'),
  normal(id: 'x1.0', rate: 1.0, label: 'ふつう'),
  fast(id: 'x1.15', rate: 1.15, label: 'やや速い'),
  fastest(id: 'x1.3', rate: 1.3, label: '速い');

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
