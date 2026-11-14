# Client requirements

What a client has to do to use a conflux mesh, and what it gets back. The
architecture behind this is in [design.md](design.md).

A plain OpenAI-compatible client works with no changes ([below](#a-client-that-does-none-of-this)).
A client that follows the recommendations here gets more of the mesh's
throughput, and results it can attribute exactly.

> **Status: implemented in Phase 1, for one Mac.** `conflux serve` and the
> app serve everything below except streaming. Header names may still change
> before the first release.

## The API

The gateway serves a subset of the OpenAI API on loopback, at
`http://127.0.0.1:8090/v1` by default:

| Endpoint | Purpose |
|---|---|
| `GET /health` | Whether the gateway is up. 200 even when no host is available. With the token, also the mesh's and each host's throughput, failures and idle time, and each host's `hardware`: `chip`, `performance_cores`, `efficiency_cores`, `gpu_cores`, `memory_bytes` and `model_identifier`, whichever it reported ([design.md](design.md#monitoring)). Nothing that identifies a device |
| `GET /v1/models` | Every model currently served in the mesh, plus aliases |
| `POST /v1/chat/completions` | One request, including image input |

Requests and responses follow the OpenAI schema, including `response_format`
for structured output ([Ask for a schema](#ask-for-a-schema)) and image parts
as `data:` URLs.

**Streaming (`"stream": true`) isn't supported yet**, and is refused with
`400` and code `stream_unsupported`. Throughput workloads don't need it, and
retrying or moving a request to another host only works cleanly while
nothing has been sent back yet.

## Requirements

### Send a token

```
Authorization: Bearer <token>
```

The gateway issues tokens: `conflux token` prints the current one, and
`conflux token --rotate` replaces it. It's kept in a file only the user can
read. Tokenless loopback access is an opt-in setting (`--no-token`, or
"Require the token" off in the app), so clients that can't send a token yet
still work. Clients should support a token from the start.

### Own your work

conflux doesn't keep a durable queue. The client keeps track of what still needs
doing, what's done, and what to retry. A request may fail, and in rare cases it
may run twice. The client records a result once, keyed by its own request ID.

### Record which model answered, per response

Read `model` and `system_fingerprint` from **every response**. Don't use a value
remembered from `/v1/models`, whose first entries are aliases, not models. A
mesh serves several models at once, and with an alias or preference list,
consecutive requests can be answered by different models.

A refusal names its model too. When a model refuses a request, the `400`
carries `model` and `system_fingerprint` beside `error`, naming the model that
refused. If several refused it in turn, that's the last of them. Errors from
the gateway itself, such as `429` and `503`, name no model, because none ran.

| Field | Contents |
|---|---|
| `model` | The artifact that ran, for example a model name with its quantization |
| `system_fingerprint` | Runtime, runtime version and artifact hash |

Results are not bit-for-bit reproducible, even at temperature 0. Batch size and
hardware change the arithmetic. These two fields tell you exactly what produced
a result, not that a re-run will match it.

## Recommendations

### Send a deadline

```
Conflux-Timeout: 115
```

Seconds the client is still willing to wait, usually a little less than its own
HTTP timeout. The gateway **always answers within that time**: with a result,
with `429`, or with `503`. It never sends a request to a host whose expected
finish would pass the deadline.

It follows that a client timeout means the gateway itself is stuck, not that
the mesh is busy. Many clients treat repeated timeouts as a dead server and
back off for minutes. With a deadline, that backoff only triggers when it
should.

Without the header, the gateway uses a conservative default wait (about 30
seconds), then answers `429`.

### Honor `Retry-After`

`429` and `503` responses carry `Retry-After` in seconds, estimated from when
the gateway expects a slot to free up. It is usually short. Waiting exactly that
long, rather than a fixed pause, keeps slots from sitting idle between retries.

### Send a request ID

```
Idempotency-Key: <stable id for this unit of work>
```

Stable across retries of the same work. The gateway uses it to:

- return the original result when a client retries something that already
  finished;
- run extra copies of a slow request on other hosts and return exactly one
  answer. The gateway does this at the tail of a batch, when nothing is
  waiting, and with or without a key the client gets one answer per
  request. With a key, a retry gets that same answer.

### Allow generous concurrency

Set the client's concurrency **at or above the mesh's peak slot count**, not
tuned to one server. The gateway holds what hosts can't take yet, inside each
request's deadline, and answers `429` for the rest. Hosts join and leave during
a run. A generous fixed concurrency follows that without the client tracking
capacity.

### Choose models deliberately

Set `model` to one of:

| Value | Eligible hosts |
|---|---|
| An exact artifact ID from `/v1/models` | Only hosts serving that artifact |
| An alias, for example `any-vision` | Any host whose model has the capability |

To accept a list of models in order of preference:

```
Conflux-Models: model-a, model-b, model-c
```

The gateway takes the first model in the list that has a free slot. conflux
never ranks models itself. Whatever ran is in the response.

Some models refuse requests that others take. Apple's on-device model
declines some content, and takes only short requests. When a model refuses
that way, the gateway tries another host serving a model the request
accepts, so accepting more than one model avoids the refusal. With nowhere
else to go, the client gets `400` with `error.code` set to `content_filter`
or `context_length_exceeded`, as OpenAI's API names them, and `model` naming
the model that refused.

### Ask for a schema

A client that parses the answer should send its JSON Schema as
`response_format`, `{"type": "json_schema", "json_schema": {"schema": …}}`.
Hosts then constrain the model to the schema as it writes, so the answer
parses and matches, whatever the model's size: llama.cpp's hosts with a
grammar, and Apple's model with its guided generation.
Asked in words alone, a small model writes JSON of its own shape, or doesn't
stop. `{"type": "json_object"}` asks for any JSON object.

- **List what you need in `required`.** A property that isn't listed is
  optional, and the model may leave it out. Small models often leave out
  every one: asked for an object with nothing required, Gemma 3 4B answers
  `{}`, with `llama-server` too. `"strict": true` doesn't change that:
  conflux, like llama.cpp, ignores it.
- **Don't stop on what JSON contains.** A `stop` string still cuts the
  answer, so `"\n"` or `"}"` leaves JSON that doesn't parse.
- **Give it room.** A constrained answer can still run out of `max_tokens`,
  with `finish_reason` set to `length`, and then it isn't complete JSON.
- **Order the properties.** The model writes them in the schema's order,
  required ones first, so put what it should work out before what depends on
  it.
- **Use what's enforced:** `type`, `properties`, `required`,
  `additionalProperties`, `items`, `prefixItems`, `minItems`, `maxItems`,
  `minLength`, `maxLength`, `enum`, `const`, `anyOf`, `oneOf`, `allOf`,
  `$ref` within the schema, an integer's `minimum` and `maximum`, and the
  `date`, `time`, `date-time` and `uuid` formats. A number's bounds and other
  formats are left to the model, as llama.cpp leaves them.
- **`pattern` needs `llama-server`.** Hosts in the app don't enforce it yet,
  and neither does Apple's model. Either declines with `400` and
  `error.code` set to `unsupported_by_model`, and the gateway tries another
  host serving a model the request accepts, such as one running
  `conflux serve --runtime llama-server`.
- **Apple's model enforces less.** It takes objects with their properties
  listed, `required`, `items`, `minItems`, `maxItems`, `enum`, a string,
  integer or null `const`, `anyOf`, `oneOf`, a list of types, `$ref` within
  the schema, and an integer's `minimum` and `maximum`, and it shows each
  property's `description` to the model. It declines, in the same way, a
  string's `pattern`, `minLength`, `maxLength` or `format`, `allOf`,
  `prefixItems`, a schema that refers to itself, and an object, or any
  value, whose shape the schema leaves open, `{"type": "json_object"}`
  included. A schema with only what it takes can be answered by Apple's
  model as well as by llama.cpp's hosts.

### Send images at the size the model needs

Each model's entry in `/v1/models` includes the largest image dimension it
uses. Images larger than that cost transfer time and give no benefit. Image
resolution is also the main factor in how long a vision model spends reading
an image. Some models read small images badly, and their hosts enlarge them,
so a smaller image saves time only with a model that handles it
([measurements.md](measurements.md)).

## Status codes

| Status | Meaning | Client action |
|---|---|---|
| `200` | Result | Record it, with `model` and `system_fingerprint` |
| `400` | Malformed request, or the model refused it | Fix the request, or accept other models. Retrying the same won't help. `model` names the model that refused. |
| `401` | Missing or wrong token | Fix configuration |
| `404` | No host has served a model this request accepts since the gateway started | Check the model ID, or widen the accepted models |
| `429` | Mesh busy: no slot in time | Retry after `Retry-After` |
| `503` | Hosts failed and the deadline ran out, or every host for an accepted model is offline | Retry after `Retry-After` |
| `500` | The gateway itself failed | Treat as a broken server |

A failing host never shows up as `500`. The gateway retries on another host, or
answers `503`. `500` means the gateway itself is at fault.

## A client that does none of this

A stock OpenAI-compatible client, with no token support, no deadline header and
no request ID:

- works, if tokenless loopback access is allowed;
- gets `429` with `Retry-After` after the default wait (the official OpenAI
  SDKs retry those on their own);
- gets results whose `model` is accurate per response, whether or not it
  records them;
- can't benefit from duplicate suppression, so a retry after a timeout may run
  the request twice.
