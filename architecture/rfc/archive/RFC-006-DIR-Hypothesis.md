# RFC-006: The Intermediate Representation Hypothesis

```
RFC:           RFC-006
Title:         The Intermediate Representation Hypothesis
Status:        Accepted
Author:        Principal Architect
Created:       2026-06-25
Target DAS:    DAS-001 (P1 amendment), DAS-002 (DIR definition)
```

## Abstract

This RFC investigates whether Decode's canonical asset is an Intermediate Representation. It compares two architectures: (A) Knowledge Units → Intelligence → Retrieval, and (B) Repository → DIR → Passes → Indexes → Retrieval → Context → Backends. Architecture B is found superior on every criterion: extensibility, maintainability, replaceability, AI integration, future capabilities, incremental updates, performance, and long-term stability.

## Decision

The DIR (Decode Intermediate Representation) is Decode's canonical asset. The pipeline architecture (Frontends → DIR → Passes → Indexes → Retrieval → Context Assembly → Backends) replaces the monolithic "Intelligence" framing.

## Incorporation Status

Fully incorporated into [DAS-002: Decode Intermediate Representation](../das/DAS-002-Decode-Intermediate-Representation.md).

DAS-001 P1 requires amendment from "Intelligence Is the Canonical Asset" to "The DIR Is the Canonical Asset." This amendment is pending.

*Full analysis available in the RFC discussion record.*
