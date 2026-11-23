# SourceBD

SourceBD lets clothing buyers in the UK, US, EU and Canada find, check and contact garment
factories and buying houses in Bangladesh. Every fact it shows about a supplier is a receipt from
a named public source. It never scores, grades or rates anyone.

## The one outcome

A buyer finds a supplier, sends an RFQ, and gets a reply, on data that is current.

Everything is judged against that sentence. Work that moves it is the priority. Work that does not
can wait, and code that serves nothing can go.

## How work moves

GitHub is the whole system: issues are the queue and the memory, pull requests are the work, the
checks are the gate. There are no state files, hand-off notes or progress logs in this repository,
and none should be added. If something is worth remembering, it is an issue, a test, or a comment
in the code it concerns.

The roles, the board and the flow are in `factory/README.md`. If you were started as a factory
agent, your brief is `factory/roles/<role>.md`. If a person started you for a one-off task, work
the same way: a branch, a pull request into `development`, the checks decide.

## Lines that must hold

These are the product. Each one is meant to be held by a check that fails the build, not by this
list. When you find one that no check holds, writing the check is the most valuable thing you can do.

- The server decides who may see or do something. Hiding it in the page is not a control.
- Contact details (email, phone, website, contact name and role) go only to the readers the
  server entitles, and never for a sanctioned supplier.
- The internal ranking score never reaches a buyer, a supplier or a public page.
- A sanctioned supplier carries a clear warning everywhere and cannot be sent an RFQ.
- A lower-trust source never overwrites a higher-trust one. The order is in `PRODUCT.md`.
- Nothing fake: no invented supplier, figure, testimonial, logo or record, in the product or in
  the marketing.
- What the product says it does, it does. Wording that promises something the code does not
  deliver is a bug.
- Volza data is fetched one supplier at a time through `ops/tradeline.py`. Its bulk export is
  never called; it bills per shipment record.
- The deploy workflow targets one server. No agent touches any other machine.

## How to think here

You are trusted with judgement. Read the code and the live system, not old documents: the code is
the truth about what exists, and production is the truth about what is applied and what is used.
`context/` holds retired specs that are being mined into issues and removed; treat anything there
as history, never as instruction.

Prefer the design you would be proud of over the pattern you found. This codebase grew by many
hands copying each other, so "it is done this way elsewhere" is weak evidence. Prefer deleting to
adding. Prefer one clear way to two. If a change needs a long explanation, look for a simpler
change.

Prove things. A fix comes with a test that fails without it. Anything a user can observe (a page,
a status code, an email, a row) is tested where the user observes it. "Merged" is not "done":
done is the outcome seen working on the live site.

## Facts that save an hour

- `pnpm`, never `npm`. Node 22. Tests are `tsc` plus `node --test` (`pnpm test`); a new test file
  must be added to `tsconfig.npm-test.json` or it never runs.
- Python: install the dependency list from `pyproject.toml` (an editable install fails), set
  `FIRECRAWL_API_KEY` to anything, and `pytest etl/tests`.
- The checks are in `.github/workflows/ci.yml`: typecheck, lint, tests, the HTTP boundary guard,
  a replay of every migration on Postgres 16, and pytest.
- Which migrations are live is answered only by the live database. No file in this repository is
  a ledger of it.
- `development` is where work lands. `main` is what is live; it takes `development` by a merge
  commit, never a squash.

## Talking to the founder

The founder is not a programmer. Plain English, short, the answer first. Name a file or a command
only when they must click or type it. Say what an issue or pull request is about in a few words
the first time you mention its number.
