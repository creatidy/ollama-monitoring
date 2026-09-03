# Contributing

This project is intentionally small and passive. Keep native Ollama on
`:11434`, do not add an inference proxy, and do not put request content into
metrics or fixtures.

## Repository Topology

Canonical development, branch history, merges, tags, and releases happen in
[Forgejo](https://forgejo.creatidy.com/BioMedical-IT/ollama-monitoring). GitHub
is the [public push mirror](https://github.com/creatidy/ollama-monitoring) and
its Issues are the easiest public issue-reporting channel. Do not expect a
change merged only on GitHub to become authoritative history. GitHub pull
requests may be used as contribution intake; accepted changes will be
integrated into Forgejo by the maintainer. A public Forgejo account is not
required to report an issue.

## Test Locally

Run the offline suite with:

```bash
./bin/test
```

With a running native Ollama and monitoring stack, the additional checks are:

```bash
./bin/test --live
./bin/test --security
./bin/test --restart
```

`./bin/test --observe-client` opens a passive operator window and never sends
an inference request. `./bin/test --kilo` uses the same harness with Kilo's
instruction text.

## Parser Fixtures

The parser targets non-public llama.cpp/Ollama journal shapes. To propose a
new Ollama version:

1. Capture only sanitized operational lines from the `ollama.service` journal.
   A focused command such as `journalctl -u ollama.service -b -o cat` piped
   through a strict timing-line filter is safer than submitting a raw journal.
2. Inspect every selected line manually. Remove prompts, responses, tool
   arguments, model paths, hostnames, usernames, IP addresses, and tokens.
3. Add the line to the smallest relevant file in `tests/fixtures/`.
4. Add a case to `tests/gen_tests.py` with exact parsed fields and metric probes.
5. Run `python3 tests/gen_tests.py` and the Vector fixture tests through
   `./bin/test`.

Never submit prompt or response content, raw journal dumps, credentials, or
private machine details.

## Pull Requests

Include the following information for parser compatibility work:

* Ollama version
* distro, WSL status, and relevant systemd/Docker versions
* relevant sanitized log shapes, with no request content
* exact test result from `./bin/test` and any live checks that were run

If a format is uncertain, prefer a narrowly scoped fixture and an explicit
parser branch over a permissive regex.
