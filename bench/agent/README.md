# Agent token benchmark

What it costs an LLM agent to build the same service in slang + zokor,
Go + Fiber and TypeScript + NestJS: tokens in, tokens out, turns, and
whether the result works. The claim "slang is the cheapest language for an
agent to build with" needs this number, the way the HTTP claims needed
`bench/http`.

## Method

- **Five tasks**, each an HTTP contract a small backend team writes every
  week: `notes` (CRUD with validation), `auth` (login, bearer tokens,
  middleware, logout), `jobs` (a background worker with concurrency),
  `ratelimit` (per-client limiting with `Retry-After`), `upload` (multipart,
  size limits, safe file names). Specs are in `tasks/<task>/SPEC.md`, with
  the rules every task shares in `tasks/COMMON.md`.
- **Same spec for every stack.** Only the last paragraph changes: which
  language and framework to use (`stacks/*.md`).
- **Hidden, black-box acceptance.** The agent never sees
  `tasks/<task>/accept.py`. After it stops, the harness runs `sh start.sh`
  in its directory and tests the service over HTTP. A stack-specific test
  would measure the test, not the stack.
- **The tests are tested.** `run.py selftest` runs each acceptance test
  against a Python reference server (`reference/`), where it must pass, and
  against another task's, where it must fail. It also runs the whole
  harness once with a fake agent (`reference/fake_agent.py`) that copies a
  reference server in, so the runner is checked without spending tokens.
- **Several runs, medians.** An agent's cost varies run to run, so each
  task and stack runs `--runs` times (default 3), interleaved so drift in
  the agent's service over a session lands on every stack alike. Report the
  median with the raw runs, and treat a difference smaller than the spread
  as noise.
- **What is counted** comes from the agent's own report: input tokens
  (including cache reads and writes), output tokens, turns and cost.

## Running

**Run it in a disposable container or VM.** The default agent command lets
the agent run any command without asking, which an unattended build needs
and a machine with files you care about does not.

```sh
python3 bench/agent/run.py selftest              # the tests are sound
python3 bench/agent/run.py run --runs 3          # every task x stack
python3 bench/agent/run.py run --task notes --stack slang-zokor --runs 1
python3 bench/agent/run.py summary               # the latest results
```

The machine needs each stack's toolchain (`slangc` with zokor pinned or on
the path, Go, Node with the Nest CLI) and the agent CLI. `AGENT_CMD`
chooses the agent; it runs in the task's empty work directory, gets the
prompt on stdin, and must print its report as JSON on stdout. The default
is Claude Code:

```sh
AGENT_CMD='claude -p --output-format json --max-turns 80 --dangerously-skip-permissions'
```

Another agent needs a wrapper that prints `usage` (`input_tokens`,
`output_tokens`, and the cache fields if it has them), `num_turns` and
`total_cost_usd`.

Each run keeps everything under `results/<time>/<task>/<stack>/<run>/`:
the prompt, the agent's report and stderr, the work directory, the
server's log and the acceptance output. `results.jsonl` has one line per
run, and `summary` prints the table.

## Reading the result

A stack wins a task only on **passing** runs: a cheap run that fails is
not cheap. Compare medians of total tokens and turns per task, then look at
the failures: which requirement, and in the transcript, which compiler
error or missing API sent the agent round again. That second step is the
point; it is what tells slang where it still costs an agent tokens.

## Not measured yet

No run has been made: it needs a budget and a decision on which agent and
model to use. The first run should record the model version, the date, and
the slang, zokor, Go and Nest versions next to the table.
