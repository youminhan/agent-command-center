# Security policy

## Supported versions

Security fixes go into the latest release. Please update before reporting.

## Reporting a vulnerability

Please **don't open a public issue** for security problems.
Report them privately through
[GitHub security advisories](https://github.com/youminhan/agent-command-center/security/advisories/new).

Include what you found, how to reproduce it and the impact you expect. You'll get a reply within a week,
and credit in the release notes if you'd like.

## Scope

Agent Command Center runs a local server on `127.0.0.1` and reads tmux and Copilot CLI data on your Mac.
Of particular interest:

- Ways for a website or another user to reach or drive the local server
- Command injection through session names, folders or settings
- Anything that deletes or exposes data without the user asking
