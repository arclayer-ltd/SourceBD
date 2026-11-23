# The SourceBD factory

A small team of agents that finishes this platform through GitHub. Each agent is a fresh session
started on a schedule, given one role, and it reads nothing from a previous run except what is on
GitHub. That is deliberate: issues, pull requests and the code carry the state, so no agent
inherits another's habits.

## What it is building towards

`CLAUDE.md` states the one outcome. The factory reaches it in this order, and the planner keeps
the queue in this order:

1. **Safe.** No way in for someone who should not be in. No private detail where it should not be.
2. **True.** The data is current, the live database matches the code, and nothing on the site
   claims what the product does not do.
3. **The loop works.** A buyer's RFQ reaches a supplier and a reply comes back, end to end.
4. **Lean.** What nothing uses is deleted.
5. **Complete.** The remaining features, each one earning its place against the outcome.

## The board

Every piece of work is one GitHub issue. Labels say where it stands.

| Label | Meaning |
|---|---|
| `ready` | Specified well enough to build. Has a "done when" that can be checked. |
| `building` | An agent has claimed it. The claim is a comment naming the branch. |
| `merged` | Its pull request is in `development`. Not yet seen working live. |
| `needs-founder` | Waiting for a decision only the founder can make. Says what it recommends. |
| `blocked` | Cannot move, and the issue says on what. |
| `p0` `p1` `p2` | Order. `p0` is safety or truth and goes before everything. |
| `web` `data` `database` `ops` | The lane. One builder works one lane, so two never collide. |
| `bug` `feature` `cleanup` | What kind of work it is. |

An issue is closed only by the releaser, after the outcome is seen on the live site.

On pull requests: `reviewed` means the reviewer has read it and is satisfied.

## The roles

| Role | What it owns | Brief |
|---|---|---|
| Planner | The queue: what gets built, in what order, and that each issue can be checked | `roles/planner.md` |
| Builder | Turning one `ready` issue into one pull request | `roles/builder.md` |
| Reviewer | Whether a pull request is right. The only role that lets one merge | `roles/reviewer.md` |
| Releaser | Getting `development` live, applying database changes, proving it works, closing issues | `roles/releaser.md` |
| Watch | The live system: stale data, failed runs, errors, things that drifted | `roles/watch.md` |
| Janitor | Deleting what nothing uses | `roles/janitor.md` |

No role does another's job. A builder never merges its own work. A reviewer never fixes what it
reviews; it says what is wrong and the builder fixes it. The releaser never changes code.

## The flow

1. The planner writes or refines an issue until it has a "done when", and labels it `ready`.
2. A builder takes the highest `ready` issue in its lane, claims it, builds it on a branch with a
   test that fails without the change, and opens a pull request into `development`.
3. The reviewer reads the pull request against the issue and the lines in `CLAUDE.md`. It either
   says what is wrong, or labels it `reviewed` and turns on auto-merge. GitHub merges when every
   check is green.
4. The releaser takes `development` to `main`, applies any database change the release needs,
   watches the deploy, and checks each merged issue's "done when" on the live site. Seen working:
   the issue is closed. Not working: it goes back to `ready` with what was seen.
5. The watch and the janitor feed the queue with what they find; they do not jump it.

## The founder's part

The founder decides what the product is. An agent that needs such a decision opens or labels an
issue `needs-founder`, states the choice in plain English with a recommendation, and moves on to
other work. It does not wait idle and it does not guess on something that cannot be undone.

Everything else the agents do themselves.

## Stopping it

Open an issue with the label `stop`. Every agent looks for one before it does anything and exits
if it finds it. Closing the issue starts the factory again. The schedules themselves live in the
founder's Claude account under scheduled tasks and can be paused there.

## Changing the factory

These files are the factory's own design and are open to change like any other code: by an issue
and a reviewed pull request. If a role keeps producing poor work, the fix is usually to say less
in its brief, not more.
