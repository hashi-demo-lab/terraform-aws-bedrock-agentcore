# Changelog

All notable changes to the `terraform-aws-bedrock-agentcore` module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-05-06

### Added

- Initial release of terraform-aws-bedrock-agentcore module
- Bedrock agent runtime with configurable foundation model and instruction
- Code interpreter action group enabled by default (toggleable)
- Lambda-backed action groups via for_each map
- Optional knowledge base with OpenSearch Serverless vector store
- Optional HTTP API Gateway exposure with throttling and access logging
- Optional Bedrock Guardrails association
- Customer-managed KMS encryption (BYO or module-managed)
- CloudWatch logging with KMS encryption (always on, configurable retention)
- X-Ray tracing (always on)
- Least-privilege IAM execution role with confused-deputy mitigation
- Required organizational tags: Environment, Owner, CostCenter, Project
