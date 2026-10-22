# Client source-control policy

This repository is the source of truth for the KidsJellyFin tvOS client and the KidsJellyFin Parents iOS client. Beads records work and ownership; Git records reviewed source states. Agent Mail carries cross-Mac handoffs and does not replace either system.

## Branches and commits

- `main` is the stable integration line. Product work is developed on named feature or release-candidate branches and merged only after the applicable QA gate.
- Every commit must describe one reviewable outcome. Source, tests, and the documentation required to operate that outcome belong in the same commit or in an immediately adjacent process commit.
- Before staging, review `git status`, `git diff --check`, the staged diff, and newly added files. Never use blanket staging on a long-lived dirty worktree.
- Do not commit generated build products, DerivedData, simulator data, credentials, private logs, media paths, database files, or raw QA captures. Reports and release manifests may be committed when they contain no secrets or private user data; large captures remain outside Git and are referenced by hash.
- Check in dependency lockfiles only when they are the intentional project-level resolution for a changed dependency. Ignore package-local resolutions created by ad hoc builds.
- Never rewrite or move a published release tag. Corrections receive a new release version.

## Review and integration

1. Claim the canonical Bead and state the acceptance criteria.
2. Inspect the complete diff and separate unrelated work before staging.
3. Run the smallest meaningful tests for the changed code, then build both affected apps.
4. Run release-gating QA from the built artifacts. Compile-only evidence is not runtime acceptance.
5. Commit the source state. A release manifest refers to this full 40-character commit ID and its deterministic implementation digest.
6. Create the immutable release tag `client-vYYYYMMDD-HHMM` only after the manifest and QA gate pass.
7. Push the branch and tag together. Never force-push a release branch or release tag.

## Cross-repository ownership

The client and backend have separate repositories and release histories. BlueLake owns client source and GreenCastle owns backend source. Cross-component changes reference the canonical Bead and exchange source or artifact hashes over Agent Mail. Do not copy backend source into this repository or manufacture a shared commit identity.

## Recovery

The previous release tag and manifest are the source rollback pointer. Rollback changes the installed app artifact; it does not erase client state, backend journals, credentials, media, approval history, or databases. If source history and an installed artifact disagree, stop the rollout and reconcile hashes before further testing.
