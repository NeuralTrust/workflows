# DAST (Dynamic Application Security Testing)

The **`dast.yml`** reusable workflow runs [OWASP ZAP](https://www.zaproxy.org/) against a **running** application (API or frontend). Unlike SAST, DAST needs a live URL to scan.

## When to use DAST

- **APIs** that require **JWT** (or Bearer) auth — ZAP sends the token on every request so protected endpoints are scanned.
- **Frontends** (many screens) — ZAP spiders from the base URL and scans discovered pages. For login-protected UIs, use JWT if your app uses it for API calls, or see [Form-based login](#form-based-logend-login) below.

Run DAST **after deploy** (e.g. `needs: deploy`) so the target URL is live (e.g. `https://api.dev.example.com` or `https://app.dev.example.com`).

---

## API with JWT auth

You can provide the JWT in two ways.

### Option 1: JWT from a secret (e.g. long-lived test token)

Use a dedicated DAST token stored in GitHub Secrets (e.g. `DAST_JWT_TOKEN`).

```yaml
jobs:
  deploy:
    uses: NeuralTrust/workflows/.github/workflows/docker-build-deploy.yml@main
    # ...

  dast:
    needs: deploy
    uses: NeuralTrust/workflows/.github/workflows/dast.yml@main
    with:
      target_url: https://api.dev.example.com
      auth_method: jwt_static
    secrets:
      JWT_TOKEN: ${{ secrets.DAST_JWT_TOKEN }}
```

### Option 2: JWT from login endpoint (recommended)

Obtain a fresh token by calling your login API with test credentials. The workflow POSTs to `auth_login_url` with the body you specify and extracts the JWT using a jq path.

```yaml
  dast:
    needs: deploy
    uses: NeuralTrust/workflows/.github/workflows/dast.yml@main
    with:
      target_url: https://api.dev.example.com
      auth_method: jwt_login
      auth_login_url: https://api.dev.example.com/auth/login
      auth_login_body: '{"username":"{{USERNAME}}","password":"{{PASSWORD}}"}'
      jwt_response_path: .access_token   # or .token, etc.
    secrets:
      AUTH_USERNAME: ${{ secrets.DAST_TEST_USER }}
      AUTH_PASSWORD: ${{ secrets.DAST_TEST_PASSWORD }}
```

- **`auth_login_body`**: Use placeholders `{{USERNAME}}` and `{{PASSWORD}}`; they are replaced with the secret values.
- **`jwt_response_path`**: jq path into the JSON response (e.g. `.access_token`, `.token`, `.data.jwt`).
- **`auth_login_content_type`**: Default `application/json`; set if your login expects something else.

ZAP then sends `Authorization: Bearer <token>` on every request so all protected API methods are scanned.

---

## Frontend (many screens)

Point ZAP at the app’s base URL. ZAP will spider and scan discovered pages.

- **No auth or same JWT**: If the frontend is public or uses the same JWT for API calls, use `auth_method: jwt_static` (or `none`) and pass `JWT_TOKEN` if needed.
- **Form-based login**: The baseline workflow does not perform form login. Two options:
  1. **Same JWT**: If the app ultimately uses a JWT (e.g. after form login), you can obtain that JWT via your login API and use `auth_method: jwt_login` with the same inputs as for the API; ZAP will send the token on requests.
  2. **Full form-based auth**: Use [ZAP Automation Framework](https://github.com/zaproxy/action-af) (`zaproxy/action-af`) with a plan that defines form-based authentication and logged-in indicators. That is more setup but covers classic username/password UIs.

To increase coverage for “lots of screens”, you can:
- Rely on ZAP’s spider to discover routes from the base URL.
- Run the workflow against a staging URL that already has a sitemap or many links so more pages are discovered.

---

## Inputs and secrets

| Input | Default | Description |
|-------|---------|-------------|
| `target_url` | *(required)* | Base URL to scan (e.g. API or frontend root). |
| `auth_method` | `none` | `none`, `jwt_static` (token from secret), or `jwt_login` (obtain from login endpoint). |
| `auth_login_url` | `''` | When `jwt_login`, URL to POST for login. |
| `auth_login_body` | `{"username":"{{USERNAME}}","password":"{{PASSWORD}}"}` | Request body; use `{{USERNAME}}` and `{{PASSWORD}}`. |
| `auth_login_content_type` | `application/json` | Content-Type for the login request. |
| `jwt_response_path` | `.access_token // .token` | jq path to extract JWT from login response. |
| `severity_threshold` | `high` | Fail the job if any finding has this severity or higher. |
| `additional_urls` | `''` | Comma-separated extra URLs to include (optional). |

| Secret | When | Description |
|--------|------|-------------|
| `JWT_TOKEN` | `auth_method: jwt_static` | Bearer token sent on every request. |
| `AUTH_USERNAME` | `auth_method: jwt_login` | Login username. |
| `AUTH_PASSWORD` | `auth_method: jwt_login` | Login password. |

---

## Summary

- **APIs with JWT**: Use `auth_method: jwt_login` (or `jwt_static` with a secret). ZAP adds `Authorization: Bearer <token>` so all methods are scanned.
- **Frontend, many screens**: Use `target_url` to the app root; use JWT auth if the app uses it; for full form-based login, use ZAP Automation Framework (see link above).
- Run DAST after deploy so the target URL is live; store test credentials in GitHub Secrets.
