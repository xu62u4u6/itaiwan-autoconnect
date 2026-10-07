# Security and privacy boundaries

The repository contains application source, synthetic tests, and general documentation. Runtime credentials, addresses, device identifiers, Tailscale IPs, mail queues, logs, local validation history, and compiled executables are excluded from Git. Git ignore rules are a safeguard; inspect every staged change before publishing. Private repositories still grant access to authorized collaborators and the hosting provider.

## Network behavior

- Only exact SSID `iTaiwan` is eligible for automatic consent. Other connected Wi-Fi networks are preserved.
- Internet probing uses Microsoft HTTP endpoints. On captive Wi-Fi, HTTP metadata and redirects can be visible or modified by the local network. These probes do not send Gmail credentials.
- Consent pages use validated HTTPS endpoints on `auth.itaiwan.gov.tw`. POST destinations are limited to the supported HiNet endpoint and the exact hospital context validated from the official page. Institutional continuation is limited to the known hospital switch HTTPS URL. Unknown URLs and JavaScript are never executed.
- Institutional client identity is matched to the connected Wi-Fi adapter before submission. Context is obtained anew and not persisted. Device/AP parameters are transmitted to the official authentication service as part of the normal login flow.
- Certificate validation remains enabled. An expired or invalid gateway certificate can block authentication; a successful form submission alone does not prove internet recovery.
- Gmail SMTP uses TLS and the locally configured sender/recipient. Optional notification bodies contain connectivity events. Tailscale status is queried locally; the program does not change VPN settings.
- Requests follow Windows routing. If another interface or VPN exit provides connectivity, a successful probe does not prove authentication on a particular Wi-Fi adapter.

## Local permissions and recovery

The application runs as the current Windows user. Gmail application passwords use Windows DPAPI encryption for that user. Software or malware with the same user privileges can potentially read and decrypt them; this is not a protection against a compromised Windows account. Treat the local data directory as private, including encrypted credentials and mail queues.

The native launcher embeds code files only. It repairs missing files with byte/hash verification, at most once per file during one launcher lifetime, and logs the action. Repeated removal stops recovery rather than overriding a security product indefinitely. The program does not add antivirus exclusions, change OS security settings, or suppress TLS certificate checks. Manual stop and uninstall remain respected. Removal of the native EXE itself cannot be repaired by a process that no longer runs.

Builds are unsigned local Windows applications and may trigger security warnings. Build from source you trust, inspect changes, and verify output hashes. No automatic GitHub download/update mechanism is implemented.

To report a problem, share sanitized error types and versions. Do not upload settings.json, outbox files, complete authentication URLs, hardware addresses, IPs, or application passwords.
