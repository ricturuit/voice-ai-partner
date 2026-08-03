@TestOn('chrome')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ai_partner_client/models/learning_level.dart';
import 'package:voice_ai_partner_client/services/learning_progress_store.dart';

void main() {
  test('ladder runs A1 → C1 in order, with A1 the floor and C1 the ceiling', () {
    expect(
      LearningLevel.values.map((l) => l.code).toList(),
      ['A1', 'A2', 'B1', 'B2', 'C1'],
      reason: 'A1 is the requested floor (英検3級) and C1 the ceiling '
          '(business conversation). C2 is intentionally excluded — 英検 '
          'cannot certify it, so it has no meaningful rung here.',
    );
    expect(LearningLevel.a1.next, LearningLevel.a2);
    expect(LearningLevel.b2.next, LearningLevel.c1);
  });

  test('the highest level has no next level to advance to', () {
    expect(LearningLevel.c1.isHighest, isTrue);
    expect(
      LearningLevel.c1.next,
      isNull,
      reason: 'Passing at the ceiling must not roll over or crash — the '
          'controller relies on a null here to report "already at the top" '
          'rather than levelling up.',
    );
    expect(LearningLevel.a1.isHighest, isFalse);
  });

  test('fromCode round-trips, and falls back to the floor on bad input', () {
    for (final level in LearningLevel.values) {
      expect(LearningLevel.fromCode(level.code), level);
    }
    // Anything unrecognised (absent key, corrupted storage, a level removed
    // in a later version) must not throw — it lands the learner at A1.
    expect(LearningLevel.fromCode(null), LearningLevel.a1);
    expect(LearningLevel.fromCode(''), LearningLevel.a1);
    expect(LearningLevel.fromCode('C2'), LearningLevel.a1);
    expect(LearningLevel.fromCode('nonsense'), LearningLevel.a1);
  });

  test('every level carries a 英検 equivalent and a plain-Japanese goal', () {
    for (final level in LearningLevel.values) {
      expect(level.eiken, isNotEmpty, reason: '${level.code} needs a 英検 label');
      expect(level.goal, isNotEmpty, reason: '${level.code} needs a goal');
    }
  });

  test('playback speeds are five steps spanning slower and faster than 1.0', () {
    expect(PlaybackSpeed.values.length, 5, reason: 'five steps were asked for');
    final rates = PlaybackSpeed.values.map((s) => s.rate).toList();
    expect(
      rates,
      orderedEquals(<double>[0.7, 0.85, 1.0, 1.15, 1.3]),
      reason: 'must be ordered slowest→fastest and centred on 1.0, since the '
          'toolbar renders them in declaration order',
    );
    expect(PlaybackSpeed.normal.rate, 1.0);
    // Below 0.5 or above ~2.0 browsers may mute playback entirely rather
    // than time-stretch it, which would read as "the audio broke".
    for (final speed in PlaybackSpeed.values) {
      expect(speed.rate, greaterThanOrEqualTo(0.5));
      expect(speed.rate, lessThanOrEqualTo(2.0));
      expect(speed.label, isNotEmpty);
    }
  });

  test('speed ids round-trip and fall back to normal on unknown input', () {
    for (final speed in PlaybackSpeed.values) {
      expect(PlaybackSpeed.fromId(speed.id), speed);
    }
    expect(PlaybackSpeed.fromId(null), PlaybackSpeed.normal);
    expect(PlaybackSpeed.fromId('x9.9'), PlaybackSpeed.normal);
  });
}
