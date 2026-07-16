# Security Policy

## Supported source state

Security updates currently focus on the `main` branch and the latest publicly available source state. This source-only project does not yet publish an official signed or notarized binary release.

## Untrusted input

Treat MDX, MDD, HTML contained in dictionary entries, and other imported files as untrusted input. Import only dictionaries from sources you understand and have permission to use. A file being readable by LocalDictionary does not establish that it is safe or legally redistributable.

## Reporting a vulnerability

Please report security vulnerabilities privately to:

**cunqiuqingling@gmail.com**

A useful report should include, where possible:

- the affected commit or source version;
- minimal reproduction steps;
- expected behavior;
- actual behavior;
- a synthetic, minimal test file rather than a commercial dictionary;
- logs stripped of private information.

Do not submit the following through a public Issue:

- API Keys, Authorization Headers, or Keychain contents;
- commercial dictionaries or commercial entry text;
- user-specific absolute paths;
- private Obsidian notes or other personal documents.

The project will never ask for a complete API Key. There is currently no vulnerability bounty program and no fixed response SLA, but reports will be acknowledged and handled on a best-effort basis. The project makes no claim of formal security certification, independent security audit, or verified cryptographic assurance.
