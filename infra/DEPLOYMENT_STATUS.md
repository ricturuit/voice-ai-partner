# Deployment Status (Phase 1)

Region: `ap-northeast-1`
Account: `568529252964`

## Deployed (InfraCoreStack)

- DynamoDB table `voice-ai-partner-short-term-memory` (PK `sessionId`, SK `createdAt`, TTL attribute `expiresAt`)
- S3 bucket `voice-ai-partner-artifacts-568529252964-ap-northeast-1` (all public access blocked, SSE-S3 encrypted, TLS-only)

## Blocked (InfraStack: Lambda health check + Secrets Manager placeholders)

The IAM user these credentials belong to (`claude-code-dev`) has only:
`IAMReadOnlyAccess`, `IAMUserChangePassword`, `AmazonDynamoDBFullAccess`,
`AmazonS3FullAccess`, `AWSCloudFormationFullAccess`, `AWSLambda_FullAccess`.

Confirmed via `iam:SimulatePrincipalPolicy` and a real deploy attempt
(rolled back cleanly, no orphaned resources):

- `iam:CreateRole` / `iam:PassRole` / `iam:PutRolePolicy` — **denied**.
  Blocks creating the Lambda execution role, so the health-check function
  cannot be created at all.
- `secretsmanager:CreateSecret` — **denied**. Confirmed by an actual
  `CREATE_FAILED` event:
  `User: .../claude-code-dev is not authorized to perform: secretsmanager:CreateSecret`
- `ssm:PutParameter` / `ecr:CreateRepository` — also denied, which is why
  `cdk bootstrap` fails too. Both stacks use `LegacyStackSynthesizer` to
  avoid needing a bootstrapped environment for the resources that *can*
  be created.

## To finish this stack

Attach a policy to `claude-code-dev` (or the role/user actually used to
deploy) granting at minimum:

- `iam:CreateRole`, `iam:DeleteRole`, `iam:PutRolePolicy`,
  `iam:DeleteRolePolicy`, `iam:AttachRolePolicy`, `iam:DetachRolePolicy`,
  `iam:PassRole` (scoped to `lambda.amazonaws.com` via
  `iam:PassedToService`), `iam:TagRole` — scoped to role names like
  `InfraStack-HealthCheckFunctionServiceRole*` if you want it tightly
  scoped.
- `secretsmanager:CreateSecret`, `secretsmanager:TagResource`,
  `secretsmanager:DeleteSecret`, `secretsmanager:PutSecretValue`,
  `secretsmanager:DescribeSecret` — scoped to
  `claude-api-key` / `elevenlabs-api-key`.

Then from `infra/`:

```
npx cdk deploy InfraStack --require-approval never
```

No bootstrap is required (both stacks use the legacy synthesizer), and
`InfraCoreStack` is already deployed and will be reused as-is.
