#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { InfraCoreStack } from '../lib/infra-core-stack';
import { InfraStack } from '../lib/infra-stack';
import { InfraWebStack } from '../lib/infra-web-stack';

const app = new cdk.App();

const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: 'ap-northeast-1',
};

const coreStack = new InfraCoreStack(app, 'InfraCoreStack', { env });

new InfraStack(app, 'InfraStack', {
  env,
  shortTermMemoryTable: coreStack.shortTermMemoryTable,
  artifactsBucket: coreStack.artifactsBucket,
});

new InfraWebStack(app, 'InfraWebStack', { env });
