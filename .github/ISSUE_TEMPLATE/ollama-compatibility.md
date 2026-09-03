---
name: Ollama compatibility or parser regression
about: Report a changed Ollama journal shape or a parser compatibility issue
title: "compatibility: "
labels: compatibility
---

## Environment

- Ollama version:
- Distribution / WSL2:
- systemd version:
- Docker and Compose versions:

## Symptoms

Describe which metrics stopped updating and whether
`ollama_journal_lines_seen_total` still increases.

## Sanitized evidence

Paste only operational timing shapes. Remove prompts, responses, tool
arguments, model paths, usernames, hostnames, IP addresses, and credentials.

## Tests

Paste the exact output counts from `./bin/test` and any applicable live test.
