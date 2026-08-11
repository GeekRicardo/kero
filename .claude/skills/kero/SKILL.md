---
name: kero
description: Drive Kero's terminal panes from inside a Kero terminal — create and close panes, send input and control keys, read output incrementally or by line number, wait for silence or a pattern instead of sleeping, and run one command for its own exit code. Use when work needs a real terminal that outlives the turn — an interactive program, a long build, an ssh session, a REPL, a full-screen TUI — or when another Kero pane has to be inspected or driven. Triggers on "kero +term", "kero +pane", "kero +agent", "another pane", "keep it running", "check on that build", "interactive", "TUI", "ssh into".
---

# Kero terminals

Kero panes are real terminals the user is looking at. Everything below drives
the same panes the user can type into, so treat them as shared: they can watch,
take over, rename, or close anything you start.

Requires `KERO_AUTOMATION=1`. If it is missing, this command is not running
inside a Kero terminal and none of it will work — say so rather than guessing.

Every command is scoped to the invoking terminal's project. Panes in other
projects and windows are not reachable, by design.

## When to use this instead of a plain shell call

Use a Kero terminal when the process is **interactive** (needs a TTY, prompts,
draws a full-screen UI), **long-lived** (a build, a server, a `tail`), or must
**survive between turns**. For a quick one-shot command with no state, the
ordinary shell tool is still the right thing.

## Commands

```
kero +term list                          # every terminal in this project
kero +term new [--alias A] [--cwd D] [--split right|down|left|up]
kero +term close TARGET [--tab]
kero +term rename TARGET --alias A
kero +term send TARGET 'text' [--key ctrl-c] [--no-enter]
kero +term read TARGET [--cursor NAME] [--max-lines N]
kero +term history TARGET [--lines N | --start N --end M]
kero +term wait TARGET [--idle MS] [--match REGEX] [--exit] [--timeout MS]
kero +term exec TARGET 'command' [--background] [--timeout MS]
kero +term result TARGET [--timeout MS] [--abandon] [--interrupt]
kero +term keys                          # every key name --key accepts
```

`TARGET` is an alias, a full pane or terminal id, or an id prefix of at least
four characters. Omit it to mean the terminal you are running in. An ambiguous
prefix is refused, never guessed. Give new terminals an alias — it is what makes
the pane legible to the user and to your next command.

Output is JSON. `--plain` prints just the text, sends notes to stderr, and makes
`exec` exit with the command's own status.

Do not run work in your own pane: while `kero` is running, that shell is busy,
and `exec` will refuse it. Create a pane first.

## Reading output

**`history` is the one to reach for when you want to look at what happened.**
With no arguments it returns the **last 100 lines**, so it is always safe to
call, even on a terminal that printed 50,000.

```sh
kero +term history build                    # last 100 lines
kero +term history build --lines 400        # more when the tail is not enough
kero +term history build --start 200 --end 260   # an exact window
```

Line numbers are absolute and stable for the life of the terminal, so
`--start`/`--end` are safe to compute once and reuse.

**`read` is for following along.** It returns only what arrived since your last
read for that cursor and advances it, so polling never repeats output. It caps
at **500 lines**; beyond that you get the newest ones plus `omitted_lines`, and
the skipped range is still reachable through `history`. Use a stable
`--cursor` name per watcher.

Kero records what the terminal *rendered*, not the raw byte stream. Two
consequences worth knowing: colors and escape sequences are already resolved
away, and output that floods faster than Kero samples is reported as `gaps`
rather than silently stitched together. When you see `gaps`, read by line
number instead of trusting the join.

## Wait, do not sleep

Guessing a delay after sending input is the main source of flaky terminal work:
too short reads half a screen, too long makes everything crawl.

```sh
kero +term send build 'make -j4'
kero +term wait build --idle 800 --timeout 300000
# → {"reason":"idle"|"match"|"exit"|"timeout", ...}
```

- `--idle MS` (default 500) resolves once output stops — "it finished printing".
- `--match REGEX` resolves the moment the pattern appears. Use it for a known
  marker. Passing `--match` turns the idle rule off unless you also pass
  `--idle`.
- `--exit` resolves when the terminal's process ends.
- `--cursor NAME` also returns and consumes the new output, so one call replaces
  send + sleep + read.

It always returns a `reason`. A timeout is an outcome, not an error — the
terminal keeps running.

