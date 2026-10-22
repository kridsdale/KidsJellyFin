# Parents credential lifecycle and renewal assessment

Assessment date: 2026-10-18. This is a source-grounded procedure and design review,
not evidence that live credential rotation has succeeded. Current execution and
ownership remain in `kids-1t9.34` and server `jf-parents-credential-renewal`.

## Outcome

The current supported replacement path is a controlled credential change followed
by fresh receiver trials and commissioning. General unattended renewal is not
implemented. A successful initial installation must not be described as permanent
operation: control credentials expire within 30 days, and commissioning expires
no later than its bound credential.

Keep Jellyfin authentication separate from the Parents control-service credential.
A control-service expiry does not require logging the parent out of Jellyfin.
Receiver replacement must preserve enforcement, admission history and uncertain
usage; unpairing is not a renewal mechanism.

## Verified source behavior

| Area | Current behavior | Evidence |
| --- | --- | --- |
| Server lifetime | Issuance accepts 1 through 30 days in seconds; server checks actual expiry and issuer authority. | Backend `kids_cache/parents/auth.py`: `MAX_LIFETIME`, `issue`, `authenticate`. |
| Inventory | The authenticated adult can list token ID, role, server, child/device scope, creation, expiry and revocation metadata. Secrets and verifiers are omitted. | Backend `AuthStore.list_credentials` and `_metadata`. |
| Provisioning | Adult web session and CSRF are required. Native Bearer requests cannot issue credentials. | Backend `kids_cache/parents/http.py`: `handle_admin`, `validate_provision`. |
| Unknown issuance outcome | Repeating the same command returns the original metadata with `token: null` and `secretShown: false`; it does not reveal the secret again. | Backend `AuthStore.issue`. |
| Revocation | An authenticated adult can revoke the exact token with an idempotent command. | Backend `AuthStore.revoke`. |
| Receiver commissioning | Eligibility binds token ID, device, child, source, client build, phase and safety epoch. The proof expiry cannot exceed credential expiry. | Backend `kids_cache/parents/commissioning.py`: `_features`, `install`. |
| Parent storage | `ParentServiceConnection` stores URL, server ID, adult ID and token; it does not store expiry or token ID. | [ParentsModel+Features.swift](../../KidsParents/ParentsModel+Features.swift). |
| Parent authorization failure | A 401 clears active control/dashboard state and disables changes. Stored service credentials and Jellyfin authentication remain. | `ParentsModel.pollControls`; [ParentsLifecycleTests.swift](../../KidsParentsTests/ParentsLifecycleTests.swift), expired-service replacement regression. |
| Parent replacement | The new service credential is persisted only after validating the connection, current server state and activity generation. It does not replay parent commands. | [ParentsModel.swift](../../KidsParents/ParentsModel.swift): `connectControls`. |
| Receiver storage | Configuration stores the token and enforcement markers, without expiry metadata. Pairing preserves activation, the latched control and required-grant mode. | [KidsAccountHost.swift](../../Packages/KidsAccounts/Sources/KidsAccounts/KidsAccountHost.swift); [KidsViewingRuntime.swift](../../Packages/KidsApplication/Sources/KidsApplication/KidsViewingRuntime.swift). |
| Receiver journal | A token change is not retirement of pending reports or a surrender. Pending state must be resolved through the supported protocol. | `KidsAdmissionJournal`, receiver pairing and policy refresh. |

The existing commissioning contract explicitly requires new actual trials for a
new token or epoch. Its same-token handoff cannot be relabeled with a replacement
token. See [parents-commissioning.md](parents-commissioning.md).

## Controlled replacement procedure

The following uses existing administrative operations. It is not an automatic
rotation endpoint and is not an instruction to execute during the current trial.

1. **Inventory before expiry.** Use the adult web administration session to read
   `GET /api/parent-admin/v1/credentials`. Record non-secret token IDs, exact role,
   server/child/device scopes and expiry. Also check the current commissioning and
   finite service deadlines. The earliest applicable deadline wins.
2. **Prepare a bounded maintenance plan.** Pin the actual source, client build,
   safety epoch, device bindings and old/new credential identities. Preserve a
   private recovery record and use the existing reviewed service controls. Do not
   extend the old token, old trial window or old proof to make the plan fit.
3. **Quiesce while the old credential is valid.** Resolve unknown parent mutation
   outcomes with their original command IDs. Stop normal receiver playback,
   deliver its genuine FIFO and original surrender, and verify no live authority.
   Check the journal after stopping, not just before: a normal heartbeat can be
   queued between an empty check and process termination. Preserve and deliver it
   normally; never clear it to obtain an empty journal.
