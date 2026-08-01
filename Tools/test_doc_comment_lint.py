"""Tests for the doc-comment scanner's block-close walk.

`findings()` used to locate a block's close by looking for a line that ENDS with
`*/`. A close can carry code after it on the same line — uniffi emits parameter
docs exactly that way (`*/restored: Bool, …`) — and for those the walk ran past
its own block and stopped at the next unrelated `*/` further down the file.

That is wrong twice over, and the second half is the one that matters:

  * it reports a detached-doc finding for a block that is correctly bound to its
    parameter (a false positive — noise), and
  * it consumes every line up to that unrelated close, so a genuinely detached
    doc sitting inside the span is never examined at all (a false NEGATIVE — the
    gate silently misses the exact thing it exists to catch).

Both were visible in Strand/CloudSync/Generated/liters_ffi.swift:3325 before
`/Generated/` was scoped out of the lint; scoping the path stopped the noise but
left the walk itself unfixed, so any HAND-WRITTEN file that puts code after a
block close still hides real findings behind it.

Run: python3 -m unittest Tools.test_doc_comment_lint -v   (from the repo root)
     or: cd Tools && python3 -m unittest test_doc_comment_lint -v
"""

import sys
import tempfile
import unittest
from pathlib import Path

# Tools/ is a plain directory, not a package (no __init__.py), so `python3 -m unittest
# Tools.test_doc_comment_lint` from the repo root imports this file without putting its
# own directory on the path. Add it, so BOTH invocations above actually work.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import doc_comment_lint as dcl  # noqa: E402  (needs the path line above)


def scan(text: str) -> list[tuple[int, str]]:
    """`findings()` over a snippet. It takes a Path, so stage a temp file."""
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "Sample.swift"
        path.write_text(text.lstrip("\n"))
        return dcl.findings(path)


def flagged(text: str) -> list[int]:
    """Just the 1-indexed lines `findings()` reports, for terse assertions."""
    return [line for line, _why in scan(text)]


class StillCatchesWhatItAlwaysCaught(unittest.TestCase):
    """The regressions the gate exists for. These passed before the walk fix and
    must keep passing after it."""

    def test_blank_line_detaches(self):
        text = """
/** Persisted preferences file. */

internal let PREFS = "..."
"""
        self.assertEqual(flagged(text), [1])

    def test_stacked_blocks_report_the_first(self):
        text = """
/** Byte-parity twin of Swift `classifyCoverage`. */
/** Both platforms use the NEGATED `>` form. */
func classifyCoverage() {}
"""
        self.assertEqual(flagged(text), [1])

    def test_multiline_block_detached_by_blank_line(self):
        text = """
/**
 * Lifecycle state of one registered database.
 */

public enum DbState {}
"""
        self.assertEqual(flagged(text), [1])

    def test_bound_doc_is_clean(self):
        text = """
/** A doc that documents the thing directly below it. */
public func alpha() {}
"""
        self.assertEqual(flagged(text), [])

    def test_file_header_before_import_is_exempt(self):
        text = """
/**
 * File header, conventionally followed by a blank line.
 */

import Foundation
"""
        self.assertEqual(flagged(text), [])


class CloseWithTrailingCode(unittest.TestCase):
    """A block whose `*/` is followed by code on the same line."""

    def test_inline_parameter_doc_is_bound_not_detached(self):
        # uniffi's shape, from liters_ffi.swift:3325. The block documents
        # `restored:` and is correctly bound to it — there is nothing to repair.
        text = """
public init(
    /**
     * Whether a full restore ran (vs. incremental application).
     */restored: Bool, fromTxid: UInt64) {
    self.restored = restored
}
"""
        self.assertEqual(flagged(text), [])

    def test_single_line_doc_followed_by_code_is_bound(self):
        text = """
public func beta(/** The gamma flag. */gamma: Bool) {}
"""
        self.assertEqual(flagged(text), [])

    def test_trailing_code_does_not_swallow_a_later_real_site(self):
        # The false negative. The old walk skipped from line 2 to the `*/` on
        # line 8, consuming line 8's genuinely detached block on the way.
        text = """
public func beta(
    /**
     * Inlined parameter doc.
     */gamma: Bool) {
    _ = gamma
}

/** This one really IS detached. */

public func delta() {}
"""
        self.assertEqual(flagged(text), [8])


class Degenerate(unittest.TestCase):
    def test_unterminated_block_is_not_this_tools_business(self):
        text = """
/**
 * Never closed.
"""
        self.assertEqual(flagged(text), [])

    def test_empty_block_comment_is_not_a_doc_open(self):
        text = """
/**/

public func alpha() {}
"""
        self.assertEqual(flagged(text), [])


if __name__ == "__main__":
    unittest.main()
