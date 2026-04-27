## OpenAI planner: builds per-chunk prompts / schema, POSTs to the
## `/v1/responses` endpoint, and returns the parsed edit-plan JSON.
##
## Responsibilities that changed in Phase 3:
##
## - Transcript parsing is now done once by the caller; the planner accepts
##   a parsed `seq[TranscriptSegment]` and filters it to the per-chunk
##   window (with a ±3 s context overlap for coherent reasoning).
## - Every HTTP call has exponential-backoff retry on 429 / 5xx / connection
##   errors (1 s, 2 s, 4 s; up to 3 attempts).
## - Parse / schema failures no longer abort the whole edit: the planner
##   `warning`s and returns a "keep whole chunk" fallback plan.
## - Schema clamps `speed` (0.75-1.5), `zoom` (1.0-1.35), and requires a
##   `reason` string used for debug logging.
## - A one-line `debug` summary per chunk (and per cut/zoom segment in
##   debug mode) makes it easy to see what the model decided.

import std/[httpclient, json, math, os, strformat, strutils]

import ./[env, faces, schema, types, util]
import ../log

export schema.TranscriptSegment, schema.parseTranscript

const
  RetryStatusCodes = @["429", "500", "502", "503", "504"]
  RetryBackoffs = @[1.0, 2.0, 4.0]   # attempts 1, 2, 3 sleep this long after failing
  ContextOverlapSecs = 3.0
  SystemPrompt = """
You are an autonomous video-editing planner.

Return a single JSON object conforming to the strict schema. Rules:

1. The core window is [windowStart, windowStop]. You will also see
   ±3 seconds of context transcript outside the core window for
   coherent reasoning, but DO NOT emit any segment whose midpoint
   lies outside the core window.
2. Segments must be sorted by `start`, non-overlapping, and must
   jointly cover the entire core window. Fill any unused gap with
   `{action: "keep", speed: 1.0, zoom: 1.0, reason: "filler"}`.
3. Cut on phrase boundaries; avoid mid-word cuts. Prefer cutting
   long pauses, filler words, false starts, and repeated phrases.
4. Speed defaults to 1.0. Use 1.08-1.25 only to tighten slow or
   repeated material. Never < 0.75, never > 1.5.
5. Zoom only on short emphasis beats (≤ 4 s windows), preferred
   range 1.12-1.25, never > 1.35. Do not zoom whole sentences.
6. Always populate `reason` with a short debug note (1-6 words),
   e.g. "filler pause", "emphasis beat", "normal speech".
"""

proc summarisePlan(plan: JsonNode, chunkStart, chunkStop: float64) =
  ## Emit a debug one-liner + per-cut/zoom `reason` log.
  if not isDebug: return
  if plan.kind != JObject or not plan.hasKey("segments") or
      plan["segments"].kind != JArray:
    return
  let segs = plan["segments"]
  var cuts, keeps, zooms: int
  for s in segs:
    if s.kind != JObject: continue
    if jsonStr(s, "action", "keep") == "cut":
      inc cuts
    else:
      inc keeps
    if jsonFloat(s, "zoom", 1.0) > 1.01:
      inc zooms
  debug(&"AI chunk {round(chunkStart, 1)}-{round(chunkStop, 1)} " &
    &"({segs.len} segments: {cuts} cut, {keeps} keep; {zooms} zoom)")
  for s in segs:
    if s.kind != JObject: continue
    let act = jsonStr(s, "action", "keep")
    let zoom = jsonFloat(s, "zoom", 1.0)
    if act == "cut" or zoom > 1.01:
      let start = jsonFloat(s, "start", 0.0)
      let stop = jsonFloat(s, "end", 0.0)
      let reason = jsonStr(s, "reason", "")
      debug(&"  {round(start, 2)}-{round(stop, 2)} {act} " &
        &"speed={jsonFloat(s, \"speed\", 1.0)} zoom={zoom} reason={reason}")

proc fallbackPlan(chunkStart, chunkStop: float64): JsonNode =
  ## "Keep the whole chunk untouched" — used whenever the model or the
  ## network fails in a way we can recover from.
  %* {
    "segments": [
      {
        "start": chunkStart,
        "end": chunkStop,
        "action": "keep",
        "speed": 1.0,
        "zoom": 1.0,
        "reason": "planner-fallback"
      }
    ]
  }

