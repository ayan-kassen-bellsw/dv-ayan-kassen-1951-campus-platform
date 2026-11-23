# Changelog

## Unreleased

- Provision a two-node k3s cluster, private image registry and S3 backups in AWS. Run scholarship applications and PostgreSQL on the cluster, with SSM-backed credentials and a tested restore procedure.
- Deploy successful main builds by their ECR digest. Version tags request a separate production rollout through a required GitHub Environment review.

## [v0.1.0](https://github.com/ayan-kassen-bellsw/dv-ayan-kassen-1951-campus-platform/releases/tag/v0.1.0) — 2026-11-23

- Added scholarship applications with PostgreSQL persistence and a configurable 16-character password policy with optional punctuation.
- Added required CI checks for tests, secrets, dependency vulnerabilities, the application image and a Docker Compose persistence check.
