# Engineering style guide

A generic engineering style guide for agents and engineers. Sections: General, TigerStyle, Comments, External APIs, Response style, Observability.

# General

## Principles

- **Architecture > code.** Code is cheap to write, expensive to maintain. Favor design conversations before implementation; favor simple code over clever code. Higher-level architecture, boundaries, and data lifecycle matter more than mechanical style.
- **Boundaries vs internals.** At boundaries where logical domains meet (module boundaries, IO surfaces, protocol interfaces, data lifecycle transitions), invest up-front — retrofits here are expensive and cascade into every caller. Reserve seams for known axes of evolution. *Inside* a task's scope, stay minimal; don't pre-build for imagined futures. The default-minimalism rules (don't add abstractions beyond what the task requires, don't design for hypothetical futures) apply to internals, not to boundary design.
- **Functional core, imperative shell.** Pure logic inside; side effects at the edges. If pure logic is tangled with IO, or IO is wrapped awkwardly around pure logic, flag it.
- **Composition over inheritance. Declarative over imperative** when both are equally clear. Deviate when there's a real reason.

## Testing

- **Test behavior, not implementation.** Assert on observable outputs and effects, not internal structure or private calls. A refactor that preserves behavior must not break tests.
- **One behavior per test.** Each case exercises a single logical unit of behavior; never bundle unrelated assertions into one case to save a test. A failing test's name should say what broke.
- **Table-driven when the shape fits.** Prefer one parameterized test over copy-pasted near-duplicate cases — most languages support this in some form.
- **Test-first: red → green → refactor.** Write the failing test, make it pass minimally, then clean up. If TDD doesn't fit the problem, don't force it — plan an alternative approach and present it to the user before proceeding.

## Communication

- **Terse is better than verbose.** One clear sentence beats one clear paragraph. End-of-turn summaries: one or two sentences max, or none.
- **Push back when you disagree** — silent agreement hides a disagreement the user needs to hear. If the user asks for something you think is wrong, say so and explain why; don't validate reflexively.
- **Trivial, easily-reversible choices** (variable names, minor idiomatic calls) can be decided silently and corrected if flagged. Default to asking only when the choice has real cost.
- **No time estimates.** "This will take X hours" is noise, not signal.
- **Announced checkpoints are blocking.** If you flag a decision for the user's review ("flag any you'd steer differently…"), end the turn and wait — announcing a decision point and acting in the same breath converts a review gate into a notification.
- **Never use `AskUserQuestion` to ask the user questions.** That tool is restrictive and doesn't support the user responding with questions of their own. Ask questions directly in chat, one question at a time, and include your recommendation and reasoning.
- **Multi-option choices:** present each option as a concrete path forward (not a restatement of the question), with your recommendation marked and reasoned. Open-ended questions that don't decompose into a small set of choices use the same "here's my recommendation, here's the reasoning, push back if wrong" shape.

## Uncertainty

- **Verify facts; escalate decisions.** A fact you don't know — how the code behaves, an API's contract, whether an approach actually works — is yours to resolve: read the source, check the docs, or run it. Don't guess at load-bearing facts, and don't ask the user what you could verify yourself.
- **Surface low confidence when being wrong is costly.** "I believe X but haven't verified" beats confident silence. Say what you checked and what you didn't.
- **Ask the user only for what's genuinely theirs to answer** — their intent, priorities, external constraints, or a decision with real cost (per the Communication rules). If you're blocked on a fact you can't resolve and can't ask, proceed on an explicitly stated assumption rather than stalling.

## Prose

- **Assert directly.** State the claim and its rationale. Scope is the prose written around the work: chat replies, PR and commit bodies, review comments, and docs — code comments are the Comments section's, and its positive-form rule governs there. Uncertainty is stated in the Uncertainty rules' vocabulary ("I believe X but haven't verified"), never as a softened predicate.
- **No understatement by negation.** `not uncommon` → `frequent`; `isn't wrong` → `correct`; `not a small change` → the line count. Litotes states a bound where the claim was wanted, and the reader is left to guess how far past the bound was meant. Syntactic test: a negated adjective or adverb where a positive one exists.
- **No `not just X, but Y`, and no `it's not that X — it's that Y`.** The frame spends a clause manufacturing a contrast and then asserts Y regardless. Write Y. Where X also holds, the two are a list: both X and Y.
- **Contrastive definition stays, and is required** where the negated half names the specific misreading a reader would otherwise default to — a wrong referent ("the unit is the operation, not the line", "comments are evidence, not authority") or a scope too narrow ("at every I/O surface, not just external APIs"). This is what separates an admitted trailing `, not Y` from the two rules above: the negation rules out one named reading rather than softening a claim or manufacturing a contrast. The test is whether deleting the negated half loses information; where it doesn't, delete it.
- **Markdown prose: one paragraph = one line.** No mid-sentence line breaks; viewers handle wrapping. Code blocks, tables, and frontmatter are exempt.

## Tooling

- **Prefer mainstream tools** — your language's standard formatter and linter — over hand-rolled scripts. Install the tool rather than reimplementing it.

## Git execution

- **Git commands run sequentially, never in parallel.** Never place more than one git command across the parallel tool calls of a single batch — concurrent git processes race on `.git/index.lock`.
- **`index.lock` failures: retry, don't investigate.** The lock is almost always transient and self-clears. Wait briefly and retry once; only if it persists, verify no git process is running, then remove the stale lock. Don't re-derive this diagnosis or treat it as repo corruption.

# TigerStyle

Adapted from TigerBeetle's [TIGER_STYLE](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) for application code. The design goals, in order: **safety, performance, developer experience**. Readability is table stakes, not the goal — the floor every change clears before those goals are weighed, never a cost to trade against them, and never license for a line that has to be decoded. Two framing rules survive from the source intact: simplicity is the hardest revision, not the first attempt — expect multiple passes to earn it; and zero technical debt — do it right the first time, because the second time may not transpire and a problem solved in design is many times cheaper than one solved in production.

## Control flow

