import 'package:flutter_test/flutter_test.dart';
import 'package:kreate_ios/services/qobuz_flac/qobuz_app_keys.dart';

// Snippet REALI del bundle 8.3.0-b029 del client web Qobuz: il parser deve
// ricavarne l'app_id di produzione e i tre segreti derivati dai seed — gli
// stessi che qobuz-dl prova uno per uno. Il "berlin" è quello accettato
// dall'API al momento della verifica (gli altri due vengono rifiutati).
const _bundle = '''
var x={production:{api:{appId:"798273057",appSecret:"05a4851e74ee47fda346f50cfdfc4f09",apiKey:"altro"}}};
var lista=[{offset:"GMT",name:"Africa/Abidjan",info:"BhZWQwMWQwNGE=NTI2OGQwY2ZmZD",extras:"UwNGZkYzliMTRhY2YxYzI3MzExOWE="},{offset:"GMT",name:"Europe/London",info:"hhNGI3YWMzODE=MTlkMTI1OWM1Nj",extras:"VkNDNlNDg2OWU2MjU1YWUxYTdmZTU="},{offset:"GMT+01:00",name:"Europe/Berlin",info:"QxM2NhM2Q5M2E=ZWI4MDU5YWEyNT",extras:"RlNDZjNTkyNTAzYjdkZGMwOGI5MGQ="}];
c.initialization=function(){var e="nightly",t="integration",r=window.__ENVIRONMENT__;return"recette"===r?c.initialSeed("ZjY5YTc3MzQ2ODZjYjk0Mjc2MjkzNz",window.utimezone.london):"beta"!==r?[e,t].includes(r)?c.initialSeed("ODA2MzMxYzNiMGI2NDFkYTkyM2I4OT",window.utimezone.abidjan):c.initialSeed("YWJiMjEzNjQ5NDVjMDU4MzMwOTY2N2",window.utimezone.berlin):void 0};
''';

void main() {
  test('legge l\'app_id di produzione dal bundle', () {
    expect(QobuzAppKeys.parseAppId(_bundle), '798273057');
  });

  test('deriva i tre segreti dai seed (come qobuz-dl)', () {
    final secrets = QobuzAppKeys.deriveSecrets(_bundle);
    expect(secrets.length, 3);
    expect(secrets['abidjan'], '806331c3b0b641da923b890aed01d04a');
    expect(secrets['london'], 'f69a7734686cb9427629378a4b7ac381');
    expect(secrets['berlin'], 'abb21364945c0583309667d13ca3d93a');
  });

  test('un bundle senza la struttura attesa non produce nulla', () {
    const rotto = 'console.log("niente da vedere");';
    expect(QobuzAppKeys.parseAppId(rotto), isNull);
    expect(QobuzAppKeys.deriveSecrets(rotto), isEmpty);
  });
}
