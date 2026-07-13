#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { InfraCoreStack } from '../lib/infra-core-stack';
import { InfraStack } from '../lib/infra-stack';

const app = new cdk.App();

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: 'ap-northeast-1',
};

// Legacy synthesizer: deploys directly with the current IAM principal's
// credentials, without requiring `cdk bootstrap` (no SSM parameter lookup,
// no S3 asset staging bucket, no bootstrap IAM roles).
const synthesizer = new cdk.LegacyStackSynthesizer();

const coreStack = new InfraCoreStack(app, 'InfraCoreStack', { env, synthesizer });

new InfraStack(app, 'InfraStack', {
  env,
  synthesizer,
  shortTermMemoryTable: coreStack.shortTermMemoryTable,
  artifactsBucket: coreStack.artifactsBucket,
});