- **Only simple, explicit control flow.** Use a minimum of excellent abstractions, and only where they make the best sense of the domain — every abstraction risks leaking.
- **Prefer iteration; recursion only with an explicitly asserted depth bound.** Every execution that should be bounded must be bounded.
- **Put a limit on everything.** Every loop, queue, cache, batch, accumulator, and retry has an explicit upper bound; every await on an external system has a timeout. A loop that must not terminate (an event loop) asserts that intent. Fail fast on violations.
- **Split compound conditions** into nested `if/else` trees, and consider whether each `if` needs a matching `else` — handle or assert the negative space.
- **State invariants positively** (`index < length`, with the `else` branch for the violation), never as negations.
- **70 lines per function, hard limit.** A function fits on a screen. When splitting, centralize control flow and state in the parent — push `if`s up, push `for`s down; helpers compute, parents decide and mutate; keep leaf functions pure.
- **Run at your own pace; never react directly to external events.** Queue work and drain it on your own terms — control flow stays yours, work per period stays bounded, and batching becomes possible.

## Assertions

- **Assertions detect programmer errors; boundary validation detects operating errors.** Operating errors (external data, expected) are validated at the boundary against a schema, with the failure returned as data and handled; programmer errors (internal invariants, unexpected) must crash — the only correct way to handle corrupt code. Assertions downgrade catastrophic correctness bugs into liveness bugs.
- **Assert via shared assert functions** that work identically in every runtime the code ships to, and that narrow static types downstream where the language supports it: a **condition assertion** for relational and nullability invariants — a plain truthy check, hot-path cheap, message carrying the operand values; and a **schema assertion** for structural invariants — a schema validation that throws an assertion error carrying the full mismatch as its cause. Never use an assert facility that logs instead of throwing.
- **Assert arguments, return values, pre/postconditions, and invariants** — at least two assertions per function on average; a function must not operate blindly on data it has not checked.
- **Pair assertions.** Enforce each property on at least two code paths: assert validity before writing, and again after reading back.
- **Assert the positive space and the negative space** — what you expect, and what you expect never to happen; bugs live where data crosses the boundary between them. Tests likewise must exercise invalid data, not only valid.
- **Split compound assertions** — two assert calls, not one conjunction, so a failure says precisely which half broke; a single-line `if a then assert b` asserts an implication.
- **Exhaustiveness is asserted twice.** Compile time: a `switch` (or match) whose default arm fails to compile when a case is missing, and compile-time checks of relationships between constants and types before the program runs. Runtime backstop: an `unreachable value` helper that throws in that same arm.
- **A blatantly-true assertion beats a comment** where an invariant is critical and surprising.
- **The helpers share one failure type.** Every assertion failure throws the same assertion error type, so a crash from any helper is recognizable as a programmer error.

## State and scope

