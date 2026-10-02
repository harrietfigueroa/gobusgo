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

The sections above are the generic engineering style guide. This section holds conventions specific to this repository and describes only what exists today.

## Purpose and source layout

Gobusgo is an Elixir application that reads Puget Sound transit data from the OneBusAway API. The application skeleton, runtime configuration validation, the OneBusAway agency requester, the generic writer and reader with their local file backends, the recorder that stores agency responses through the writer, the CloudEvents encoding, the generic publisher contract, the agency processor that publishes the records of one stored response, the reconciliation function that publishes "response stored" events again, the in-memory agency view, and a Phoenix HTTP server with a health endpoint and agency endpoints exist. The publisher's only backend delivers records inside the application, and the supervision tree in `lib/gobusgo/application.ex` holds the agency view and the HTTP endpoint, so nothing calls the recorder, the processor, or reconciliation on a schedule, and nothing reaches Kafka.

- `lib/gobusgo/application.ex` is the OTP application entry point. It validates the HTTP listener settings and starts the endpoint with them.
- `lib/gobusgo/config.ex` validates runtime settings as pure functions over the application environment.
- `lib/gobusgo_web/` holds the HTTP server: the Phoenix endpoint, the router, the controllers, the LiveView pages under `live/`, the layouts under `components/`, and the error bodies `GobusgoWeb.ErrorJSON` and `GobusgoWeb.ErrorHTML`.
- `assets/` holds the front end's JavaScript and CSS sources; `mix assets.build` writes the built files to `priv/static/assets/`, which git ignores.
- `lib/gobusgo/one_bus_away/` holds the OneBusAway integration: the HTTP client, the agency requester, the stored form of a raw agency response and its "response stored" event, the recorder, the agency processor with its records module, the agency view with its state module, and reconciliation with its time range module. Read `lib/gobusgo/one_bus_away/AGENTS.md` before changing it.
- `lib/gobusgo/request_id.ex` builds the UUID version 7 request identifiers.
- `lib/gobusgo/schema.ex` checks decoded data against a schema and returns the first mismatch as a value; `lib/gobusgo/assert.ex` raises on it.
- `lib/gobusgo/canonical_json.ex` encodes compact JSON with sorted keys, the encoding of every stored file and every published event.
- `lib/gobusgo/cloud_event.ex` encodes a CloudEvent 1.0 in structured mode and turns it into a publisher record.
- `lib/gobusgo/destination.ex` owns the logical destination and prefix rules that the writer and the reader share.
- `lib/gobusgo/writer.ex` is the backend-neutral write contract and entry point; `lib/gobusgo/writer/local_file.ex` is its local file backend.
- `lib/gobusgo/reader.ex` is the backend-neutral contract and entry point for reading content and discovering destinations; `lib/gobusgo/reader/local_file.ex` is its local file backend.
- `lib/gobusgo/local_file/` holds what the local file backends share.
- `lib/gobusgo/publisher.ex` is the backend-neutral contract and entry point for publishing records to topics; `lib/gobusgo/publisher/in_process.ex` is its in-process backend, which calls a subscriber per topic and stores nothing.
- `config/config.exs` selects the writer, reader, and publisher backends, gives the file backends one base directory, names the publisher's subscribers, and configures the HTTP endpoint. `config/runtime.exs` reads the environment variables.
- `test/` mirrors `lib/`.

## Toolchain and commands

Erlang and Elixir versions are pinned in `.tool-versions` and installed with mise (`mise install`). Run these before declaring work done:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

`mix.exs` also sets `warnings_as_errors` for compilation. The third-party dependencies are Req, Phoenix, Phoenix LiveView, Phoenix HTML, Bandit, and Plug, with esbuild and Tailwind to build assets and LazyHTML for LiveView tests; adding one needs the justification the style guide requires. Phoenix encodes JSON with Elixir's built-in `JSON` module.

When a change touches `assets/` or the classes in a template, also run `mix assets.build`; CI runs it as its own job. `mix assets.setup` installs the esbuild and Tailwind binaries at the versions `config/config.exs` pins. `mix format` formats HEEx templates through `Phoenix.LiveView.HTMLFormatter`.

## Issue branches

