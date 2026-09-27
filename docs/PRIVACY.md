# Privacy

Docker Codex Suite runs locally. It does not include analytics or telemetry and does not upload configuration data.

The installer never packages or uploads API keys, `auth.json`, SSH private keys, Codex sessions, logs, memories, or API profiles. During local use, the API switcher may copy the current user's Codex authentication into the selected local Docker directory when the user explicitly chooses host-API mode.

The installer does not add or modify Codex skills. Existing user-managed skills remain outside the suite's control.

The bundled Docker image downloads the Codex CLI from `https://chatgpt.com/codex/install.sh` while building. API traffic after configuration goes to the provider URL selected by the user.
