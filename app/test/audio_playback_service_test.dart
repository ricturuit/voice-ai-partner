@TestOn('chrome')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_ai_partner_client/services/audio_playback_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unlock() re-primes on every call and is never latched behind an '
    '"already unlocked" flag',
    () async {
      // This is the regression test for a bug this project has now shipped
      // twice, from two different implementations (the AudioContext era's
      // `_audioContextUnlocked`, then the <audio> element era's
      // `_unlocked`): priming the audio element only once per session.
      //
      // iOS Safari can silently revoke an element's permission to play
      // without a gesture (backgrounding, screen lock, audio-session
      // interruption). The only way to get it back is to touch the element
      // inside a real user gesture — so if unlock() short-circuits after
      // the first success, that recovery path never runs and autoplay is
      // dead for the rest of the session while manual replay still works.
      // See AudioPlaybackService.unlock()'s doc comment and README.md.
      //
      // Asserting on attempt count (not on whether playback succeeded)
      // keeps this meaningful in a headless browser, where the underlying
      // play() may legitimately be refused.
      final service = AudioPlaybackService();
      expect(service.primeAttempts, 0);

      await service.unlock();
      expect(service.primeAttempts, 1);

      await service.unlock();
      expect(
        service.primeAttempts,
        2,
        reason: 'unlock() must re-prime on every user gesture. A count '
            'stuck at 1 means an "already unlocked" latch was '
            'reintroduced, which silently breaks autoplay for the rest '
            'of the session once iOS revokes the permission.',
      );

      service.dispose();
    },
  );
}
