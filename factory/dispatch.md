# Dispatch

How each factory agent is started. A small dispatcher session receives a message such as
`Dispatch: builder web` on a schedule, reads this file from `origin/development`, and starts one
fresh session for that role with the settings below. The dispatcher does no factory work itself.

Fresh sessions are started this way, rather than directly by the schedule, because a session
started by the dispatcher has the repository, the GitHub tools and the database connection, and a
session started directly by a schedule has none of them.

## Settings common to every role

- Repository: `https://github.com/arclayer-ltd/SourceBD`, revision `development`
- Environment: `env_01AzRaaKgDLzmF19UjiFTdov` (named "SourceBD")
- Tags: `sourcebd-factory` and `sourcebd-factory:<role>`
- Title: `SourceBD <Role>` followed by the date and hour
- Branch: `factory/<role>-<lane if any>-<yyyymmdd-hhmm>`, so every run has its own

## Roles

| Message | Model | Effort |
|---|---|---|
| `Dispatch: planner` | `claude-fable-5-2` | high |
| `Dispatch: builder web` | `claude-opus-5-5` | high |
| `Dispatch: builder data` | `claude-opus-5-5` | high |
| `Dispatch: builder database` | `claude-opus-5-5` | high |
| `Dispatch: builder ops` | `claude-opus-5-5` | high |
| `Dispatch: reviewer` | `claude-fable-5-2` | high |
| `Dispatch: releaser` | `claude-opus-5-5` | high |
| `Dispatch: critic` | `claude-fable-5-2` | high |
| `Dispatch: watch` | `claude-sonnet-5-5` | medium |
| `Dispatch: janitor` | `claude-sonnet-5-5` | medium |

## The message each new session is given

Replace `<role>` and `<Role>`, and for a builder add the lane sentence.

> You are the <Role> of the SourceBD factory. Nobody is watching this run and nobody will answer
> questions: decide and proceed.
>
> The repository is `arclayer-ltd/SourceBD`, checked out on `development`. Read `CLAUDE.md`, then
> `factory/README.md`, then your brief `factory/roles/<role>.md`, and do one run exactly as the
> brief describes. Use the GitHub tools for issues, pull requests and workflow runs; load them
> with ToolSearch if they are not listed. If you push, push only to the branch this session was
> started on.
>
> End with a few plain sentences: what you did, each issue and pull request you touched with a
> few words on what it is about, and anything that got in your way.

Lane sentence for a builder, placed after the first sentence: `Your lane is <lane>.`

## Before starting anything

If an open issue in the repository carries the label `stop`, start nothing and say so.

If a session for the same role (and lane) from an earlier dispatch is still running, start
nothing and say so. Two of the same role at once collide. A session that has waited more than an
hour for an approval is not running and never will be: archive it, then start the role as usual.

If there is plainly nothing for the role to do, start nothing and say so. This saves a whole run:

- Reviewer: no open pull request into `development`.
- Builder: no open issue labelled `ready` in its lane, and no open pull request carrying its lane
  label.
- Releaser: `development` has nothing `main` lacks, and no open issue is labelled `merged`.