proc validatePlan(plan: JsonNode, chunkStart, chunkStop: float64): bool =
  ## Minimal post-validation beyond strict-mode schema: ensure at least one
  ## well-formed segment lies within the core window. `apply.nim` does its
  ## own clamping on top of this.
  if plan.kind != JObject or not plan.hasKey("segments"):
    return false
  if plan["segments"].kind != JArray or plan["segments"].len == 0:
    return false
  for seg in plan["segments"]:
    if seg.kind != JObject: return false
    if not seg.hasKey("start") or not seg.hasKey("end"): return false
    if not seg.hasKey("action") or seg["action"].kind != JString: return false
    let act = seg["action"].getStr()
    if act != "keep" and act != "cut": return false
  true

proc clipPlanToCoreWindow(plan: JsonNode, chunkStart, chunkStop: float64): JsonNode =
  ## Drop/clip any segment whose midpoint falls outside the core window,
  ## then clamp the remaining segments to `[chunkStart, chunkStop]`.
  ## Preserves the "segments only inside core window" invariant that the
  ## orchestrator relies on for its non-overlapping chunk walk.
  result = newJObject()
  var kept = newJArray()
  if plan.kind == JObject and plan.hasKey("segments") and
      plan["segments"].kind == JArray:
    for seg in plan["segments"]:
      if seg.kind != JObject: continue
      let s = jsonFloat(seg, "start", chunkStart)
      let e = jsonFloat(seg, "end", chunkStop)
      if e <= s: continue
      let mid = (s + e) / 2.0
      if mid < chunkStart or mid > chunkStop: continue
      var clipped = copy(seg)
      clipped["start"] = %max(s, chunkStart)
      clipped["end"] = %min(e, chunkStop)
      kept.add clipped
  result["segments"] = kept

proc buildPayload(args: mainArgs, transcriptSegments: seq[TranscriptSegment],
    faces: seq[FaceSample], chunkStart, chunkStop, duration: float64): JsonNode =
  let ctxStart = max(0.0, chunkStart - ContextOverlapSecs)
  let ctxStop = min(duration, chunkStop + ContextOverlapSecs)
  let compactTranscript = compactTranscriptJson(transcriptSegments,
    ctxStart, ctxStop)
  let userPrompt = &"""
Plan an automatic video edit for ONLY this core window.

windowStart: {chunkStart}
windowStop: {chunkStop}
mediaDuration: {duration}

Context window (±3 s outside core, for reasoning only): [{ctxStart}, {ctxStop}].
Do NOT emit segments whose midpoint is outside the core window.

Transcript segments (compact JSON `[start, end, text]` triples,
pre-filtered to the context window):
{compactTranscript}

Face samples in this window (normalized x/y, size=bbox area):
{faceSamplesJson(faces, chunkStart, chunkStop)}
"""
  %* {
    "model": args.aiModel,
    "input": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userPrompt}
    ],
    "text": {
      "format": {
        "type": "json_schema",
        "name": "auto_editor_ai_plan",
        "strict": true,
        "schema": planSchema()
      }
    }
  }

type OpenAiAttempt = object
  retry*: bool        ## true => transient, caller should back off and retry
  status*: string     ## HTTP status line or synthetic "exception"
  body*: string       ## response body (or exception message)

proc postOnce(apiKey, payload: string): OpenAiAttempt =
  var client = newHttpClient()
  client.headers = newHttpHeaders([
    ("Authorization", "Bearer " & apiKey),
    ("Content-Type", "application/json"),
  ])
  defer: client.close()
  try:
    let res = client.request("https://api.openai.com/v1/responses",
      httpMethod = HttpPost, body = payload)
    let code = res.status.split(' ')[0]
    result = OpenAiAttempt(
      retry: code in RetryStatusCodes,
      status: res.status,
      body: res.body,
    )
  except OSError, IOError, HttpRequestError:
    result = OpenAiAttempt(
      retry: true,
      status: "exception",
      body: getCurrentExceptionMsg(),
    )

