# NeuralTrust Shared Workflows

This repository contains reusable GitHub Actions workflows for the NeuralTrust organization.

## Available Workflows

### 1. Auto Approve PR

Automatically approves pull requests when all CI checks pass.

### 2. AI Code Review

Uses OpenAI GPT-4 to review code changes and post comments with suggestions.

## Quick Start

Add this workflow to any repository:

```yaml
# .github/workflows/pr-automation.yml
name: PR Automation

on:
  pull_request:
    types: [opened, synchronize, ready_for_review]

jobs:
  # AI Code Review - runs immediately on PR
  ai-review:
    uses: NeuralTrust/workflows/.github/workflows/ai-code-review.yml@main
    secrets: inherit

  # Auto Approve - waits for all CI to pass
  auto-approve:
    uses: NeuralTrust/workflows/.github/workflows/auto-approve.yml@main
    secrets: inherit
```

## Workflow Details

### Auto Approve (`auto-approve.yml`)

Waits for all CI checks to pass, then automatically approves the PR.

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `approve_message` | string | `Auto-approved...` | Message in approval |
| `timeout_seconds` | number | `900` | Max wait time |

**Required Secrets:**
- `GH_TOKEN` - GitHub token with `repo` permissions

---

### AI Code Review (`ai-code-review.yml`)

Reviews PR changes using OpenAI and posts a detailed comment.

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `model` | string | `gpt-4o` | OpenAI model |
| `max_files` | number | `20` | Max files to review |
| `language` | string | `english` | Review language |

**Required Secrets:**
- `OPENAI_API_KEY` - OpenAI API key

**What it reviews:**
- 🐛 Bugs & potential issues
- 🔒 Security vulnerabilities
- ⚡ Performance concerns
- 📝 Code quality & best practices
- 💡 Improvement suggestions

---

## Setup

### 1. Organization Secrets

Go to `github.com/organizations/NeuralTrust/settings/secrets/actions` and ensure these secrets exist:

| Secret | Description |
|--------|-------------|
| `GH_TOKEN` | GitHub token with `repo` scope (for approving PRs and commenting) |
| `OPENAI_API_KEY` | OpenAI API key (for AI reviews) |

### 2. Add to Repositories

Add the caller workflow to each repository's `.github/workflows/` directory.

## Workflows Reference

| Workflow | Description | Required Secrets |
|----------|-------------|------------------|
| `auto-approve.yml` | Approves PRs when CI passes | `GH_TOKEN` |
| `ai-code-review.yml` | AI-powered code review | `OPENAI_API_KEY`, `GH_TOKEN` |

## Example PR Comment

When a PR is opened, the AI will post a comment like:

> ## 🤖 AI Code Review
>
> ### Summary
> This PR adds a new authentication middleware...
>
> ### Issues Found
> - **Line 45**: Potential SQL injection vulnerability
> - **Line 123**: Missing error handling
>
> ### Suggestions
> - Consider using parameterized queries
> - Add rate limiting to prevent abuse
>
> ---
> <sub>Powered by OpenAI gpt-4o | NeuralTrust</sub>
