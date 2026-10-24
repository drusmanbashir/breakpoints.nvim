# breakpoints.nvim modules

Scope: `lua/`, `plugin/`, `tests/`

## Entry points

- `plugin/breakpoints.lua`: load once and configure default editor behavior.
- `lua/breakpoints/init.lua`: public store API, setup, optional host attachment, F2/F3/clear/properties mappings and redraw.

## Libraries (import, not run)

- `lua/breakpoints/storage/bp_file.lua`: locked language-folder store, one-time folder copy, nested snapshots and atomic writes.
- `lua/breakpoints/storage/bp_language.lua`: deterministic filetype-to-folder mapping.
- `lua/breakpoints/storage/bp_merge.lua`: merge moved marks and rename records without losing IDs.
- `lua/breakpoints/storage/bp_record.lua`: breakpoint records, IDs, properties and refusals.
- `lua/breakpoints/storage/bp_space.lua`: refreshed Git project boundaries and no-project buckets.
- `lua/breakpoints/storage/breakpoints_store.lua`: editor mutations, marks, native change signals and recovery.
- `lua/breakpoints/breakpoints/bp_marks.lua`: saved-intent sign extmarks.
- `lua/breakpoints/breakpoints/bp_editor.lua`: native properties box, validation, save and close.
- `lua/breakpoints/ui/gutter_hover.lua`: shared non-focusable gutter tooltip host.

## Tests

- `tests/breakpoints_test.lua`: G1 headless integration of the standalone public API, mappings, store, migration, rename, save merge and event payloads; private XDG required. Optional `BP_TEST_CASE=existing|copy-failure` selects migration boundaries.
