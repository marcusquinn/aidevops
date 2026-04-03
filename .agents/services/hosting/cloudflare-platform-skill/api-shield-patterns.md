# Patterns & Use Cases

## Protect API with Schema + JWT

```http
# 1. Upload OpenAPI schema
POST /zones/{zone_id}/api_gateway/user_schemas

# 2. Configure JWT validation
POST /zones/{zone_id}/api_gateway/token_validation
{"name": "Auth0", "location": {"header": "Authorization"}, "jwks": "{...}"}

# 3. Create JWT rule
POST /zones/{zone_id}/api_gateway/jwt_validation_rules

# 4. Set schema validation action
PUT /zones/{zone_id}/api_gateway/settings/schema_validation
{"validation_default_mitigation_action": "block"}
```

## Progressive Rollout

1. **Log mode** — Schema + JWT action = Log; observe false positives
2. **Block subset** — Change critical endpoint actions to Block; monitor firewall events
3. **Full enforcement** — Default action = Block; handle fallthrough with custom rule

## Fallthrough Detection (Zombie APIs)

```javascript
// WAF Custom Rule
(cf.api_gateway.fallthrough_triggered and http.host eq "api.example.com")
// Action: Log (discover unknown) or Block (strict)
```

## Rate Limiting by User

```javascript
// Rate Limiting Rule
(http.host eq "api.example.com" and
 lookup_json_string(http.request.jwt.claims["{config_id}"][0], "sub") ne "")

// Rate: 100 req/60s
// Counting: lookup_json_string(http.request.jwt.claims["{config_id}"][0], "sub")
```

## Architecture Patterns

| Pattern | Edge Stack |
|---------|-----------|
| **Public API** (high security) | Discovery → Schema Validation → JWT → Rate Limiting → Bot Management → Origin |
| **Partner API** (mTLS + schema) | mTLS → Schema Validation → Sequence Mitigation → Origin |
| **Internal API** (discovery + monitoring) | Discovery → Schema Learning → Auth Posture → Origin |

## OWASP API Top 10 Mapping

| OWASP Issue | API Shield Solutions |
|-------------|---------------------|
| Broken Object Level Auth | BOLA detection, Sequence, Schema, JWT, Rate Limiting |
| Broken Authentication | Auth Posture, mTLS, JWT, Credential Checks, Bot Management |
| Broken Object Property Auth | Schema validation, JWT validation |
| Unrestricted Resource | Rate Limiting, Sequence, Bot Management, GraphQL protection |
| Broken Function Level Auth | Schema validation, JWT validation |
| Unrestricted Business Flows | Sequence mitigation, Bot Management, GraphQL |
| SSRF | Schema, WAF managed rules, WAF custom |
| Security Misconfiguration | Sequence, Schema, WAF managed, GraphQL |
| Improper Inventory | Discovery, Schema learning |
| Unsafe API Consumption | JWT validation, WAF managed |

## Monitoring

- **Security Events**: Security > Events — filter Action=block, Service=API Shield
- **Firewall Analytics**: Analytics > Security — filter by `cf.api_gateway.*` fields
- **Logpush fields**: `APIGatewayAuthIDPresent`, `APIGatewayRequestViolatesSchema`, `APIGatewayFallthroughDetected`, `JWTValidationResult`, `ClientCertFingerprint`

## Availability

| Feature | Availability |
|---------|-------------|
| mTLS (CF-managed CA) | All plans |
| Endpoint Management | All plans (limited ops) |
| Schema Validation | All plans (limited ops) |
| API Discovery | Enterprise only |
| JWT Validation | Enterprise (add-on) |
| Sequence Mitigation | Enterprise (closed beta) |
| BOLA Detection | Enterprise (add-on) |
| Volumetric Abuse | Enterprise (add-on) |
| Full Suite | Enterprise add-on; 10K ops (contact for higher); non-contract preview available |
