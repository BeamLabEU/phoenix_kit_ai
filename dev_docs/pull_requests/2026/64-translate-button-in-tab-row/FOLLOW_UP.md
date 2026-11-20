# PR #64 follow-up

Claude review completed on 2026-11-16; see [the review](CLAUDE_REVIEW.md).

- **Fixed in the PR (b5f9403):** the `show_header` nitpick — the translate button's cell is now `self-end` when core's
  header is on, so it sits on the tabs' line instead of floating between header and tabs. Two tests pin it.
- **Fixed in the sibling repos (this sweep):** the MEDIUM finding — `phoenix_kit_projects`
  (`web/components/form_parts.ex`) passed `ai_row_class="flex items-center gap-3 -mt-3"` and
  `phoenix_kit_publishing` (`web/edit.ex`) passed `ai_row_class="flex items-center gap-3 -mt-2 mb-4"`. Both values
  were tuned for the old layout and pulled the progress row up into the language tabs. Both call sites now omit
  `ai_row_class` and take the component default (`"flex items-center gap-3"`, no margin of its own — see the attr doc
  in `PhoenixKitAI.Components.AITranslate`). A workspace-wide grep confirms no other consumer passes
  `ai_row_class`.
- **Resolved with the PR's gate fix:** the HIGH `hex.audit` advisory on `grpc_core` (EEF-CVE-2026-121808, via `xai`
  → `grpc`) was cleared by moving `grpc` / `grpc_core` to 1.1.0 in the lock. `mix hex.audit` is clean on current
  main.
- **Not changed:** the component still cannot undo a negative margin a host passes — class precedence follows
  stylesheet order. The attr doc now states the default carries no margin precisely so a caller's negative margin
  cannot be silently stripped.
