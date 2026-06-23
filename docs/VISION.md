# Decode — Product Vision and Philosophy

> This document captures the current product vision and philosophy. It is intentionally implementation-agnostic. The codebase and future architectural decisions are the source of truth for implementation. If implementation and this document diverge, the implementation takes precedence until this document is updated.

---

## Mission

Decode helps developers understand unfamiliar code the same way an experienced senior engineer would.

The mission is not to parse code, build graphs, or produce metadata. The mission is understanding.

---

## Core Philosophy

**Understanding, not analysis.** Decode's value is not in extracting facts from code. IDEs already do that. Decode's value is in synthesizing facts into the kind of understanding that an experienced engineer builds naturally — purpose, behavior, risk, design intent — and delivering it at the moment a developer needs it.

**Information density over narration.** Explanations should tell the developer what they cannot learn from reading the code themselves. Obvious observations waste the developer's time. The goal is insight per sentence.

**Capability-first, technology-second.** Product decisions are driven by what understanding developers need, not by what tools can extract. Technology choices serve capabilities, not the reverse.

---

## How Decode Works

Decode has three interaction modes. Each captures code differently, but all share the same goal: help the developer understand what they're looking at.

**Selection Mode** — The developer highlights code in any editor and presses a hotkey. Decode captures the selected text and explains it. This is fast, contextless, and works everywhere. The explanation is based solely on the selected code.

**Screenshot Mode** — The developer presses a hotkey and drags to select a screen region. Decode performs OCR on the captured image and explains the recognized code. This works when text selection is not available (images, videos, locked interfaces).

**Session Mode** — The developer opens a source file in Decode, creating a persistent session. Then they highlight code in their editor and press a hotkey. Decode identifies which session the snippet belongs to, builds structural context from the parsed file, and explains the snippet in the context of the full file. Session Mode is where Decode's deeper understanding lives.

The fundamental difference between Selection Mode and Session Mode is context. Selection Mode explains code in isolation. Session Mode explains code in context — the context of the file's structure, purpose, and behavior. This contextual understanding is what separates "what does this code do?" from "why does this code exist and how does it fit?"

---

## The Understanding Model

When an experienced engineer opens an unfamiliar source file, they don't read top-to-bottom. They build understanding in layers, starting with orientation and progressively deepening.

Decode's understanding model mirrors this process.

### Identity

What is this file? Where does it live? What language? What do the name and location tell you about its role before reading a single line of code?

### Purpose

Why does this file exist? What is its specific job? Every well-designed file has one reason to exist. Purpose is the anchor for all subsequent understanding. Without it, every function is disconnected detail. With it, every detail clicks into a coherent story.

### Responsibilities

What distinct jobs does the file perform? Not individual functions — the conceptual responsibilities. Understanding responsibilities tells you the scope of the file and, equally important, what the file does not do.

### Structure

What types and APIs does the file define? How is it organized? What vocabulary does it introduce to the codebase? Structure reveals the author's mental model.

### Behavior

How do the file's parts work together at runtime? Which functions call which? How does data move from entry points to outputs? Where does state change? What side effects occur? Behavior connects static structure to dynamic execution.

### Safety

What could go wrong? How does the file handle errors? Is concurrent access safe? What does the code assume but not verify? Safety is where engineering experience is most valuable — noticing risks that less experienced developers miss.

### Design

What patterns does the file follow? How do its types relate conceptually? Which parts are central to its purpose and which are supporting infrastructure? Design understanding provides the mental model that makes the file navigable.

---

### What Understanding Is Not

Understanding is not line-by-line narration. It is not style commentary. It is not refactoring advice (that is a separate feature). It is not performance analysis.

Understanding is the mental model a senior engineer builds — the one that lets them say "I know what this file does, how it works, and where to be careful."

---

## Evolution

Decode's understanding deepens incrementally across four phases. Each phase expands the scope of context without requiring the previous phase to be rebuilt.

**File Intelligence** — Understanding one file in isolation. Everything a senior engineer discovers by reading a single unfamiliar source file. Structure, purpose, behavior, safety, design. This is the foundation.

**Module Intelligence** — Understanding how related files work together. Cross-file dependencies, shared data flow, the API contracts between files. A file's purpose becomes clearer when you see what calls it and what it calls. This is the context that transforms isolated file understanding into connected understanding.

**Project Intelligence** — Understanding the whole codebase as an architecture. Module boundaries, dependency direction, architectural patterns, design rules. A file's role becomes fully clear when you see the system it serves. This is the perspective that lets an engineer navigate an unfamiliar codebase with confidence.

**Living Intelligence** — Understanding that stays current as the codebase evolves. Continuous background analysis, change impact awareness, evolving insights. This is the state where Decode understands the codebase as well as the engineers who built it.

Each phase naturally composes from the phase below. Module Intelligence aggregates File Intelligence. Project Intelligence aggregates Module Intelligence. No phase requires rearchitecting a previous phase.

---

## What Decode Does Not Do

Decode does not replace the developer's judgment. It provides understanding — the developer decides what to do with it.

Decode does not generate code (except through the Improve Code feature, which is a separate, post-explanation workflow).

Decode does not require developers to configure AI providers or API keys. The product handles AI access through a server-side gateway.

Decode does not require integration with the developer's editor, build system, or version control. It works with any editor through system-level text capture.
