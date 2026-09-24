# Agent Guidance

## Documentation

`DOCUMENTATION-STANDARD.md` is the canonical style guide for BARCH
documentation. Apply its reader-first rules to README files and other project
documentation.

### Write for the reader

- Start with what the feature does and how the reader uses it.
- Explain the user-visible consequence before implementation details.
- Include details that affect configuration, API usage, performance,
  permissions, failure handling, recovery, or data safety.
- Omit implementation details that do not change what the reader should do.
- Make the opening paragraph and headings describe the feature, task, or
  behavior. Keep examples close to the rules they demonstrate.

### Use direct prose

- Use ordinary English, complete sentences, active verbs, and concrete
  instructions such as “use,” “set,” and “call.”
- State behavior directly instead of building a sentence from rejected
  interpretations or implementation terminology.
- Explain defaults, limits, prerequisites, version-specific behavior, and
  failure or recovery steps explicitly.
- Use negative wording only when it prevents a realistic mistake or explains
  an observable failure, action, permission, or recovery decision.

### Avoid contrastive noise

- Do not stack `not`, `never`, `rather than`, `instead of`, or `there is no`
  clauses to anticipate every possible misunderstanding.
- Before keeping a contrast, ask whether the reader must choose between the
  two options and whether the distinction changes a command, setting, result,
  permission, or recovery step.
- If a direct description is equally accurate, use the direct description.
- When a contrast is necessary, name the practical choice and its consequence
  instead of listing rejected interpretations.
- Do not repeat the same warning in multiple sections. Explain it where the
  feature is defined and refer to it elsewhere if needed.

### Preserve technical accuracy

- Describe the behavior in the checked-out source, not a familiar feature or
  an earlier design.
- Check command syntax, reply shapes, defaults, limits, status output, and
  error text against the implementation or tests.
- Preserve command names, setting keys, paths, identifiers, ACL categories,
  and literal error messages exactly. Do not turn an ignored option into a
  promised behavior.

### Format clearly

- Put commands, settings, paths, function names, identifiers, and exact
  replies in backticks. Use fenced blocks for multi-line examples.
- Keep tables concise but complete. Include requiredness, defaults, valid
  values, and important failure modes when they affect usage.
- Keep example comments useful and explain why a step matters rather than
  restating the code.
- Keep prose near 80 columns when practical. Do not reflow tables, command
  blocks, or code examples just to meet that limit.

### Review before finishing

- Read the page as a user who has not seen the implementation.
- Search for new contrast terms such as `not`, `never`, `rather than`, and
  `instead of`; keep each only when it protects a user decision or explains a
  real failure mode.
- Check examples against the documented syntax and relevant tests.
- Confirm that links, anchors, code blocks, and tables still render.
- Run `git diff --check` and an appropriate document validation check.
- Make the smallest language-only change that improves clarity. Do not add
  behavior, compatibility claims, or undocumented assumptions while editing
  documentation.
