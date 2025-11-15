# Agent Instructions

## Zig Development

Always use `zigdoc` to discover Zig standard library APIs - assume training data is out of date.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc std.fmt.allocPrint
```

## Build Commands

- Build and run: `zig build run`
- Format code: `zig fmt .`
- Run tests: `zig build test`

## Commit Message Format

**Title (first line):**
- Limit to 60 characters maximum
- Use a short prefix for readability with git log --oneline (do not use "fix:" or "feature:" prefixes)
- Use only lowercase letters except when quoting symbols or known acronyms
- Address only one issue/topic per commit
- Use imperative mood (e.g. "make xyzzy do frotz" instead of "makes xyzzy do frotz")

**Body:**
- Explain what the patch does and why it is useful
- Use proper English syntax, grammar and punctuation
- Write in imperative mood as if giving orders to the codebase

**Trailers:**
- If fixing a ticket, use appropriate commit trailers
- If fixing a regression, add a "Fixes:" trailer with the commit id and title
