# Deployment Status (Phase 1)

Region: `ap-northeast-1`
Account: `568529252964`

Status: **fully deployed**. Both stacks (`InfraCoreStack`, `InfraStack`)
are `CREATE_COMPLETE`. The health check Function URL was verified with a
live request and returned HTTP 200.

## Deployed resources

- DynamoDB table `voice-ai-partner-short-term-memory` (PK `sessionId`,
  SK `createdAt`, TTL attribute `expiresAt`, TTL confirmed `ENABLED`)
- S3 bucket `voice-ai-partner-artifacts-568529252964-ap-northeast-1`
  (all public access blocked, SSE-S3 encrypted, TLS-only)
- Secrets Manager placeholders `claude-api-key` and `elevenlabs-api-key`
  (value `REPLACE_ME` — fill in manually via console or
  `aws secretsmanager put-secret-value`)
- Lambda function `voice-ai-partner-health-check` with a public Function
  URL (no bootstrap required — see below)

## Notes on this account's IAM constraints

The deploying IAM user (`claude-code-dev`) originally lacked
`iam:CreateRole`/`iam:PassRole` and `secretsmanager:CreateSecret` — these
were granted mid-session (`IAMFullAccess`, `SecretsManagerReadWrite`).
It also never had `ssm:*` or `ecr:*`, so `cdk bootstrap` still isn't
possible; both stacks use `cdk.LegacyStackSynthesizer()` in
`bin/infra.ts`, which deploys directly with the caller's own credentials
and doesn't need a bootstrapped environment (no SSM version parameter,
no S3 asset staging bucket, no bootstrap IAM roles). This works here
because the Lambda code is small enough to embed inline
(`lambda.Code.fromInline`) rather than uploading a zip asset to S3.

One more gap surfaced during deploy: `logs:CreateLogGroup` was denied
for the deploying user, so `@aws-cdk/aws-lambda:useCdkManagedLogGroup`
is set to `false` in `cdk.json` — the function's own execution role
already has `logs:CreateLogGroup`/`PutLogEvents` (via the CDK-generated
basic execution policy), so CloudWatch Logs still work; the log group is
just created lazily on first invocation instead of by CloudFormation.

## Redeploying

```
cd infra
npx cdk deploy --all --require-approval never
```
