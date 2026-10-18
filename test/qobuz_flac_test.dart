import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/qobuz_flac/qobuz_candidate_matcher.dart';
import 'package:kreate_ios/services/qobuz_flac/qobuz_signer.dart';
import 'package:kreate_ios/services/qobuz_flac/qobuz_token_pool.dart';

// I vettori delle firme sono quelli REALI del progetto di riferimento
// (QbdlxSignerTest, "locked against real HAR vectors"): la formula portata
// in Dart deve riprodurli esattamente.
void main() {
  const harSecret = 'abb21364945c0583309667d13ca3d93a';

  group('firma MD5 (track/getFileUrl)', () {
    test('riproduce il vettore HAR (format 27)', () {
      const signer = QobuzSigner();
      final sig = signer.signGetFileUrl(
        ts: 1782781652,
        trackId: 2841459,
        formatId: 27,
        appSecret: harSecret,
      );
      expect(sig, '013c10042c5e15ca5f1d85610bdd62ad');
    });

    test('riproduce il vettore HAR (format 6)', () {
      const signer = QobuzSigner();
      final sig = signer.signGetFileUrl(
        ts: 1782781565,
        trackId: 3144087,
        formatId: 6,
        appSecret: harSecret,
      );
      expect(sig, 'ff083dedd464374d86affbb22daeae01');
    });

    test('un segreto diverso cambia la firma', () {
      const signer = QobuzSigner();
      final a = signer.signGetFileUrl(
        ts: 1782781652,
        trackId: 2841459,
        formatId: 27,
        appSecret: harSecret,
      );
      final b = signer.signGetFileUrl(
        ts: 1782781652,
        trackId: 2841459,
        formatId: 27,
        appSecret: 'e79f8b9be485692b0e5f9dd895826368',
      );
      expect(a, isNot(b));
    });
  });

  group('matching dei candidati', () {
    test('un ISRC uguale vale 0.95, senza guardare il resto', () {
      final score = QobuzCandidateMatcher.confidence(
        query: const QobuzTrackQuery(artist: 'A', title: 'T', isrc: 'IT1234567890'),
        candTitle: 'Tutt\'altro titolo',
        candArtist: 'Tutt\'altro artista',
        candIsrc: 'it1234567890',
        candDurationSec: 200,
        candStreamable: true,
      );
      expect(score, 0.95);
    });

    test('titolo e artista uguali con durata vicina superano la soglia', () {
      final score = QobuzCandidateMatcher.confidence(
        query: const QobuzTrackQuery(
          artist: 'Daft Punk',
          title: 'Get Lucky',
          durationMs: 248000,
        ),
        candTitle: 'Get Lucky',
        candArtist: 'Daft Punk',
        candIsrc: null,
        candDurationSec: 248,
        candStreamable: true,
      );
      expect(score, greaterThanOrEqualTo(QobuzCandidateMatcher.minConfidence));
    });

    test('un candidato non riproducibile vale 0', () {
      final score = QobuzCandidateMatcher.confidence(
        query: const QobuzTrackQuery(artist: 'A', title: 'T'),
        candTitle: 'T',
        candArtist: 'A',
        candIsrc: null,
        candDurationSec: 100,
        candStreamable: false,
      );
      expect(score, 0);
    });

    test('la normalizzazione toglie parentesi, feat. e apostrofi', () {
      expect(
        QobuzCandidateMatcher.normalize("Don't Stop (feat. Someone) [Live]"),
        'dont stop',
      );
    });
  });

  group('pool di token', () {
    test('legge le tre forme: token, token:paese, token:paese:appId', () {
      final pool = QobuzTokenPool()
        ..configure(
          primaryAppId: '798273057',
          primaryAppSecret: 'segret0',
          appSecretsRaw: '312369995:altro-segreto',
        )
        ..poolRaw = 'aaa,bbb:it,ccc:fr:312369995';

      expect(pool.length, 3);
      expect(pool.entries[0].appId, '798273057');
      expect(pool.entries[1].country, 'it');
      expect(pool.entries[2].appId, '312369995');
      // Il token taggato si firma con la coppia DELLA SUA app.
      expect(pool.signingFor('ccc').appId, '312369995');
      expect(pool.signingFor('ccc').appSecret, 'altro-segreto');
      expect(pool.signingFor('aaa').appId, '798273057');
      expect(pool.activeToken(), isNotNull);
    });

    test('un app_id taggato senza segreto torna alla coppia primaria', () {
      final pool = QobuzTokenPool()
        ..configure(primaryAppId: '798273057', primaryAppSecret: 'segret0')
        ..poolRaw = 'ccc:fr:312369995';
      // Mai un misto app_id-di-uno/segreto-di-un-altro: è proprio quello
      // che degrada a preview.
      expect(pool.signingFor('ccc').appId, '798273057');
      expect(pool.signingFor('ccc').appSecret, 'segret0');
    });

    test('un token morto lascia il posto al successivo', () {
      final pool = QobuzTokenPool()
        ..configure(primaryAppId: '798273057', primaryAppSecret: 'segret0')
        ..poolRaw = 'aaa,bbb';
      final first = pool.activeToken();
      expect(first, isNotNull);
      pool.markDead(first!);
      final second = pool.activeToken();
      expect(second, isNotNull);
      expect(second, isNot(first));
      pool.markDead(second!);
      expect(pool.allDead(), isTrue);
    });

    test('senza token il pool è tutto morto', () {
      final pool = QobuzTokenPool()
        ..configure(primaryAppId: '798273057', primaryAppSecret: 'segret0')
        ..poolRaw = '';
      expect(pool.allDead(), isTrue);
    });
  });
}
