## Orchestrator for the AI editing pipeline. Delegates all real work to the
## focused submodules under `src/ai/`; this file only wires the chunk loop
## and the artifact cache (Phase 4).

import std/[json, options, os, strformat, strutils]

import ./log
import ./ai/[apply, cache, faces, planner, transcribe, types, util]
import ./ai/env as aiEnv

proc parseCachedFaces(raw: string): Option[FaceTracks] =
  ## Rebuild `FaceTracks` from a cached Python-emitted JSON string. Mirrors
  ## `faces.parseFaceTracks` (which is private) without round-tripping back
  ## through the Python process. On any schema mismatch we return `none` so
  ## the caller falls back to a fresh detection run.
  var node: JsonNode
  try:
    node = parseJson(raw)
  except JsonParsingError, ValueError:
    return none(FaceTracks)
  if node.kind != JObject: return none(FaceTracks)
  if not node.hasKey("schema") or node["schema"].kind != JInt or
      node["schema"].getInt() != 2:
    return none(FaceTracks)
  if not node.hasKey("tracks") or node["tracks"].kind != JArray:
    return none(FaceTracks)
  var tracks: FaceTracks
  tracks.videoFps = jsonFloat(node, "video_fps", 0.0)
  tracks.sourceWidth = jsonFloat(node, "source_width", 0.0).int32
  tracks.sourceHeight = jsonFloat(node, "source_height", 0.0).int32
  for trackNode in node["tracks"]:
    if trackNode.kind != JObject: continue
    var track = FaceTrack(
      id: jsonFloat(trackNode, "id", -1.0).int32,
      hits: jsonFloat(trackNode, "hits", 0.0).int32,
    )
    if trackNode.hasKey("frames") and trackNode["frames"].kind == JArray:
      for frameNode in trackNode["frames"]:
        if frameNode.kind != JObject: continue
        track.frames.add FaceFrame(
          time: jsonFloat(frameNode, "time", 0.0),
          x: jsonFloat(frameNode, "x", -1.0).float32,
          y: jsonFloat(frameNode, "y", -1.0).float32,
          w: jsonFloat(frameNode, "w", 0.0).float32,
          h: jsonFloat(frameNode, "h", 0.0).float32,
          conf: jsonFloat(frameNode, "conf", 0.0).float32,
          trackId: track.id,
        )
    tracks.tracks.add track
  some(tracks)