4. **Issue one replacement.** Through the same adult-cookie/CSRF administration
   facility, send `POST /api/parent-admin/v1/credentials` with a fresh command UUID,
   exact existing role/scopes and bounded `expiresInSeconds`. The closed body is
   `commandID`, `role`, `childUserIDs`, `deviceIDs`, `expiresInSeconds`. A receiver
   credential has exactly one child and device. Keep the returned secret in a
   private channel or owner-only operator file; never in chat, source or Beads.
5. **Handle an unknown issuance response explicitly.** Reuse the same command UUID
   to inspect the result. A null secret on replay is not a usable replacement.
   Recover the privately saved original response if available. Otherwise establish
   that the orphan credential was not installed, revoke that exact unused token
   through the supported operation, then prepare a distinct reviewed issuance.
   Do not issue an unbounded series of replacements or overwrite old records.
6. **Replace the parent connection independently.** Keep the existing Jellyfin
   session. Enter the replacement control-service credential in the Parents
   connection UI and let the app validate it before persistence. Verify fresh
   capabilities, the expected server/children/devices and no command replay.
7. **Recommission the receiver for the new token.** Pair through the PIN-protected
   UI, retaining enforcement markers and the installation identity. The existing
   commission is bound to the old token and cannot authorize the new one. Use the
   reviewed trial/commissioning facility for the new exact token/build/source/
   epoch tuple, gather the required actual trials and install a fresh envelope.
   Replacing a token field or copying an old accepted row is not commissioning.
8. **Observe the actual new connection.** Confirm the authenticated new-token
   build/heartbeat, expected scope, fresh policy and actual release acknowledgment.
   Observe the required receiver behavior; a successful HTTP response or cached
   capability list alone is insufficient. Preserve budgets, history, uncertain
   usage, original receipts and the safety epoch throughout.
9. **Retire the old credential after successful handoff.** Use the adult web
   operation `POST /api/parent-admin/v1/credentials/{tokenID}/revoke` with its own
   idempotent `commandID`. Verify the exact old token is rejected and the new
   connection still works. This is separate from accepting the new credential.

## Failure and rollback boundaries

- A parent connection rejected during validation does not overwrite the saved
  previous service credential or Jellyfin identity. If credential persistence
  itself fails, keep mutations paused and inspect the actual stored outcome;
  do not promise rollback from an error alone. Revalidate an old credential before
  reconnecting, including its expiry and current authority.
- Receiver pairing writes configuration before the later network handshake. A
  failed new connection must remain held. Preserve the private old secret and
  exact journal instead of unpairing or discarding pending evidence.
- New receiver commissioning replaces the token binding and retires authority.
  Re-entering the old secret alone does not reverse it. Rollback requires a
  reviewed current source/epoch/token commissioning procedure; never direct SQL
  edits, copied database state, restored usage counters or a relabeled envelope.
- An expired/revoked old token cannot serve as rollback authority. Recover through
  the authenticated adult administration path and fresh commissioning.
- A source, epoch, scope, device or client-build change is a different transition.
  It must not inherit a same-state renewal assertion.

## Work needed for durable operation

1. **Expiry visibility.** Deliver and store validated token ID/expiry metadata in
   each app. Show the control-connection deadline separately from Jellyfin login.
   Local dates are advisory; they never extend server authority. Distinguish an
   expired control credential from a Jellyfin sign-in failure in error text.
2. **A real quiescence boundary.** Receiver maintenance needs to stop new monitor
   work, drain the original FIFO/surrender and retire in-flight old-token work
   before replacement. A pre-stop empty check is not an atomic barrier. Preserve
   all enforcement markers and uncertain state if the transition cannot finish.
3. **A supported renewal/continuity contract.** If unattended renewal is required,
   specify its authenticated adult authority, exact scope, source/build/epoch
   binding, finite overlap, unknown-result recovery and commissioning rules.
   Current code has no general refresh endpoint. Do not assume that an old token,
   its proof, or its secret permits an expiry extension or changed-scope issuance.
4. **Observed replacement and expiry recovery.** Tests must cover successful
   renewal, unknown issuance, failed persistence, an interrupted handoff, old-token
   revocation, expired offline devices and commissioning mismatch. Include genuine
   new-token behavior in the approved environment, not only transport fixtures.

The existing parent lifecycle regression covers service-only 401 and validated
replacement without a Jellyfin login/logout or mutation replay. This assessment
did not issue, rotate, revoke or expire live credentials, change service/profile
expiry, recommission a receiver or run a new device trial. General durable renewal
and its runtime acceptance therefore remain outstanding in Beads.
