<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Gotchas & Troubleshooting

## Schema Blocking Valid Reqs

Firewall Events show violations? 1) Check details 2) Review schema (Settings) 3) Test Swagger Editor 4) Log mode 5) Update schema. Error "Schema violation": missing fields, wrong types, spec mismatch.

Validated: date-time,time,date,email,hostname,ipv4/6,uri(-reference),iri(-reference),int32/64,float,double,password,uuid,byte,uint64

oneOf: Zero matches (missing discriminator), Multiple (ambiguous)

## JWT Failing

1) JWKS match IdP? 2) `exp` valid? 3) Header/cookie name? 4) Test jwt.io 5) Clock skew? Error "Token invalid": config wrong, JWKS mismatch, expired

## Discovery Missing

Needs 500+ reqs/10d, 2xx from edge, not Workers direct. Check threshold, codes, session ID config. ML updates daily. Path norm: `/profile/238` → `/profile/{var1}`

## Sequence False Positives

Lookback: 10 reqs to managed endpoints, 10min (contact for adjust). Check session ID uniqueness, neg vs pos model

## Error Quick Ref

"Fallthrough": Unknown endpoint, pattern mismatch. "mTLS failed": Cert untrusted/expired, wrong CA.

## Limits & Performance

Schema: OpenAPI v3.0.x only, no ext refs/non-basic paths, 10K ops, need `type`+`schema`, default `style`/`explode`, no `content` in params, no obj param validation, no `anyOf` in params. Latency ~1-2ms.

JWT: Headers/cookies only, validates managed endpoints only. Latency ~0.5-1ms.

Sequence (Beta): Needs endpoints+session ID, contact team. Latency ~0.5ms.

mTLS: Latency ~2-5ms.

## Best Practices

1. Discovery first (map before enforce)
2. Session IDs unique per user
3. Validate schema (Swagger Editor)
4. Automate JWKS rotation (Worker cron)
5. Fallthrough rules (zombie APIs)
6. Logpush + alerts

Progressive rollout, rate limiting with JWT claims, bot management layering, staging testing: see [patterns.md](./api-shield-patterns.md).
