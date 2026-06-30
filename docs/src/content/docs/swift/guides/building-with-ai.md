---
title: Building with an AI assistant
description: How to point any AI coding assistant at the AgentSquad Swift skill file so it works with real API signatures and avoids common pitfalls.
---

The repo ships `SKILL.md` — a single, assistant-agnostic guide at the root of the `swift/` directory.
It covers:

- **Mental model** — when to reach for `Agent` vs. `GroundedAgent`, single-agent vs. classifier routing, text vs. voice
- **Real API signatures** — `Orchestrator`, `Agent`, `GroundedAgent`, `LLMClassifier`, `ChatCompletionsClient`, storage and tracing types
- **Module map** — what each import (`AgentSquad`, `AgentSquadMCP`, `AgentSquadAudio`) pulls in
- **Task recipes** — the `AsyncThrowingStream<AgentEvent, any Error>` loop, routing between agents, wiring tools, custom protocol conformances
- **Gotchas** — `maxToolRounds` defaults, `JSONValue` integer decoding, storage scoping, tracing lifecycle, realtime teardown

## Pointing your assistant at SKILL.md

Tell your assistant once, before it writes any AgentSquad code:

> *Read `SKILL.md` before writing any AgentSquad code.*

That is all. The file is self-contained — no context beyond it is required.

This works with any assistant: Claude, Cursor, GitHub Copilot, or anything else that can read a file.

## Claude Code: install as a skill

Claude Code users can register `SKILL.md` so it is loaded automatically whenever the assistant works on AgentSquad code. Copy the file into your project's skills directory:

```bash
mkdir -p .claude/skills/agent-squad-swift
cp swift/SKILL.md .claude/skills/agent-squad-swift/SKILL.md
```

After that, Claude Code picks it up without an explicit instruction on every session.

:::note
The skill is not installed automatically. You must copy the file as shown above.
:::

## What SKILL.md does not replace

`SKILL.md` is guidance and a map, not an API reference. It tells you *what to use, when, and what to watch out for*. For exact signatures, read the sources under `swift/Sources/AgentSquad/`. For worked examples, see the rest of this doc site — in particular:

- [Orchestrator](/agent-squad/swift/orchestrator/overview/) and [Agents](/agent-squad/swift/agents/overview/) for the core turn loop
- [GroundedAgent](/agent-squad/swift/agents/built-in/grounded-agent/) for the Brain → Presenter anti-hallucination pattern
- [Classifiers](/agent-squad/swift/classifiers/overview/) for multi-agent routing
- [Tools](/agent-squad/swift/tools/overview/) and [MCP tools](/agent-squad/swift/mcp/overview/) for tool wiring
- [LLM clients](/agent-squad/swift/llm/overview/) for pointing `ChatCompletionsClient` at any OpenAI-compatible endpoint
- [Chat history](/agent-squad/swift/storage/overview/) for on-device persistence
- [Tracing](/agent-squad/swift/tracing/overview/) for span export
- [Realtime voice](/agent-squad/swift/voice/overview/) for `VoiceAssistant` setup
