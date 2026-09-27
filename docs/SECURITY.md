# Security

- SSH is bound to `127.0.0.1` only.
- The installer generates a unique Ed25519 key on each machine and never bundles a private key.
- The Docker service uses `SYS_ADMIN` and `seccomp=unconfined` to support nested Codex sandboxing. Treat the selected workspace directory as accessible to the container.
- API profiles and copied authentication files are local secrets. Do not publish the installed `data`, `.env`, or `codex-home` directories.
- The installer does not install or replace Codex skills. Existing user-managed skills remain untouched.
- Public release binaries should be Authenticode-signed. Unsigned development builds can trigger Microsoft Defender SmartScreen.

Report security issues privately to the distributor of the build.