Before starting work on an issue, take its branch name from Linear: the "Copy git branch name" value, which `get_issue` returns as `gitBranchName`. Use it as the exact branch name, never one composed from the issue key and title. Create and check out that branch before making changes. When the value cannot be retrieved, ask the user to paste it.

## Naming across implementation levels

Each level names only what it contains or depends on.

- **Contract level** (behaviours, entry points, shared types, error reasons, and their docs): names domain concepts such as logical destination, content, and outcome. It names no storage technology (no file system, directory, path, bucket, object key, POSIX reason, or concrete backend module) and lists none of its implementations.
- **Implementation level** (a backend module and everything in its namespace): names its own technology and nothing of its siblings. A local-file backend speaks of directories, paths, and POSIX reasons; an S3 backend would speak of buckets, keys, and HTTP statuses. Translation from technology errors to contract outcomes happens here.
- **Composition level** (application configuration and wiring): the only place that selects and names a concrete backend.
- **Tests**: contract tests use a test double defined in the test; implementation tests name their backend.

The rule applies to every backend-neutral interface: the writer, the reader, the publisher, and later ones. Explanations of how a future backend would implement a contract live in Linear, not in the repository.

## Linear issue workflow

Update the Linear issue status as the work moves, without waiting to be asked:

1. Move the issue to In Progress when work starts, or when its work is committed locally and not yet pushed.
2. Make one commit per issue, with the issue key in the subject (for example `(GOB-12)`).
3. Move the issue to Done once its commit is pushed to `origin`, and after CI passes on that push once the CI workflow runs on GitHub.
4. Leave an issue in its current status and tell the user when its acceptance criteria are not fully met, such as a pending decision or a missing credential.

Pushing and other outward-facing actions still need the user's go-ahead.

## Deferred work

TODO items live in Linear. Record follow-up work as a comment on the relevant issue, or as a new issue when it stands alone. Code, comments, documentation, and commit messages carry no `TODO`, `FIXME`, or similar markers.

## HTTP server

Phoenix serves the HTTP API on Bandit; GOB-17 records the choice and its rationale. `mix phx.server` starts it on `GOBUSGO_HTTP_HOST` and `GOBUSGO_HTTP_PORT`, which default to `127.0.0.1` and `4000`.

- **Routes.** `GET /health` answers `{"status": "ok"}` and is not logged. API routes go under `/api`: `GET /api/agencies` and `GET /api/agencies/:id` serve the current fetch of the agency view.
- **Success bodies** hold `data` and `meta`. `meta` names the fetch the data comes from (`fetchedAt`, `requestId`), and a collection adds `count`. A route whose view has no current fetch answers `503` problem details with `Retry-After`, never an empty `200`.
- **Errors.** A JSON error response is an RFC 9457 problem details object, served as `application/problem+json`, with `type` (`about:blank`), `title`, and `status`. `detail` appears only for an error whose explanation the application writes itself, so the message of an unexpected error never reaches a client. Every error under `/api` is problem details: `GobusgoWeb.FallbackController` answers the requests no API route matches. Elsewhere, the error is an HTML page from `GobusgoWeb.ErrorHTML` for a request that accepts HTML first, and problem details otherwise.
- **Plugs that can raise go in a router pipeline, never in the endpoint.** The endpoint registers the callback that sets the problem media type, and only an error raised inside the router reaches the error renderer with that callback. `Plug.Static` is the one exception, because it has to run before the router.
- **Browser pages** are LiveViews routed through the `:browser` pipeline and rendered inside `GobusgoWeb.Layouts.root/1`. `GET /` is a placeholder page, and `GET /agencies` is a test page that lists the agencies of the agency view's current fetch and updates when the view switches. A page shows a value from outside the application as a link only when it is an `http` or `https` address. The LiveView socket is at `/live`, over WebSocket only.
- **Session.** The session is a signed cookie. `SECRET_KEY_BASE` supplies the secret: production refuses to start without it, and development and test generate a random one at startup when it is unset. The signing salts in the code are not secrets. Outside production the socket accepts any origin; a production deployment has to configure its public host name first.
- **Tests** send requests through the endpoint with `Phoenix.ConnTest` and mount pages with `Phoenix.LiveViewTest`; no socket is opened.

## Credentials and configuration