- **Smallest possible scope, fewest variables in play.** Declare at the point of use, never before needed, and don't leave variables around after — place-of-check to place-of-use gaps breed bugs. This is a rule about lifetime, not about inlining: it never argues for fusing operations to avoid naming an intermediate.
- **No duplicated state, no aliases** — one owner per fact, so copies can't drift out of sync.
- **Every `await` is a suspension point**: shared state may have shifted by the time you resume. Keep invariant-critical sections synchronous, and re-check invariants after resuming rather than trusting pre-`await` assertions.
- **Simple signatures, low-dimensional returns.** Dimensionality at the call site is viral through the call chain: `void` beats `boolean`, `boolean` beats a value, a value beats `T or nothing`, and `T or nothing` beats throwing.
- **All errors are handled.** No unobserved async work, no empty `catch`, no swallowed failure — handle it or rethrow with context. Most catastrophic production failures trace to mishandled non-fatal errors (OSDI '14: 92%).
- **Know your numeric types.** Where the language's default number is a floating-point double, assert integer-ness where integers are meant, use an arbitrary-precision or 64-bit integer type where that range matters, and never rely on implicit coercion.

## Performance

- **Performance is a design-phase activity.** The 1000x wins happen before there is anything to profile — napkin-sketch the four resources (network, disk, memory, CPU) and their bandwidth and latency before building, and be roughly right.
- **Optimize the slowest resource first** — in application code usually the network and the database — after weighting by frequency of use.
- **Batch to amortize.** Per-item round trips are the N+1 shape of this mistake; give the CPU and the database large, predictable chunks of work.

## Naming

- **Get the nouns and verbs exactly right** — the perfect name shows you understand the domain. Prefer nouns over adjectives and participles: nouns compose (`config.pipelineMax`) and can be used in a doc or conversation without rephrasing.
- **No abbreviations**; acronym casing follows the repo's existing convention. Long-form flags (`--force`) in scripts — single letters are for interactive use.
- **US spellings everywhere** — identifiers, comments, documentation, log messages, and test names alike: `analyze`, `normalize`, `serialize`, `behavior`, `canceled`. A split spelling is the one-name-one-meaning rule broken at the character level, and it costs most in identifiers, where `normalise` and `normalize` are two distinct symbols that a search for either finds only half of. The single exception is text that must match something external verbatim — another system's field name, a quoted tool output, a cited title — where the foreign spelling is the fact being reproduced and changing it would make the line wrong.
- **Units and qualifiers go last, by descending significance**: `latencyMsMax`, so related names group and sort together (`latencyMsMin` lines up beside it).
- **Give related names the same length** where you can (`source`/`target`, not `src`/`dest`) so parallel code lines up and asymmetry is visible at a glance.
- **Name helpers after their caller** (`readSector` → `readSectorCallback`) to show the call history. Callbacks go last in parameter lists, mirroring when they run.
- **Options objects for mix-uppable arguments, and always at three or more parameters.** Two parameters of the same type must go through a named options object; three or more always do, whatever their types — the call site stays self-describing and argument order stops mattering, so a later reordering cannot silently compile. A nullable parameter is named so a bare `null` at the call site reads unambiguously. Singleton dependencies stay positional, most general first. Two exceptions. The first is the language's rather than a preference: where a type guard or assertion signature can only narrow a named parameter, the assert helpers above keep their positional shape — positional is the only expressible form. The second follows from the rationale: a function with no written call site — a callback a library calls itself, such as a comparator handed to `sort` by name or inline — keeps its positional shape, because nobody writes the argument list a transposition would corrupt. An exported function is never that callback: its callers are out of sight.
- **No magic numbers — constants are named.** Every literal carrying meaning becomes a named constant, its name bearing the units and qualifiers per the rules above (`latencyMsMax`, `pageSizeLimit`), so the rationale and every use site share one definition. Bare literals are for the self-evident only: `0`, `1`, an identity, a first index, and an HTTP status code, which the specification has already named — `FORBIDDEN = 403` supplies a synonym and a lookup where `403` was the name itself. The test is whether a reader could ask "why that number?" — if the answer lives in a comment, it belongs in a name instead.
- **One name, one meaning.** Don't overload a term with context-dependent meanings across code, docs, and conversation.
- **Important things first in the file**: entry points at the top; fields, then types, then methods; alphabetical when no order is more meaningful.

## Comment style

- **Always say why.** Comments explain rationale and show the workings; code alone documents what, never why. Tests open with a sentence on their goal and methodology.
- **Comments are prose**: full sentences, capitalized, punctuated. End-of-line comments may be phrases.

## Off-by-one

- **`index`, `count`, and `size` are conceptually distinct types.** index + 1 = count; count × unit = size — name variables so the casts between them are visible.
- **Show division intent**: an explicit floor, ceiling, or truncation whenever a division can be fractional, to show rounding was thought through.

## Dependencies and tooling

- **Every new dependency must be justified** against the standard library and the dependencies already in the repo — each one is supply-chain risk, safety and performance risk, and install time.
- **Pass options explicitly at call sites instead of relying on library defaults** — defaults change under you, and the call site should read complete.
- **Write scripts in the project's primary language**, not shell — type-safe, cross-platform, and one fewer dialect for the team.
- **Strictest settings, zero suppressions.** The compiler's and type checker's strictest settings stay fully on; no type-checker suppression, escape-hatch type, or lint-disable without a why-comment and no cleaner alternative. A disable names a rule the repository's own configuration carries and nothing else: a finding from a linter that repository does not run is left open rather than silenced, because the directive names a rule nobody there can look up — the repository's own linter reports the name as unresolved or the directive as unused, and the next agent to meet it explains it by inventing a theory.
- **The formatter owns layout.** TigerStyle's numeric formatting rules (indentation, line length, brace style) are not adopted — the repo's standard formatter and linter govern.

# Comments

The sections above decide what the code does; this one decides what may be written *about* it. Nothing above says a comment may not explain who calls this function, what the plan was, or what the code used to do. A comment stating a fact that some *other* file can falsify will never be corrected, because nothing brings that file's editor here — it rots by construction, and an agent then reads it as ground truth and builds on a fact that stopped being true three changes ago. `comment: only called from the ingest worker` is seven words and rots exactly as hard as a paragraph does. The governing axis is whether the code underneath a comment can prove it wrong.

- **Name, type, assertion, test — then comment.** Before writing a comment, try to spend its meaning on a mechanism that cannot go stale: a named constant (TigerStyle's no-magic-numbers rule), a named intermediate, a type that makes the illegal state unrepresentable, an assertion (TigerStyle's "a blatantly-true assertion beats a comment"), or a test case. A comment is the last rung because it is the only one nothing enforces — no compiler checks it, no test runs it, nothing fails when it goes false. Reach for it once the meaning genuinely cannot live in the four rungs above.
- **Every claim is falsifiable by the code it is attached to.** Ask what future edit makes this sentence false, and where that edit lives. If it lives in another file, the sentence is unmaintainable and does not go in — nothing will ever bring that editor to this comment. This is what rules out call sites, callers' motivations, "the only place that does X", and how a returned value is consumed downstream: each is a claim some other file owns and this one cannot keep true.
- **Present tense, positive form — what the code does and the case that motivates it.** Never the counterfactual ("without this lookahead, X would slip through") and never the history ("previously", "this used to", "instead of X we now"). A counterfactual's subject is a program that does not exist, so nothing on the page can check it, and to the next reader it is indistinguishable from a description of a past version — exactly the ambiguity an agent resolves in the wrong direction. This is TigerStyle's "state invariants positively, never as negations" applied to prose instead of conditions, and it is a syntactic test: an opening of "Without…", "Previously…", "This used to…", "Instead of…", or "We changed…" is the rewrite signal.
- **The admission list is closed.** A comment does one of these six jobs, and if none fits it is not written: (1) the non-obvious case the code handles, stated as the case; (2) why a line that looks wrong or redundant is correct — a defensive copy taken because the next call mutates in place; (3) an external constraint the code obeys that is not visible in it, such as an API quirk, a spec clause, or a protocol requirement, with a citation; (4) an invariant the reader must preserve that no assertion can express; (5) the why-comment the zero-suppressions rule mandates; (6) a test's goal-and-methodology sentence. Not on the list, therefore never written: what the code does, who calls it, where it is used, what it replaced, what was tried and abandoned, and what the plan or review said.
- **Doc comments state the contract, never the usage.** A doc comment on an exported symbol is the one place "what" is legitimate, because the caller cannot see the body: say what the caller must guarantee and what it gets back. It still names no callers. `doc: Every finding on a dashboard, in reading order.` is a contract; `doc: Used by the verifier CLI to build its summary.` is usage, and it is the precise shape that rots.
- **A module header may state the file's design posture** and the constraint that posture serves — that everything here is pure, which is what lets the rule set be replayed against a fixture; that kinds are inferred from values rather than from names. The falsifiable subject stays local (this file does no IO; nothing here reads a name), so the falsifiability rule is satisfied, and the consequence is motivation rather than a claim about another file's contents.
- **Write for the next editor of this function, not the reviewer of this change.** They have the code in front of them and no memory of why the change was made. This is the source of most of what the admission list excludes: an agent's default audience is whoever is about to approve its work, so it writes the justification it would give in review. Provenance already has owners — the commit, the PR description, the ADR, the plan document. A source file is the one place that cannot expire it.
- **Comments are evidence, not authority.** A comment asserting something you have not checked is a lead, not a fact — verify it at the source before relying on it, and most of all when it describes code elsewhere. Where it proves wrong or stale, fix or delete it in the same change — the passage this change actually trips, never a neighboring sweep.
- **"Always say why" is bounded by checkability.** The rationale a comment carries is what the code it sits on can confirm; a why that only some other file can confirm is not admissible, however true when written.
- **"Full sentences" sets register, not length.** The admission list decides whether a comment exists at all; full sentences is how the surviving ones are written.

# External APIs

- **External API calls follow the bounded-read contract.** Multi-item fetches carry an explicit bound or paginate, no single request asks for more than 100 items, and pagination is wrapped in a lazy async iterator (generator) over the provider's paging mechanism — preferring its cursor/page-token scheme where offered, falling back to page or offset parameters — so call sites consume every paginated source the same way.
- **Documented error codes never throw.** An error code the provider's API documentation describes is a known outcome, not an exception: accept it as legitimate and handle it appropriately, returning it to the caller as a value (a discriminated union) rather than throwing. Throwing is reserved for what the documentation does not account for: network faults, unrecognized statuses, malformed payloads.
- **Every external-API module carries an agents file.** The module integrating a provider ships an `AGENTS.md` describing the API: what it is and what the integration uses it for, the authoritative documentation sources (the same links the error-handling comments cite), auth and configuration expectations, and how the module should be used from the rest of the codebase. An agent landing in the integration reads the contract before the code — and the file is kept current as the integration changes.
- **Cite the documentation where known errors are handled.** The branch that handles a documented error code carries a comment linking the provider's API documentation for that code, where known — the reader verifies the contract the branch encodes against the source, not against model memory or folklore.
- **Doc citations are dated.** Every API-doc comment carries the date it was last verified (`comment: https://… — checked 2026-08-13`): a citation is a claim about when the contract was last true, not a permanent fact. When code near an aged citation is touched, re-fetch the doc, confirm the contract still holds (fix the code if it doesn't), and refresh the date.
- **HTTP APIs: accept documented statuses as data.** Configure the HTTP client to treat the documented status codes as successful responses, so it hands them back as data instead of throwing; the caller branches on `response.status` explicitly, and statuses outside the documented set remain exceptional.
- **Auth headers are stripped on cross-origin redirects.** When a request authenticates via a header (`Authorization`, `X-API-Key`, …), configure the client so that header is dropped when following a redirect to a different origin — the credential never travels to an origin the integration didn't name.
- **…and redacted from serialized errors.** The same secret-bearing keys are masked wherever the client serializes a request into an error — errors end up in logs, and this keeps the no-sensitive-data logging rule intact on that path.
- **Response type and encoding are always set on outbound requests.** The call site states the shape and encoding it expects back instead of leaning on client defaults — the pass-options-explicitly rule at the HTTP surface, and the known parse that the boundary schema assertion then validates against.
- **Inbound webhooks always verify the sender.** Every webhook endpoint authenticates the delivery by the provider's documented mechanism — signature verification over the raw body with the timestamp checked against replay, mutual TLS, or a shared secret — before the payload is parsed or acted on. Where the provider publishes source IP ranges, a strict IP allowlist is applied in addition, never instead. A delivery that fails verification is rejected, not processed leniently.
- **Retries are bounded, explicit, and transient-only.** Retry only failures the provider's contract marks transient — network faults, timeouts, 408/429/5xx as documented — never other 4xx client errors. The attempt count, per-attempt timeout, and total deadline are explicit at the call site: a retry loop is a loop, and TigerStyle's put-a-limit-on-everything rule bounds all three.
- **Back off exponentially, with jitter, honoring `Retry-After`.** Delay doubles from an explicit base to an explicit cap, with jitter so synchronized callers don't stampede the provider; a documented `Retry-After` header (429/503) overrides the computed delay. Sleep through a cancelable timer, so cancellation composes instead of leaking timers.
- **Retry only what is safe to repeat.** Idempotent requests retry freely; a non-idempotent request retries only through the provider's idempotency mechanism (idempotency keys, documented) — without one, the failure goes back to the caller as a known outcome rather than risking a duplicate side effect.

# Response style

This section is the checkable form of Communication's terse-over-verbose rule, Uncertainty's calibration vocabulary, and Prose's assert-directly rule: "be terse" and "assert directly" are true and not checkable against a transcript the way "no bullet fragments" or "no filler openers" is.

- **No filler openers or closers.** `Certainly!`, `Great question!`, `I hope this helps!` carry no information — cut them, state the answer, and stop. This is the terse-over-verbose rule applied to a response's edges, not just its middle. It doesn't reach the harness's own required one-sentence statement of intent before a tool call — that sentence states what's about to happen, which is information a filler opener isn't.
- **Verbosity matches complexity in both directions.** A yes/no question gets a sentence; a genuinely multi-part question gets structure. Don't pad a short answer to look thorough, and don't compress a complex one to look terse.
- **Prose over fragmented bullets for explanation and analysis.** Bullets are for things that are actually lists — steps, parallel options, enumerated findings. Reasoning, comparisons, and recommendations are paragraphs; a bulleted list of sentence fragments that don't share a parallel structure is prose that lost its connective tissue, not a clearer version of it.
- **Headings in your output use sentence case, not Title Case** — matching every current style guide surveyed (Google, Microsoft, GOV.UK) and giving the one AI-writing tell on this list that's purely mechanical to check: "Current Best-Practice Docs" becomes "Current best-practice docs."
- **Unearned validation is the same failure as silent agreement.** Communication already bans staying quiet when you disagree; it equally bans opening with praise ("Great idea!", "You're right to...") before establishing that the claim is true. OpenAI's public account of the April 2025 GPT-4o rollback is the concrete case: an approval-based reward signal measurably degraded the model's honesty, which is the failure mode this rule guards against here.
- **A word list is banned for being filler dressed as insight, not for being wrong:** `delve`, `boast(s)`, `bolster(ed)`, `crucial`, `meticulous`, `pivotal`, `showcase`, `tapestry`, `testament`, `underscore`, `vibrant`, `garner`, `foster/fostering`, `intricate`, `landscape` (as metaphor), `align with`, `valuable`, `enduring`, `interplay`, `enhance`. Each has a plainer word that says the specific thing; reach for that instead.
- **A second list is banned for the opposite failure, empty hedging:** `might`, `could`, `perhaps`, `somewhat`, `generally`, `in many cases` used to soften a sentence's core claim without adding information. Prose's assert-directly rule and Uncertainty's vocabulary already require hedging to be genuine; this is the concrete list of words that usually aren't.

Deliberately not adopted from the research behind this section: banning rule-of-three lists and heavy em-dash use, both flagged elsewhere as AI-writing tells. This guide uses both by design — its own design-goals ordering is a rule of three, and em-dashes carry most of its parenthetical structure — so the tell is reflexive, unvaried use, not the construct itself, and banning either here would contradict the voice this document already demonstrates.

# Observability

- **Observability is a first-class deliverable.** Every piece of work includes verification steps: how to observe the existing state before the change lands, and how to track the improvement after it ships — the logs, metrics, or queries named up front as part of the work, not reverse-engineered afterward.

## Logs

- **Log messages are stable, searchable templates.** Details go in structured properties, never interpolated into the message text — the message is the query key, the properties are the data.
- **An error is logged under `err`, as an object the call site writes out.** The caught value's home is `err` — never `error`, `stack`, `errorMessage`, nor the whole properties argument — and under `err` sits an object naming `message` and `stack`. Two failures are one failure at the index: a key other than `err` puts the value where the error serializer does not look, so the line arrives with no stack, and a value handed over whole leaves the serialized shape to whichever serializer is configured, so the fields differ between call sites and the query that finds one finds neither. `cause` is the known optional key, carrying the wrapped error where the error has one, and further keys are welcome; every one of them is named the same way, which is what rules out a spread. This is the pass-options-explicitly rule at the logging surface.

- **No sensitive data in logs.** Messages and properties carry no user-identifiable data (names, emails, account or household identifiers, tokens, financial details). Data flowing into a log call transitively counts — check what the logged object actually contains, not just the literal arguments.
- **Verbosity is a cost.** No per-iteration logs in loops, no duplicate logs on one failure path (log-or-rethrow, never log-and-rethrow), no large payload dumps. When in doubt, drop the level or drop the log.
- **Log at the decision point.** One log where the outcome is decided beats scattered logs along the path — the property bag carries what the path knew.
- **No logs inside pure functions.** A log call is a side effect — it disqualifies the function from the functional core and couples pure logic to a logger. Pure logic returns what happened (values, outcome unions); the imperative shell around it logs, at the decision point per the rule above. A pure function that seems to need a log usually needs a richer return value instead.

## Log levels

Severity names follow OpenTelemetry's `SeverityNumber` ranges — `trace`, `debug`, `info`, `warn`, `error`, `fatal` — because that vocabulary is what every log index, agent, and backend already shares. The spec's descriptions settle nothing at a call site, so the discriminators below are this guide's: attribute the names to OTel and the rules to this guide.

- **Two questions decide the level, and each is about a different subject.** Did the caller's operation complete? Did the process survive? Operation completion separates `warn` from `error`; process survival separates `error` from `fatal`. "Was the exception caught?" decides nothing at all — nearly every exception in a request-scoped service is caught and leaves the process healthy, so a caught exception is found at all three levels and catching tells you nothing about which one.
- **`error` — the operation did not complete.** A request, job, or task failed to do what it was asked, and the wider process is healthy. Whether a `catch` handled the exception is irrelevant to the level: the test is whether the caller got what it asked for, so a failure that is caught, logged, and returned as a `500` is `error`, and a failure that is caught and recovered from is not.
- **`warn` — the operation completed, degraded.** A fallback was taken, a retry eventually succeeded, a quota is near its limit, a deprecated path was used, a partial result was returned. The outcome was delivered, and something about the way it was delivered is worth a human's attention.
- **`info` — routine operational events.** Startup, shutdown, configuration load, a meaningful state transition, and one summary line per periodic task. The narrative of a process behaving correctly.
- **`debug` — diagnostics for someone actively investigating.** This is a claim about the runtime level, not about which code may exist: `debug` call sites ship to production and are switched off there by configuration. Deleting a `debug` call to keep production quiet is the wrong lever; the level configuration is the right one.
- **`fatal` — the process is going down.** A failed startup precondition, an uncaught exception, an unhandled rejection the process will not survive. Rare by construction — one or two sites per service, living in the handlers that own exit — and every `fatal` call in a service without such a handler is misplaced.
- **`fatal` only counts if it flushes.** Buffered loggers such as pino hold output in memory, so a `fatal` written on the way to `exit` is lost unless the exit path flushes synchronously. A `fatal` that never reaches the index is worse than no `fatal`, because the absence reads as a clean shutdown.
- **`trace` is not used; add a span instead.** Step-by-step execution, method entry and exit, and per-variable state are what a tracing span records, and a span carries the timing and causality that a sequence of log lines cannot reconstruct. Where a tracer is already installed, a `trace`-level log is a worse span. The name collision is its own reason for the ban: "a trace-level log" and "a trace" are unrelated things, and a reader cannot tell which one a sentence means.
- **A level nobody acts on is the wrong level.** The level is a claim about a reader, not only about an event: `error` says someone on-call can act now, `warn` says someone reviewing later should look, `info` says nobody acts. Ask who is paged and what they would do — if the honest answer is that nobody would do anything, the line belongs at `info`, at `debug`, or in a counter.
- **Expected and handled by design is never `warn`.** An outcome the code anticipates and absorbs is not an anomaly and no reviewer will act on it: a lookup that legitimately finds nothing, a provider that returns no data for an entity that has none, a record skipped because the skip is the rule. These want a counter and no log line, and reaching for `warn` to record that they happened is how a warn stream becomes unreadable. This is stricter than the level being merely available, and it binds the per-item case hardest — a skip inside a loop is a metric, never a line per item.
- **A level is a severity, not a category.** The single ordinal axis carries severity and nothing else. Which subsystem, which provider, whether the failure is retryable, and which tier the caller sits in are structured properties, per the Logs rules above. Encoding a category by promoting its severity is how `error` stops meaning anything.
- **Never move a level to quiet a signal.** Demoting `error` to `warn` because a dashboard is noisy hides the outcome instead of fixing it, and promoting `info` to `error` to get attention spends the one channel that is supposed to mean something. The level follows the two questions at the top of this section; noise is fixed by removing lines, batching them, or replacing them with a counter.


## Metrics

- **Prefer logs over metrics.** Where a metric must exist, emit a well-structured log and derive the metric from it via the observability backend's log-based metrics, instead of instrumenting a standalone metric.
- **Every custom-metric emission is paired with a log.** Wherever code emits a custom metric (new or touched), emit a well-structured log at the same site carrying the same signal — the metric's dimensions as structured properties. This keeps the migration path to log-based metrics open: the log must be sufficient to derive the metric, so the custom metric can later be dropped without losing the signal.


---

# Gobusgo project guidance

The sections above are the generic engineering style guide. This section holds the conventions of this repository, and the area files it maps hold the detail of each part of the code. Each describes only what exists today.

## Purpose

Gobusgo is an Elixir application that reads Puget Sound transit data from the OneBusAway API and shared bike and scooter data over GBFS. It stores each response, publishes the response's records to in-memory views, and serves them on a Phoenix site whose main page, `/vehicles`, is a map of the vehicles, route lines, and stops, with arrivals, favorites, service alerts, trip planning in the browser, and offline use.

## Area map

Read this file whole, then the area file of the code a change touches before changing that code. Each area file starts with what the area is and the files in it. A change to an area's behavior updates its area file in the same commit.

`node test/scripts/agents_md_check.mjs` fails when a repository path an `AGENTS.md` names in a code span is not tracked, when an `AGENTS.md` is missing from this map, and when the map names an area file that does not exist, with the file and line of each (GOB-349). Its rule for what a path is, and its exceptions with their reasons, are at the top of the check. CI runs it in its `agents-md` job.

- `lib/gobusgo/AGENTS.md`: the application core, the settings, cadences and schedulers, the demand registry, usage records, the storage contracts and retention, the publisher, the filter contract, the basemap extraction, the start-memory check, and the data flow every dataset follows. Read it before changing a module under `lib/gobusgo/` that no other area file covers, or the path from a fetch to a view.
- `lib/gobusgo/one_bus_away/AGENTS.md`: the OneBusAway integration, its requests, stored responses, processors, views, scheduled sources, rebuilds, and trip paths. Read it before changing anything under `lib/gobusgo/one_bus_away/`.
- `lib/gobusgo/gbfs/AGENTS.md`: the GBFS client, vehicle types, the shared vehicle source, and its files published to the browser.
- `lib/gobusgo/packed/AGENTS.md`: the packed container of published data files, its layout, kinds, storage, fixtures, and Mix task.
- `lib/gobusgo/places/AGENTS.md`: the places file, its selection and merge rules, its kind of the packed container, its publication and serving, and the Mix task that builds it.
- `lib/gobusgo/routing/AGENTS.md`: the routing snapshots and the browser's routing modules.
- `lib/gobusgo/addresses/AGENTS.md`: the county address points, their export, normalization, the address shard and index kinds of the packed container, the build, and the manifest.
- `lib/gobusgo/s3/AGENTS.md`: the S3 backends' requests, settings, and credentials.
- `lib/gobusgo/vendor_assets/AGENTS.md`: the vendored front-end assets and their sources.
- `lib/gobusgo_web/AGENTS.md`: the HTTP server, its routes, static files, error bodies, session, the browser pages' layout, the route and stop tile archive, and the pure modules that turn views into what a page shows.
- `lib/gobusgo_web/live/AGENTS.md`: the vehicle page, what it shows, its filter, panel sheet, tabs, map layers, and the events between the page and the browser.
- `assets/AGENTS.md`: the front end, the JavaScript modules and hooks, the stylesheet and themes, the build, the service worker, offline use, and the check each JavaScript file runs.

Outside the area files:

- `config/config.exs` selects the writer, reader, deleter, and publisher backends, names the in-process publisher's subscribers, schedules the sources and records usage everywhere except under test, and configures the endpoint; a production build also serves HTTP on start, reads the digested asset names, has the map skip MapLibre's style check, and logs from `info` upward. `config/runtime.exs` reads the environment variables and selects the S3 backends when `GOBUSGO_S3_BUCKET` names a bucket.
- `Dockerfile` and `.dockerignore` build the application's image, the one a developer runs locally and the one CI publishes: a release, run by a non-root user, with the base directory at `/data`. Its `GOBUSGO_REVISION` build argument, the full commit the image is built from, becomes the variable of the same name, which `Gobusgo.Config.revision/0` validates as 40 lowercase hexadecimal digits; a build without it names no commit (GOB-212). `mix.exs` defines the release.
- `experiments/routing/` is the routing engine experiment of GOB-232: correctness fixtures and the benchmark of the connection scan engine, which they import from `assets/js/`, with the decision for JavaScript over WebAssembly in its README. Nothing in the application, the image, or CI uses it.
- `test/` mirrors `lib/`; `test/support/` holds the synthetic fetches and memory readings of the vehicle page measurements and the headless Chrome they drive, and `test/scripts/` holds the node checks and the measurement that needs a browser.

## Toolchain and commands

Erlang and Elixir versions are pinned in `.tool-versions` and installed with mise (`mise install`). Run these before declaring work done:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

When a change touches `assets/css/app.css` or a route chip, also run the accessibility checks CI's `accessibility` job runs:

```sh
node test/scripts/css_accessibility_check.mjs
node test/scripts/route_chip_color_check.mjs
```

A change to a file under `assets/js/` runs that file's node check, or is checked in a browser, as `assets/AGENTS.md` ("Checks") lists; CI runs neither.

`mix test` also excludes the tests tagged `memory`, which print a measurement and assert little. `lib/gobusgo_web/live/AGENTS.md` ("Memory checks") holds the two commands that measure the vehicle page; run both before and after a change meant to move those numbers.

`mix.exs` also sets `warnings_as_errors` for compilation. The third-party dependencies are Req, Phoenix, Phoenix LiveView, Phoenix HTML, Bandit, and Plug, with esbuild and Tailwind to build assets, LazyHTML for LiveView tests, and Quokka to rewrite code during `mix format`; adding one needs the justification the style guide requires. Phoenix encodes JSON with Elixir's built-in `JSON` module.

CI's `accessibility` job checks the browser pages (GOB-296). `test/gobusgo_web/accessibility/rendered_pages_test.exs` renders `/`, `/agencies`, `/vehicles` without a basemap and with one, unfiltered, filtered, and under a refused filter, and the 404 and 500 error pages, checks each against the rules of `Gobusgo.Test.Accessibility` (a `lang`, one title, one `<main>`, one `<h1>`, every ARIA reference resolving, every control named, every `<dl>` holding only terms and definitions, every heading, paragraph, table, and control in a landmark), and writes each to `tools/lint/rendered/`; `node test/scripts/write_offline_screen.mjs` writes the offline screen beside them.

html-eslint then lints those files: `tools/lint/` holds ESLint and `@html-eslint/eslint-plugin` at exact versions with a committed lock file, a development tool that no build, bundle, or image reads, and its configuration takes html-eslint's recommended rules with its accessibility rules turned on, the layout rules off for generated output, and three rules narrowed by a named exemption. `npm run --prefix tools/lint check` lints documents written out by hand to check that each rule still reports its failure.

`node test/scripts/a11y_source_check.mjs` scans `assets/js/` for a positive `tabindex`, an `aria-haspopup` with no popup of that role, and a click handler on a tag no keyboard reaches. The job also runs the two checks above (GOB-298).

A rule a page still breaks is listed with the issue that fixes it, in the test's `@known_failures`, the configuration's `KNOWN_FAILURES`, or the scan's `KNOWN_FAILURES`; the test and the scan fail when a listed failure is gone, so the fix removes the entry. What the browser builds after it connects is checked in a browser, with axe-core and the accessibility tree. Locally:

```sh
npm ci --prefix tools/lint
npm run --prefix tools/lint check
mix test test/gobusgo_web/accessibility
node test/scripts/write_offline_screen.mjs
npm run --prefix tools/lint lint
node test/scripts/a11y_source_check.mjs
```

When a change touches `assets/` or the classes in a template, also run `mix assets.build`; CI runs it as its own job. `assets/AGENTS.md` ("Build") holds `mix assets.setup`, the vendored packages' rules, and the build's steps. `mix format` formats HEEx templates through `Phoenix.LiveView.HTMLFormatter`.

`mise.toml` pins the `pmtiles` command, which only `mix gobusgo.basemap.extract` runs; compiling, testing, CI, and the image do not need it. The README's "Basemap archives" section holds the extraction process and the measured archive sizes.

tippecanoe builds the route and stop tile archive: the image installs the version its Debian release ships, 2.53.0, pinned in the `Dockerfile`, and a local run takes the one on the path, such as Homebrew's (`brew install tippecanoe`), since no mise backend publishes it. Without it a build logs its failure and the application runs on. The tests run a stand-in, so compiling, testing, and CI do not need it.

`mix format` also rewrites Elixir code through the Quokka plugin, with every rewrite category `.formatter.exs` lists, so run `mix format` and read its diff before the three commands above. Quokka is an autofixer for style: the engineering style guide stays a review criterion, and a rewrite that conflicts with it is corrected by hand in a form Quokka leaves alone.

- **`.credo.exs` configures Quokka only.** Credo arrives as Quokka's dependency and is not run as a linter. The one setting keeps a module's directives and attributes in the order they are written, because a module here declares the attributes its `@moduledoc` interpolates above that `@moduledoc`.
- **An explicit `nil` fallback is a `case`.** Quokka removes `else: nil` from an `if` and inverts an `if` whose `do` is `nil`, so a branch that has to name its `nil` outcome is written as a `case` clause.
- **A comment in `config/*.exs` can move.** Quokka sorts `config` stanzas and does not always carry a stanza's comment with it; check that each comment still sits on its stanza.

When a change touches `Dockerfile`, `.dockerignore`, `mix.exs`, or `config/`, also run `docker build --tag gobusgo:local .`; CI runs it as its own job. The image's Elixir, Erlang, and Debian versions are build arguments in the `Dockerfile` and change together with `.tool-versions`. A file the release needs from outside `lib/`, `assets/`, and `config/` has to be admitted in `.dockerignore` and copied in the `Dockerfile`.

## CI and release

CI's `image` job builds the image for `linux/arm64` on every pull request with its commit, starts it, checks that `/health` names that commit, and publishes nothing.

Its `start-memory` job builds the image the same way and runs `mix gobusgo.start_memory` on it against the fixture of the run's UTC date, so a change that grows a start's memory past the threshold fails its pull request; run the check locally after `docker build --tag gobusgo:local .` when a change touches what a start reads, builds, or holds. `lib/gobusgo/AGENTS.md` ("Start-memory check") holds the threshold and the fixture.

On a push to `main`, once every other job passes, the `publish` job builds the image again and pushes it to GitHub Container Registry as `ghcr.io/harrietfigueroa/gobusgo:<full commit SHA>`, signed in with the workflow's own token. A tag never moves: the job leaves a tag that is already published, and no `latest` exists. The job keeps the 10 newest images of the package and deletes the rest.

A run on `main` that has started is never canceled by a later one. A run that waits for it is: the workflow's concurrency group holds one waiting run, and a newer one replaces it, so of the commits merged while a run is in progress only the newest gets an image.

After `publish`, the `release` job asks the infrastructure repository for a production release of the commit: it sends a `workflow_dispatch` for `application-release.yml` in `harrietfigueroa/gobusgo-infra` with the commit's full SHA, and ends. It does not wait for the release, so a release that fails shows in that repository's runs and nowhere on the commit here.

The `release` job runs only while the repository variable `PRODUCTION_DEPLOY_ENABLED` is `true` and is skipped otherwise, and it asks for nothing when its commit is no longer the head of `main`, which is the case of a run that is started again after a later merge. It signs in with the repository secret `PRODUCTION_RELEASE_TOKEN`, a fine-grained personal access token limited to the infrastructure repository with the Actions permission at write, which no other job reads. That permission covers every workflow of that repository, the production Terraform one included (accepted in GOB-213).

- **A commit on `main` is a production release** while `PRODUCTION_DEPLOY_ENABLED` is `true`. An agent never merges a pull request into `main` and never pushes to `main`, with or without a go-ahead to push: the user's merge is the release's go-ahead.
- **The pause is the variable.** With `PRODUCTION_DEPLOY_ENABLED` at any value but `true`, a merge publishes its image and releases nothing. The user sets it; an agent does not. Production is moved to a chosen commit by hand with the infrastructure repository's `application-deploy.yml`, and the pause keeps it there through later merges.
- **Infrastructure first.** A change here that needs something of the infrastructure repository, such as a parameter, a permission, or a bucket, is merged only after that repository's change is merged and applied, and that change is harmless to the image that is running. A change that cannot be made that way is merged with the pause on and released by hand.
- **This repository holds no infrastructure work.** No workflow or file here names an AWS account, role, region, or registry, and no AWS credential is added to the repository. The `release` job names the infrastructure repository and one workflow file of it, and whatever else moves a published image further belongs to the infrastructure repository.

## Issue branches

Before starting work on an issue, take its branch name from Linear: the "Copy git branch name" value, which `get_issue` returns as `gitBranchName`. Use it as the exact branch name, never one composed from the issue key and title. Create and check out that branch before making changes. When the value cannot be retrieved, ask the user to paste it.

## Naming across implementation levels

Each level names only what it contains or depends on.

- **Contract level** (behaviours, entry points, shared types, error reasons, and their docs): names domain concepts such as logical destination, content, and outcome. It names no storage technology (no file system, directory, path, bucket, object key, POSIX reason, or concrete backend module) and lists none of its implementations.
- **Implementation level** (a backend module and everything in its namespace): names its own technology and nothing of its siblings. A local-file backend speaks of directories, paths, and POSIX reasons; an S3 backend would speak of buckets, keys, and HTTP statuses. Translation from technology errors to contract outcomes happens here.
- **Composition level** (application configuration and wiring): the only place that selects and names a concrete backend.
- **Tests**: contract tests use a test double defined in the test; implementation tests name their backend.

The rule applies to every backend-neutral interface: the writer, the reader, the deleter, the publisher, and later ones. Explanations of how a future backend would implement a contract live in Linear, not in the repository.

## Linear issue workflow

Update the Linear issue status as the work moves, without waiting to be asked:

1. Move the issue to In Progress when work starts, or when its work is committed locally and not yet pushed.
2. Make one commit per issue, with the issue key in the subject (for example `(GOB-12)`).
3. Move the issue to Done once its commit is pushed to `origin`, and after CI passes on that push once the CI workflow runs on GitHub.
4. Leave an issue in its current status and tell the user when its acceptance criteria are not fully met, such as a pending decision or a missing credential.

Pushing and other outward-facing actions still need the user's go-ahead.

## Deferred work

TODO items live in Linear. Record follow-up work as a comment on the relevant issue, or as a new issue when it stands alone. Code, comments, documentation, and commit messages carry no `TODO`, `FIXME`, or similar markers.

## Credentials and configuration

Local settings live in `.env`, which git ignores. `.env.example` lists the variable names (`ONEBUSAWAY_BASE_URL`, `ONEBUSAWAY_API_KEY`, `GOBUSGO_HTTP_HOST`, `GOBUSGO_HTTP_PORT`, `GOBUSGO_DATA_DIR`, `SECRET_KEY_BASE`, `GOBUSGO_PUBLIC_HOST`, `GOBUSGO_S3_BUCKET`, `GOBUSGO_S3_REGION`, `GOBUSGO_S3_PREFIX`, `GOBUSGO_S3_ENDPOINT`, `GOBUSGO_REVISION`, `GOBUSGO_DONATION_URL`, and the five vehicle motion variables, each left empty for its default); the OneBusAway ones carry placeholder values, and the secret, the public host, and the donation address are left empty. Load them into the shell with:

```sh
set -a; source .env; set +a
```

`mix phx.server` starts the HTTP server on `GOBUSGO_HTTP_HOST` and `GOBUSGO_HTTP_PORT`, which default to `127.0.0.1` and `4000`.

Never commit secrets, and never put a key in code, tests, logs, documentation, a `Dockerfile`, or error output. A container receives its credentials as environment variables at run time. `.env.example` carries placeholders and non-secret defaults, never a real credential. The OneBusAway key travels in a query string, so the rules of `lib/gobusgo/one_bus_away/AGENTS.md` on redacting it apply to every HTTP client.

## Integration reference

The OneBusAway API reference is <https://developer.onebusaway.org/api/where/methods>. Integration details, verified links, and open questions are in `lib/gobusgo/one_bus_away/AGENTS.md`.

## Open decisions

- Whether distinct or returning visitors are counted, which needs an identifier that a usage record leaves out (GOB-191).
- Which coding agents the team uses, and therefore whether `AGENTS.md` stays the only guidance file or gains agent-specific files.
- The reverse-DNS prefix for the CloudEvents `type` attribute.
- Which aggregates the REST API serves, and therefore which datasets need a history topic.
- The OneBusAway rate limit; five requests per second is an assumption, and the live server has answered 429 at about three.
- With a bucket configured the hourly cleanup is not scheduled: the bucket's lifecycle rules, declared in the infrastructure repository, hold the retention of what is in S3, with the days of `Gobusgo.RetentionPolicy` (decided in GOB-203). The two are kept the same by hand; whether one should be derived from the other is open.
- The time the S3 requests add to a vehicle cycle, which is not measured in production (GOB-203).
- Removal from the views of what is no longer fetched: an agency that no longer exists keeps its last fetch until a restart, and so do the vehicles of an agency that is no longer fetched, the routes of such an agency, and the path of a route its agency no longer lists.
- The route path of a route the paths view holds and no agency lists any more is never fetched again and never removed. Its stops record stays as well, so the stop view keeps the stops only that route lists.
- How an instance that serves pages tells the instance that runs ingestion what is in demand, the open stops and the vehicle viewers, once ingestion runs on one instance only (GOB-154); the demand registry is per node.
- The arrival source's pace, one request every five seconds, set low until the rate limit is known.
- The places file and its manifest under `places/` (GOB-366) are built by hand and deleted by nothing: `Gobusgo.RetentionPolicy` has no rule for them and the bucket has no lifecycle rule, so an old file stays until it is removed by hand. CloudFront has no behavior for `/places/*` yet, so production serves no places file until the infrastructure repository adds one.
- The bucket's lifecycle rules, in the infrastructure repository, have no rule for `raw/gbfs/free-bike-status/` or `shared-vehicles/` yet; until one is added, the ten-minute deletion of `Gobusgo.Gbfs.VehicleStatusRetention` alone removes the shared vehicle files and their published files from S3 (GOB-256, GOB-258). CloudFront has no behavior for `/shared-vehicles/*` yet, so production pages draw no shared vehicle until the infrastructure repository adds one (GOB-258).
- Whether the stops no route serves are ingested, through `stop-ids-for-agency` and `stop` (GOB-69, GOB-70); most are entrances of Sound Transit stations.
- Whether the service alerts come from the agencies' own GTFS-realtime alert feeds, which hold an agency's whole set, where OneBusAway's responses hold those of the running trips and the open stops (deferred in GOB-225).
- Whether OneBusAway means an empty `activeWindows` and a window with no end as GTFS-realtime does, active until withdrawn, as the application reads them; and how a page shows an alert that names an agency and no route, which it now leaves out.
- The vehicle cadence while a vehicle page is connected, ten seconds for every agency until GOB-91 decides (moved from five in GOB-183, to fit the measured cycle), and the five-minute grace period before an absent vehicle's tombstone, which is not measured against the live feed. The 60 seconds with no page connected and the 60-second hold are set by GOB-175 and are not measured either.
- Which further vehicle fields are published: the route's color, type, and address, the line a route follows, the closest stop, occupancy, journey phase, and service-alert identifiers are left out. Trip progress is published as each marker's last report, trip, and service date (decided in GOB-238).

Do not resolve an open decision in code without confirming it with the user, then update this list.
