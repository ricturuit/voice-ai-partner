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
}