## Exit codes

`exec` runs one command in the terminal's live shell and reports **that
command's** output and exit code:

```sh
kero +term exec build 'npm test'
# → {"status":"completed","exit_code":1,"output":"…"}
```

It never blocks indefinitely. If you already know the command is long-running,
say so and get a handle immediately:

```sh
kero +term exec build 'npm run dev' --background
# → {"status":"running","backgrounded_because":"requested"}
```

And when you did not know, two budgets protect you: printing nothing at all for
10s backgrounds it straight away (there is nothing to hand you anyway), and
still printing keeps it in the foreground until 60s. Backgrounded means
`status: running` and the command is still going — the exit code is not lost:

```sh
kero +term result build --timeout 120000     # → completed, or running again
kero +term history build                     # watch progress in between
```

**To stop a command, interrupt it:**

```sh
kero +term result build --interrupt          # → status: abandoned
```

That sends Ctrl-C, waits for the shell to finish redrawing its prompt, and
releases the terminal. The wait matters: sending the next command too early gets
its first character swallowed mid-redraw.

An interrupted command can never print the marker `exec` waits for, so its exit
code is gone for good — which is why interrupting and abandoning are the same
operation. If a command was interrupted by hand, `--abandon` releases it, and
`exec --replace` does so implicitly. Without that, the terminal stays occupied
by a command that will never report.

`exec` instruments the shell's command line, so it needs a shell at a prompt. It
will not work inside `vim`, a pager, or a full-screen agent — use `send` and
`wait` there.

## Control keys

`send` types raw input. Text implies Return; `--no-enter` suppresses it. Keys
are sent literally:

```sh
kero +term send repl '2 + 2'                 # types it and presses Return
kero +term send build --key ctrl-c           # interrupt
kero +term send picker --key down --key down --key enter
```

Names: `enter tab esc space backspace delete up down left right home end pageup
pagedown f1…f12 ctrl-a…ctrl-z`. Run `kero +term keys` for the full list.

## Recipes

**Start a long job and come back to it**

```sh
kero +term new --alias build --cwd "$PWD"
kero +term exec build 'npm run build' --background
# … other work …
kero +term result build --timeout 5000       # done yet?
kero +term history build --lines 200
```

**Run something and get its output and status**

```sh
kero +term new --alias work --cwd "$PWD"
kero +term exec work 'npm test 2>&1 | tail -40' --plain
```

**Interactive program / ssh**

```sh
kero +term new --alias remote
kero +term send remote 'ssh user@host'
kero +term wait remote --match '\$ $' --timeout 30000
kero +term send remote 'uname -a'
kero +term wait remote --idle 500 --cursor agent
```

## Naming the tab you are in

```sh
kero +tab rename 'refactor auth'     # renames the caller's tab
kero +tab rename --clear             # back to the automatic title
```

This only ever renames the tab the command runs in. Use it when a long task
would otherwise leave the user staring at a strip of identically named tabs.

## Rules

- **Never type secrets.** Passwords, tokens, passphrases, private keys: stop and
  ask the user to type them directly into the Kero pane, which writes to the
  same terminal. Do not put them in `send`, in a command line, or in an
  environment variable — they would land in the transcript, in the shell's
  history, and in your own context.
- **Never answer a permission, credential, trust, or destructive-action prompt
  on the user's behalf.** Report the blocker instead.
- **Send a newline.** `send --no-enter` types characters and waits; without it
  the text is submitted.
- **Wait, do not sleep.** Reading immediately after sending gets a half-drawn
  screen.
- **Close what you open**, and only what you open. The user shares these panes;
  do not close, rename, or rearrange panes you did not create.
- **Keep new panes unfocused** unless the user asked to watch. `--focus` is
  opt-in for that reason.
- **Exited is not gone.** A finished terminal still answers `history`.
- Full-screen programs (`top`, `vim`) produce output that reads poorly as text.
  Prefer a non-interactive equivalent (`ps`, `sed`) when you only need the data.

## Coordinating agents

`kero +agent` is a separate, narrower surface for starting and prompting
recognized coding agents in Kero panes, with lifecycle state Kero observes
rather than asks the model to report. Run `kero +agent --help` and
`kero +agent explain` for its contract. Use `+term` for terminals and `+agent`
for agents; do not drive an agent's TUI with raw `send` unless the user asked
for exactly that.
