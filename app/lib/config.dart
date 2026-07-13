/// App-wide configuration.
///
/// [apiSharedSecret] is injected at build time via `--dart-define` so the
/// real value never lives in source control. See README.md for why this is
/// a temporary approach that needs to change before a public release.
class AppConfig {
  static const String conversationApiUrl = String.fromEnvironment(
    'CONVERSATION_API_URL',
    defaultValue:
        'https://se2cfbj2p7jinxigw2nmlpz35e0kcjco.lambda-url.ap-northeast-1.on.aws/',
  );

  static const String apiSharedSecret = String.fromEnvironment(
    'API_SHARED_SECRET',
    defaultValue: '',
  );
}