Local settings live in `.env`, which git ignores. `.env.example` lists the variable names (`ONEBUSAWAY_BASE_URL`, `ONEBUSAWAY_API_KEY`, `GOBUSGO_HTTP_HOST`, `GOBUSGO_HTTP_PORT`, `SECRET_KEY_BASE`); the OneBusAway ones carry placeholder values and the secret is left empty. Load them into the shell with:

```sh
set -a; source .env; set +a
```

Never commit secrets, and never put a key in code, tests, logs, documentation, or error output. `.env.example` carries placeholders and non-secret defaults, never a real credential. The OneBusAway key travels in a query string, so the integration's AGENTS.md rules on redacting it apply to every HTTP client.

## Integration reference

The OneBusAway API reference is https://developer.onebusaway.org/api/where/methods. Integration details, verified links, and open questions are in `lib/gobusgo/one_bus_away/AGENTS.md`.

## Data flow design

Implemented: output goes through the generic writer with a local file backend, and `Gobusgo.OneBusAway.AgencyRecorder.record/2` stores each successful agency response through it as one `{meta, body}` object. `Gobusgo.OneBusAway.AgencyBatch.process/2` reads the stored response at one destination through the generic reader and publishes it through the generic publisher: one record per agency, keyed `agency/<agency id>`, then one manifest record keyed `manifest`, all to the topic `oba.agencies-with-coverage.state`. `Gobusgo.OneBusAway.Reconciliation.republish/2` publishes a "response stored" event again for every stored response of a dataset fetched inside a time range. Every published record holds a CloudEvent 1.0 in structured mode. `Gobusgo.OneBusAway.AgencyView` holds the agencies of the latest complete fetch in memory: it holds a fetch's agency records until its manifest arrives, switches to the fetch in one step, announces the switch on the application's publish-subscribe server, and ignores a fetch older than the current one. The REST API and the agency test page read the view. The configured publisher backend is in-process and hands the state topic's records straight to the view, so a processed response reaches the REST API with no broker; it has no subscriber for "response stored" events. The view starts empty and holds nothing across a restart. An S3 mock is not part of the design.

Intended, with no process or service in the repository yet. The decisions are recorded in Linear; GOB-19 holds the trigger definition and names the issues that hold the rest.

- **Retrieval.** One scheduler process per source calls the recorder at that source's cadence; agency discovery runs once a minute. Every OneBusAway request passes through a request gate that holds the API key to one request per second.
- **Trigger.** After a raw response is stored, the recorder publishes a "response stored" event to Kafka, and a consumer calls `AgencyBatch.process/2` with the destination that event names.
- **Storage.** Raw responses are the only files. Kafka is the data store for processed data: the state topic the processor publishes to is compacted, and the manifest record completes the fetch.
- **Messages.** Every Kafka message is a CloudEvent 1.0 in structured mode, with its version in `type`. A dead-letter record keeps its key and value untouched and describes the failure in Kafka headers.
- **Failures.** A failed event is retried in place for about two seconds when the processor classes the failure as transient, then dead-lettered with the processor's error code, and the next event for the dataset brings readers up to date. Reconciliation runs on demand, never on a schedule.
- **Reads.** A subscriber per state topic feeds the in-application views from Kafka, from the beginning of the topic on every start, in place of the in-process publisher backend. LiveView pages read the views beside the REST API.
- **Libraries.** BroadwayKafka consumes and brod produces, as the backend of the publisher contract. Building them needs CMake and a C compiler.
- **Environments.** Local development uses a local Kafka. Production uses production services. Keep the two distinct: configuration selects the target, and local runs never touch production endpoints.

## Open decisions

- Which coding agents the team uses, and therefore whether `AGENTS.md` stays the only guidance file or gains agent-specific files.
- The production Kafka service on AWS, and how much of the event format carries over to it.
- The reverse-DNS prefix for the CloudEvents `type` attribute.
- Which aggregates the REST API serves, and therefore which datasets need a history topic.
- The OneBusAway rate limit; one request per second is an assumption.
- The writer's interface beyond the local file backend.
- Tombstone cleanup for agencies that no longer exist; their records stay in the state topic and no manifest names them.
- The public host name of a production deployment, which the LiveView socket's origin check needs.
- A valid OneBusAway API key and confirmation that `https://api.pugetsound.onebusaway.org` is the right server (see the integration's AGENTS.md).

Do not resolve an open decision in code without confirming it with the user, then update this list.
