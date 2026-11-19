# Evidence notes (the "i" buttons)

One short note per feature: what the research says, where the data supports it and where it does not, how the
app uses it, the sources, and the libraries and models behind it. They are written for anyone who uses the app,
not for scientists. Each feature in the pages (and in the phone app) has a small round **i** button that
opens its note.

These Markdown files are the single source. `python3 scripts/evidence_to_js.py` turns them into
`scripts/web/evidence.js` for the laptop pages; the phone app bundles these same files as assets. Edit the
note here, rerun the script, and commit both.

## Grades

Every note carries one grade: how well the evidence supports the feature **for this headband** (BrainBit
Black: four dry electrodes at O1 and O2 on the back of the head, T3 and T4 above the ears, a forehead
reference).

| Grade | Meaning |
|---|---|
| **strong** | shown repeatedly at these electrode sites or on near-identical devices |
| **some** | shown on similar devices or sites, or in one good or a few small studies; must be checked on you |
| **weak** | small, mixed, indirect or lab-only evidence, or trials where it did no better than a fake version |
| **none** | no evidence, or these electrodes cannot measure it |

When a feature has parts with different grades, the grade is for its main use and the line under it names the
weaker parts. A grade is about the evidence, not about safety: a strong measurement can still be used in a
way the research does not support, and the note says so.

## Layout of a note

```
# Title
## What it does                          1-2 lines
## Evidence for this headband: <grade>   strong | some | weak | none, then one line why
                                         (the helmet's note says "this helmet")
## What the research says                3-6 bullets, with numbers where they exist
## Where the data does not support it    bullets
## How the app uses this                 the concrete rules
## Sources                               links
## Libraries and models                  name, link, licence
Checked: YYYY-MM-DD
```

The converter accepts a small Markdown subset: `#`, `##` and `###` headings, `- ` bullets (a continuation
line is indented by two spaces), paragraphs, `**bold**`, `` `code` `` and `[text](https://...)` links. Links
must be `http` or `https` web addresses; it refuses anything else.

## Rules

- Copy every link exactly from the research it came from; never write one from memory.
- Plain words: explain any technical term in a few words the first time it appears in a note.
- This repository is public: nothing personal (no one's own recordings or results, no device serial numbers or
  addresses, no local file paths).
- Update "Checked:" when you re-read the sources for a note.