proc planChunk*(args: mainArgs, transcriptSegments: seq[TranscriptSegment],
    faces: seq[FaceSample], chunkStart, chunkStop, duration: float64): JsonNode =
  ## Build a per-chunk edit plan. On any recoverable failure (retryable
  ## HTTP, network error, non-JSON response, or failed schema validation)
  ## `warning`s and returns `fallbackPlan(chunkStart, chunkStop)` instead of
  ## aborting the whole edit.
  let apiKey = getSecret("OPENAI_API_KEY")
  if apiKey == "":
    error "--ai-provider openai requires OPENAI_API_KEY in the environment or .env"

  let payload = $buildPayload(args, transcriptSegments, faces,
    chunkStart, chunkStop, duration)

  conwrite(&"AI: planning {round(chunkStart, 1)}s-{round(chunkStop, 1)}s...")

  var attempt: OpenAiAttempt
  for i, backoff in RetryBackoffs:
    attempt = postOnce(apiKey, payload)
    if not attempt.retry and attempt.status.startsWith("2"):
      break
    if i == RetryBackoffs.high:
      break
    if attempt.retry:
      debug(&"AI: OpenAI attempt {i + 1} failed ({attempt.status}); " &
        &"retrying after {backoff}s")
      sleep(int(backoff * 1000.0))
    else:
      # Non-retryable non-2xx: break out and let the error branch handle it.
      break

  if attempt.status == "exception":
    warning(&"OpenAI request failed after retries: {attempt.body}. " &
      "Falling back to keep-whole-chunk for this window.")
    return fallbackPlan(chunkStart, chunkStop)
  if not attempt.status.startsWith("2"):
    warning(&"OpenAI request failed ({attempt.status}): " &
      attempt.body[0 .. min(199, attempt.body.high)] &
      ". Falling back to keep-whole-chunk for this window.")
    return fallbackPlan(chunkStart, chunkStop)

  var responseJson: JsonNode
  try:
    responseJson = parseJson(attempt.body)
  except JsonParsingError, ValueError:
    warning(&"OpenAI (model={args.aiModel}) returned non-JSON response: " &
      attempt.body[0 .. min(199, attempt.body.high)] &
      ". Falling back to keep-whole-chunk for this window.")
    return fallbackPlan(chunkStart, chunkStop)

  if responseJson.kind == JObject and responseJson.hasKey("error") and
      responseJson["error"].kind != JNull:
    warning(&"OpenAI error ({args.aiModel}): " & ($responseJson["error"])[0 ..
      min(199, ($responseJson["error"]).high)] &
      ". Falling back to keep-whole-chunk for this window.")
    return fallbackPlan(chunkStart, chunkStop)

  let text = extractOutputText(responseJson).strip()
  if text == "":
    warning(&"OpenAI response missing output_text (model={args.aiModel}). " &
      "Falling back to keep-whole-chunk for this window.")
    return fallbackPlan(chunkStart, chunkStop)

  var plan: JsonNode
  try:
    plan = parseJson(text)
  except JsonParsingError, ValueError:
    warning(&"OpenAI (model={args.aiModel}) returned non-JSON plan: " &
      text[0 .. min(199, text.high)] &
      ". Falling back to keep-whole-chunk for this window.")
    return fallbackPlan(chunkStart, chunkStop)

  if not validatePlan(plan, chunkStart, chunkStop):
    warning(&"OpenAI (model={args.aiModel}) returned plan that failed " &
      "schema validation: " & text[0 .. min(199, text.high)] &
      ". Falling back to keep-whole-chunk for this window.")
    return fallbackPlan(chunkStart, chunkStop)

  result = clipPlanToCoreWindow(plan, chunkStart, chunkStop)
  if result["segments"].len == 0:
    warning(&"OpenAI (model={args.aiModel}) returned no in-window segments. " &
      "Falling back to keep-whole-chunk for this window.")
    return fallbackPlan(chunkStart, chunkStop)
  summarisePlan(result, chunkStart, chunkStop)

proc openAiPlanChunk*(args: mainArgs, transcriptSegments: seq[TranscriptSegment],
    faces: seq[FaceSample], chunkStart, chunkStop, duration: float64): JsonNode =
  ## Thin back-compat alias. Future caching (Phase 4) will wrap this.
  planChunk(args, transcriptSegments, faces, chunkStart, chunkStop, duration)
