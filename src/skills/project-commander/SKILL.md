---
name: project-commander
description: Route work for Docker-hosted Codex projects through exactly one persistent commander conversation per project. Trigger on conversational commands such as `/list`, `/projects`, `/new`, `/project`, `/status`, `/send`, and `/help`, or natural-language requests to create, inspect, modify, test, manage, list, or discuss projects under the Docker Codex workspace. Discover and link an existing named commander by both thread name and project path; for a new project, create its named workspace folder first, initialize the project there, and only then create its commander.
---

# Project Commander

Use `scripts/project-commander.ps1` as the only entry point for work in the Docker Codex project workspace.

## Conversation protocol

Treat these as user-facing chat commands even when the desktop app sends them as ordinary text:

- `/list` or `/projects`: Run the gateway with `-ListProjects`. List projects and commander state without creating anything.
- `/new <name>`: Run the gateway with `-NewProjectName`. Create `/workspace/Documents/<name>` first, initialize Git in that folder, then create and name its commander. Refuse when the folder already exists.
- `/project <name>`: Resolve one exact project, connect its commander, or create one if absent. Keep that project selected for later messages in the current outer conversation.
- `/status <name>`: Resolve the project with `-NoCreate` and report its current commander mapping. Do not send a model turn.
- `/send <name> <instruction>`: Resolve the exact project and send the full instruction to its commander.
- `/help`: Return this command list without calling Docker.

For ordinary natural language, infer the same operation only when the project is unambiguous. If a basename matches multiple paths, list the candidates and ask for the exact path.

## Required workflow

1. Resolve the exact container project path. Never infer a project from a similar basename.
2. For a new project, create the exact named folder under `/workspace/Documents`, verify it exists, initialize Git, and only then continue. Never create a commander for a missing folder.
3. Run the gateway with that path and the user's complete message.
4. Let the gateway inspect existing thread names and `cwd` values.
5. Link an existing commander when its name and project path match. Do not rename it.
6. Create a commander only when no matching commander exists. New commanders use `总指挥｜<project-name>`, with a short path hash only when that name is already used by another project.
7. Report whether the gateway created the project folder and whether it linked, adopted, reactivated, or created the commander, followed by the commander's response.

## Safety rules

- Do not edit the Docker project directly from the outer Codex task.
- Do not treat a nonexistent path as a project. Use `-NewProjectName` so folder creation, Git initialization, and commander creation occur in that order.
- Reject project names containing path separators, Windows-invalid filename characters, traversal names, reserved device names, or trailing dots/spaces.
- Do not use `codex exec --last`; always target the resolved thread ID.
- Always pass the exact project `cwd` on every resumed turn.
- Pass prompts through stdin-safe transport; never interpolate user text into a shell command.
- Serialize turns per commander. If multiple commander candidates match one project, stop and report their names and IDs.
- Use `read-only` for inspection and discussion. Use `workspace-write` only when the user asks to change the project.
- Never use `danger-full-access` through this skill.

## Commands

Resolve or create without sending a project task:

```powershell
& "$PSScriptRoot/scripts/project-commander.ps1" -ProjectPath "/workspace/Documents/example"
```

List projects without creating commanders:

```powershell
& "$PSScriptRoot/scripts/project-commander.ps1" -ListProjects
```

Create a new project folder, initialize Git, and create its commander:

```powershell
& "$PSScriptRoot/scripts/project-commander.ps1" -NewProjectName "example"
```

Send a read-only request:

```powershell
& "$PSScriptRoot/scripts/project-commander.ps1" -ProjectPath "/workspace/Documents/example" -Sandbox read-only -Message "Inspect the repository and report its status."
```

Send an implementation request:

```powershell
& "$PSScriptRoot/scripts/project-commander.ps1" -ProjectPath "/workspace/Documents/example" -Sandbox workspace-write -Message "Implement the requested change and run focused tests."
```

When the user identifies an existing commander by name, pass `-CommanderName` exactly. Use `-AdoptThreadId` only for a thread already verified in the current run whose role is known but whose name is missing.
