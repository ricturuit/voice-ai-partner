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

  test('playback speeds run 0.5x–1.0x only, never faster than normal', () {
    final rates = PlaybackSpeed.values.map((s) => s.rate).toList();
    expect(
      rates,
      orderedEquals(<double>[0.5, 0.6, 0.7, 0.8, 0.9, 1.0]),
      reason: '0.1 steps from 0.5x to 1.0x, in order, since the menu renders '
          'them in declaration order',
    );
    expect(
      rates.every((r) => r <= 1.0),
      isTrue,
      reason: 'the setting exists because replies are too fast to follow; '
          'anything above 1.0x would not serve that',
    );
    expect(
      rates.every((r) => r >= 0.5),
      isTrue,
      reason: 'below ~0.5x browsers stop time-stretching and may mute '
          'playback outright, which would read as broken audio',
    );
    expect(PlaybackSpeed.normal.rate, 1.0);
    for (final speed in PlaybackSpeed.values) {
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

  test('volume defaults to a boost, and keeps an unboosted escape hatch', () {
    expect(
      PlaybackVolume.fromId(null),
      PlaybackVolume.boosted,
      reason: 'replies are quieter than comfortable on a phone speaker, so '
          'the boost is the default rather than opt-in',
    );
    expect(PlaybackVolume.boosted.gain, 1.5);
    expect(
      PlaybackVolume.original.gain,
      1.0,
      reason: 'a gain of exactly 1.0 is what keeps the element off the Web '
          'Audio graph entirely — the fallback if boosting misbehaves',
    );
    for (final volume in PlaybackVolume.values) {
      expect(volume.gain, greaterThanOrEqualTo(1.0));
      expect(PlaybackVolume.fromId(volume.id), volume);
    }
    expect(PlaybackVolume.fromId('v9.9'), PlaybackVolume.boosted);
  });
}
