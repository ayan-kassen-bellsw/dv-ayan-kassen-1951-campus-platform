# Approve and deploy a production release

The main and production Deployments use separate Pods and Services in the project namespace. Both use the same PostgreSQL database, application credentials and Ingress address in Learner Lab. Traefik routes the `prod.scholarships.test` host to production. A merge updates the main Deployment. The first approved release starts two production Pods; later approvals roll that Deployment forward.

## Configure the environment and cluster

In **Settings → Environments → prod**, add the repository owner as a **required reviewer**, disable administrator bypass and restrict deployments to the branch `main`. The release workflow runs on the default branch after a Git tag event. In this single-student project, the owner can push a tag and then approve it as a separate action. Keep the ECR credential in the existing `ecr-publish` environment. [GitHub deployment protection rules](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)

On the k3s server, run the deployment installer from the release-capable checkout. It prepares the prod route, database access and a Deployment with zero replicas on initial setup. Reinstalling preserves the current prod version and replica count. Use the same ECR registry hostname as the main publisher. [Server installation](ecr.md#deploy-images-from-main)

On 23 November 2026, Learner Lab reported zero prod replicas and HTTP 503 on the prod host before the first approval. The main route continued to serve `main-26` on two ready replicas. GitHub reported the required reviewer and the branch restriction, and AWS confirmed that the temporary SSH rule had been removed. [Pre-release verification](evidence/prod-release-setup.json)

## Release a published commit

1. Select a commit on `main` whose CI and **Publish ECR** runs passed. Confirm its full Git SHA has an image tag in the project ECR repository. Set `VERSION` to the new SemVer tag (for example, `v0.2.0`) and `RELEASE_SHA` to that full commit SHA.

   ```bash
   git fetch origin main --tags
   git merge-base --is-ancestor "$RELEASE_SHA" origin/main
   git tag -a "$VERSION" "$RELEASE_SHA" -m "Release $VERSION"
   git push origin "refs/tags/$VERSION"
   ```

2. Open the **Release to prod** workflow run. Check the version and SHA shown in the review job. Choose **Review deployments → prod → Approve and deploy** to authorize those exact bytes. A rejected release leaves the current production version in place.
3. After approval, the publisher assigns the version tag and a numbered deployment tag to the SHA's ECR digest. The k3s service checks all three tags and rolls the production Pods. GitHub verifies the version and SHA on two distinct production Pod names and checks database and storage readiness.
4. Record links to the approval, workflow and GitHub Release for the report. The original CI build and the approved deploy together establish which artifact ran.

For a manual check, set `K3S_APP_URL` to the same public origin configured in GitHub. The reserved test hostname is selected by an HTTP header, so these commands work without public DNS.

```bash
curl -fsS -H 'Host: prod.scholarships.test' "$K3S_APP_URL/info"
curl -fsS -H 'Host: prod.scholarships.test' "$K3S_APP_URL/readyz"
```

## Roll back a production release

On the server, choose a known healthy production revision from the rollout history. Replace `REVISION` below with its numerical revision.

```bash
k=(sudo /usr/local/bin/k3s kubectl -n dv-ayan-kassen-1951)
"${k[@]}" rollout history deployment/dv-ayan-kassen-1951-prod
"${k[@]}" rollout undo deployment/dv-ayan-kassen-1951-prod --to-revision="$REVISION"
"${k[@]}" rollout status deployment/dv-ayan-kassen-1951-prod --timeout=5m
```

Repeat the prod Ingress checks and record the recovered version. After a successful deployment, the server records the approved release number in `prod-applied.json`; polling the same number preserves a manual rollback. If a rollout is still failing and has no checkpoint, pause the deployment timer during recovery and resume it when a corrected, approved image is available. Pausing this shared timer also pauses main deployments.