proc applyAi*(args: var mainArgs) =
  if args.inputs.len != 1:
    error "--ai currently supports exactly one input file"
  if args.aiProvider != "openai":
    error &"--ai-provider '{args.aiProvider}' is not implemented yet. Use openai."
  if aiEnv.getSecret("OPENAI_API_KEY") == "":
    error "--ai-provider openai requires OPENAI_API_KEY in the environment or .env"
  if args.aiChunkSecs < 5 or args.aiChunkSecs > 600:
    error "--ai-chunk-secs must be between 5 and 600"

  let inputPath = args.inputs[0]
  let faceScript = resolveFaceScript(args.aiFaceScript)
  let pythonPath = resolvePython(args.aiPython)
  let whisperPython = resolveWhisperPython(args.aiWhisperPython)
  let duration = mediaDuration(inputPath)
  if duration <= 0.0:
    error "--ai could not determine media duration"

  let aiCache = initAiCache(args)

  # ---- Transcript (cached) ------------------------------------------------
  let transcript =
    block:
      let cached = aiCache.getTranscript(inputPath, args.aiWhisperModel,
        args.aiLanguage)
      if cached.isSome:
        debug "AI: using cached transcript"
        cached.get()
      else:
        let t = runWhisper(inputPath, args.aiWhisperModel, args.aiLanguage,
          args.aiWhisperCommand, whisperPython)
        aiCache.putTranscript(inputPath, args.aiWhisperModel,
          args.aiLanguage, t)
        t
  let transcriptSegments = parseTranscript(transcript)
  if transcriptSegments.len == 0 and transcript.strip().len > 0:
    warning "AI: could not parse transcript into segments; planner will run without transcript context."

  # ---- Face tracks (cached) ----------------------------------------------
  var facesJsonRaw = ""
  let faceTracks =
    block:
      let cachedRaw = aiCache.getFaces(inputPath, faceScript)
      var result: FaceTracks
      var hit = false
      if cachedRaw.isSome:
        let parsed = parseCachedFaces(cachedRaw.get())
        if parsed.isSome:
          debug "AI: using cached faces"
          result = parsed.get()
          facesJsonRaw = cachedRaw.get()
          hit = true
        else:
          warning "AI: cached faces artifact was unusable; re-detecting."
      if not hit:
        result = runFaceDetection(inputPath, faceScript, pythonPath)
        # Re-serialize to a stable JSON form so we can round-trip it.
        var tracksArr = newJArray()
        for track in result.tracks:
          var framesArr = newJArray()
          for f in track.frames:
            framesArr.add(%* {
              "time": f.time,
              "x": f.x.float64,
              "y": f.y.float64,
              "w": f.w.float64,
              "h": f.h.float64,
              "conf": f.conf.float64,
            })
          tracksArr.add(%* {
            "id": track.id.int,
            "hits": track.hits.int,
            "frames": framesArr,
          })
        let payload = %* {
          "schema": 2,
          "video_fps": result.videoFps,
          "source_width": result.sourceWidth.int,
          "source_height": result.sourceHeight.int,
          "tracks": tracksArr,
        }
        facesJsonRaw = $payload
        aiCache.putFaces(inputPath, faceScript, facesJsonRaw)
      result
  let faces = toFaceSamples(faceTracks)

  if args.aiDebugFaces != "":
    try:
      writeFile(args.aiDebugFaces, facesJsonRaw)
      debug &"AI: wrote face tracks to {args.aiDebugFaces}"
    except OSError, IOError:
      warning &"AI: failed to write --ai-debug-faces to {args.aiDebugFaces}: {getCurrentExceptionMsg()}"

  let userActions = args.setAction
  args.setAction = @[]
  args.edit = "none"
  args.whenNormal = aNil

  # ---- Per-chunk plans (cached) ------------------------------------------
  var chunkStart = 0.0
  var dumpedChunks = newJArray()
  while chunkStart < duration:
    let chunkStop = min(duration, chunkStart + args.aiChunkSecs.float64)
    let plan =
      block:
        let cached = aiCache.getPlan(inputPath, args.aiWhisperModel,
          args.aiLanguage, faceScript, args.aiModel, args.aiProvider,
          args.aiChunkSecs, chunkStart, chunkStop)
        if cached.isSome:
          debug &"AI: using cached plan for chunk {chunkStart}-{chunkStop}"
          cached.get()
        else:
          let p = planChunk(args, transcriptSegments, faces,
            chunkStart, chunkStop, duration)
          aiCache.putPlan(inputPath, args.aiWhisperModel, args.aiLanguage,
            faceScript, args.aiModel, args.aiProvider, args.aiChunkSecs,
            chunkStart, chunkStop, p)
          p
    if args.aiDumpPlan != "":
      var segmentsNode = newJArray()
      if plan.kind == JObject and plan.hasKey("segments") and
          plan["segments"].kind == JArray:
        segmentsNode = plan["segments"]
      dumpedChunks.add(%* {
        "start": chunkStart,
        "end": chunkStop,
        "segments": segmentsNode,
      })
    addPlanActions(args, plan, faceTracks, faces, chunkStart, chunkStop, duration)
    chunkStart = chunkStop

  if args.aiDumpPlan != "":
    var totalFrames = 0
    for track in faceTracks.tracks:
      totalFrames += track.frames.len
    let dump = %* {
      "input": try: absolutePath(inputPath) except OSError, ValueError: inputPath,
      "duration": duration,
      "chunkSecs": args.aiChunkSecs,
      "aiModel": args.aiModel,
      "aiProvider": args.aiProvider,
      "chunks": dumpedChunks,
      "faceTracks": {
        "count": faceTracks.tracks.len,
        "total_frames": totalFrames,
      },
      "transcriptSegmentCount": transcriptSegments.len,
    }
    try:
      writeFile(args.aiDumpPlan, dump.pretty())
      debug &"AI: wrote plan dump to {args.aiDumpPlan}"
    except OSError, IOError:
      warning &"AI: failed to write --ai-dump-plan to {args.aiDumpPlan}: {getCurrentExceptionMsg()}"

  for action in userActions:
    args.setAction.add action
  clearline()

  if args.aiDryRun:
    echo "AI dry run complete."
    quit(0)
