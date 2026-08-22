# Fuel Backend Contract and Deployment Gate

The iOS app is intentionally local-first. `BackendAPIClient` is inert until `FUEL_BACKEND_BASE_URL` resolves to a validated HTTPS URL (Debug also permits localhost). This directory specifies the service that must exist before cloud sync or remote recognition is enabled for users; it is not evidence that a production service has been deployed.

## Environments

Use separate development, staging, and production deployments, databases, signing keys, object-storage buckets, logs, and Apple service credentials. Inject only the public base URL and environment name into the app. Provider keys, Apple private keys, database credentials, webhook secrets, and model credentials stay in server secret management.

The app reads:

- `FUEL_BACKEND_ENVIRONMENT`: `development`, `staging`, or `production`
- `FUEL_BACKEND_BASE_URL`: HTTPS origin; omitted means local-only mode

## Required controls

- Verify Sign in with Apple identity tokens for issuer, audience, signature, expiry, nonce, and replay.
- Authorize every profile, sync object, job, export, and deletion against the authenticated account.
- Enforce content type, decoded image type, pixel/byte limits, schema limits, and malware/image-parser isolation.
- Apply per-account and per-IP rate limits, abuse detection, bounded job concurrency, and cost limits.
- Treat `Idempotency-Key` as account-scoped; persist response/replay state for the operation retention window.
- Validate model and nutrition-provider responses against strict schemas; reject unknown/oversized structures.
- Encrypt transport and managed storage; rotate keys; redact tokens, health/nutrition content, photos, and free-form notes from logs.
- Keep automated backups, perform restore drills, define RPO/RTO, and separate backup deletion/retention policy.
- Apply the shortest practical photo retention. Delete raw uploads after job completion unless a person explicitly chooses retention.
- Provide complete account export and deletion, including primary data, object storage, job payloads, logs subject to policy, and backup tombstoning.
- Validate subscription webhooks on the server; never trust an app-supplied premium flag.

## Endpoint inventory

- `POST /v1/auth/apple`
- `GET|PUT /v1/profile`
- `POST /v1/recognition/jobs`
- `GET /v1/recognition/status/{jobID}`
- `POST /v1/nutrition/search`
- `POST /v1/sync`
- `POST /v1/recommendations`
- `POST /v1/account/export`
- `DELETE /v1/account`
- `GET /v1/configuration`
- Server-only subscription entitlement webhook

The canonical client DTOs and validation limits live in `Fuel/Services/BackendServices.swift`. Any server OpenAPI specification must be generated from or contract-tested against those DTOs before enabling staging.

## Sync semantics

- Client mutations use stable entity identifiers and operation idempotency keys.
- The server returns accepted keys, explicit conflicts, remote changes, and a monotonic account revision.
- Fuel chooses the newer `updatedAt`; equal timestamps use revision, with server winning ties.
- A local win receives a new idempotency key and retries against the returned server revision.
- A remote win is applied through typed decoders; unknown entity types or malformed payloads stop the batch.
- HealthKit samples are not part of the sync entity set.

## Operational release evidence

Before switching a non-Debug build out of local-only mode, attach evidence for authorization tests, rate-limit tests, backup restore, deletion/export drills, retention jobs, secret scanning, vulnerability review, dashboards/alerts, on-call ownership, and staging-to-production promotion approval.
