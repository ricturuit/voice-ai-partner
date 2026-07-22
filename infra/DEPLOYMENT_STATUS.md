# Deployment Status (Phase 1)

Region: `ap-northeast-1`
Account: `568529252964`

Status: **fully deployed**, standard bootstrap-based CDK flow (no
workarounds). Both stacks (`InfraCoreStack`, `InfraStack`) are
`CREATE_COMPLETE`/`UPDATE_COMPLETE`. The health check Function URL was
verified with live requests: missing/incorrect `x-api-secret` header
returns 401, correct header returns 200.

## Deployed resources

- DynamoDB table `voice-ai-partner-short-term-memory` (PK `sessionId`,
  SK `createdAt`, TTL attribute `expiresAt`, TTL confirmed `ENABLED`)
- S3 bucket `voice-ai-partner-artifacts-568529252964-ap-northeast-1`
  (all public access blocked, SSE-S3 encrypted, TLS-only)
- Secrets Manager:
  - `claude-api-key` / `elevenlabs-api-key` — placeholders (value
    `REPLACE_ME`, fill in manually)
  - `voice-ai-partner-api-shared-secret` — auto-generated 48-char secret
    used for Lambda-side request authentication (see `README.md`)
- Lambda function `voice-ai-partner-health-check` with a Function URL
  (`AuthType: NONE` at the URL level; the handler itself enforces the
  `x-api-secret` header check)

## CDK bootstrap and IAM history

This account's deploying IAM user (`claude-code-dev`) was originally
missing several permission groups, discovered incrementally across the
session:

1. `iam:CreateRole`/`iam:PassRole`, `secretsmanager:CreateSecret` — fixed
   by attaching `IAMFullAccess` and `SecretsManagerReadWrite`.
2. `ssm:PutParameter`/`ecr:CreateRepository` (needed for `cdk bootstrap`)
   — fixed by attaching `AmazonSSMFullAccess` and
   `AmazonEC2ContainerRegistryFullAccess`. `cdk bootstrap` then ran
   successfully and created the standard `CDKToolkit` stack
   (staging S3 bucket, ECR repo, publishing/deploy/lookup IAM roles).
3. `logs:CreateLogGroup` was denied for the deploying user early on, so
   `@aws-cdk/aws-lambda:useCdkManagedLogGroup` was temporarily set to
   `false`. **This has been reverted to `true`** now that bootstrap is in
   place — CloudFormation deploys via the bootstrap `CloudFormationExecutionRole`
   (`AdministratorAccess` by default), not the caller's own IAM
   permissions, so this class of gap no longer applies to stack deploys.

As a result, `bin/infra.ts` no longer uses `LegacyStackSynthesizer` and
`infra-stack.ts` no longer inlines the Lambda source — both stacks use
the default (bootstrap-based) synthesizer and `lambda.Code.fromAsset(...)`,
same as a normal CDK project.

One follow-up note: when we deleted a Lambda function's log group
manually during Legacy-synth days and later re-enabled CDK-managed log
groups, CloudFormation failed with "log group already exists" because it
wasn't previously tracked by CloudFormation. We deleted the
orphaned/unmanaged log group via `aws logs delete-log-group` before the
first bootstrap-based deploy so CloudFormation could create and own it.
This is a one-time migration step, not something future deploys need to
repeat.

## Redeploying

```
cd infra
npx cdk deploy InfraCoreStack InfraStack --require-approval never
```
