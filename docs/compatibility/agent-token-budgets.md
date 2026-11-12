# Agent token budgets

Veasel applies process-wide token admission ceilings before each native agent
provider call. The defaults are 262,144 tokens per child session and 1,048,576
tokens for the parent conversation and all descendants combined. Operators can
override them with:

| Variable | Default | Maximum |
|---|---:|---:|
| `VEASEL_AGENT_CHILD_TOKEN_BUDGET` | `262144` | `50000000` |
| `VEASEL_AGENT_PARENT_TOKEN_BUDGET` | `1048576` | `50000000` |

Values must be positive base-10 integers, and the child limit cannot exceed the
parent limit. Invalid policy prevents agent provider calls with a configuration
error. The limits are process policy; changing a provider or delegating a child
does not widen them.

Before dispatch, Veasel durably reserves a conservative bound based on the
serialized messages and tool schemas, a 4 KiB provider-protocol allowance, and
the configured output ceiling. It
uses a 4,096-token output ceiling when the selected profile omits one, and
allows for the bounded transient retry policy. Reservations are atomic across
concurrent child calls and are scoped to the root conversation. A child also
has its own cumulative ceiling. An oversized request or exhausted ceiling fails
before provider dispatch and reports an actionable error.

Only adapter-reported tokens are exposed as actual usage. A single successful
attempt with reported usage settles its reservation to the actual input plus
output count. Anthropic's separately reported cache read and cache creation
tokens are added because that adapter reports them disjointly; OpenAI and
Gemini cache reads are already included in input tokens and are not counted
twice. If usage is absent, a request is interrupted, or a transient
retry occurred, Veasel retains the conservative reservation because failed
attempts may have been billed. After restart, in-flight reservations become
uncertain and are not replayed. The conservative admission bound is not a token
usage estimate and is never displayed as actual usage.

Dollar cost is not hard-capped in this slice. Veasel exposes a child operation's
`reported_cost_usd` only when its provider adapter supplied that amount, with
`cost_reported: true`; otherwise the amount is omitted and `cost_reported` is
false. Embedded schedule prices are estimates and are not used as actual spend
or as a budget enforcement input. Providers without trustworthy pre-call price
bounds cannot receive an exact-spend guarantee.
