# NOOP scoring-precision research

A multi-lens research pass on how NOOP's five score families **should** be computed and presented — grounded in physiology/medical literature, how Oura and WHOOP actually do it (published methodology only), and an audit of NOOP's current Swift. Generated 2026-07-13.

## Start here

- **[roadmap.md](roadmap.md)** — the program map. The thesis (five scores are ~8 shared machines), a recurrence matrix, 12 governing principles, a sequenced backlog ranked by (impact×confidence)/effort, and a validation strategy against ~2yr of Oura history.

## Per-score methodology

Each doc = target methodology (how it should be computed + presented, cited) + gap analysis vs NOOP today + an actionability rubric + ranked recommendations.

- [stress-methodology.md](stress-methodology.md)
- [sleep-methodology.md](sleep-methodology.md)
- [recovery-methodology.md](recovery-methodology.md)
- [readiness-methodology.md](readiness-methodology.md)
- [trends-methodology.md](trends-methodology.md)
- [all-recommendations.md](all-recommendations.md) — every recommendation, impact-sorted.

## Research appendices

Raw per-lens findings (science/medical, competitive Oura/WHOOP, NOOP code audit, adversarial verification) with source URLs, per score: `*-research-appendix.md`.

## Discipline

- Vendor methodology is **published-only**; proprietary details are marked UNKNOWN, never invented.
- Correlation to Oura is a **regression net and directional test, not the objective function** — matching WHOOP is equally acceptable (NOOP is a WHOOP companion). The goal is rigorous, actionable methodology.
- Every new derived signal must **track a varying input** before it gates or defaults anything.

## Status

The **Wave 0** slice ("wire the rigorous methodology that's already written but disconnected" + free honesty fixes) is the first implementation sub-project; see its spec under `docs/scoring-precision/wave-0-spec.md` once written.
