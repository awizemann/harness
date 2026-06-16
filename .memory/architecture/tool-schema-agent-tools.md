---
title: Tool Schema & Agent Tools
type: note
permalink: harness/architecture/tool-schema-agent-tools
tags:
- tools
- agent-schema
source_sha: 60fdd16d416f309f12ae6e82aeb563813cbd19c7
source_paths: Harness/Tools/AgentTools.swift, docs/PROMPTS/
---

## Observations
- [design] AgentTools.swift (Harness/Tools/): toolDefinitions(cacheControl:) returns Anthropic-formatted tool schema. Tools available on all three platforms: tap_mark(id), tap(x,y), swipe(x1,y1,x2,y2), scroll(direction,amount), type(text), key(name), fill_credential(field), navigate(url, web-only), mark_goal_done(success,reason), note_friction(kind,description). #schema
- [design] tap_mark(id) is preferred when Set-of-Mark badges are present. Falls back to tap(x,y) for unmarked content. Agent receives behavior reminder per turn. #targeting
- [design] Multi-tool emissions accepted: one action tool + zero or more note_friction inline in same response. Parsers split action vs friction and forward inline frictions through AgentDecision.inlineFriction → JSONL friction rows. #parsing
- [design] fill_credential(field: 'username'|'password') tool. Password bytes never enter model context or JSONL log — tool_call.input for password fills records only {'field':'password'}, no value. #security
- [design] note_friction(kind, description): agent-flagged friction events. Kinds: ui_ambiguity, dead_end, unresponsive, auth_required, navigation_blocked, input_error, other. Recorded inline in JSONL. #friction

## Relations
- relates_to [[Agent Loop Core Mechanism]]
- relates_to [[Run Logging Format (JSONL v2+)]]
