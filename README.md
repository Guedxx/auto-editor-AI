<p align="center"><img src="https://auto-editor.com/img/auto-editor-banner.webp" title="Auto-Editor" width="700"></p>

**Auto-Editor** is a command line application for automatically **editing video and audio** by analyzing a variety of methods, most notably audio loudness.

---

[![Actions Status](https://img.shields.io/github/actions/workflow/status/wyattblue/auto-editor/build.yml?style=flat)](https://github.com/wyattblue/auto-editor/actions)
[![Nim](https://img.shields.io/badge/nim-%23FFE953.svg?style=flat&logo=nim&logoColor=black)](https://nim-lang.org)

Before doing the real editing, you first cut out the "dead space" which is typically silence. This is known as a "first pass". Cutting these is a boring task, especially if the video is very long.

```
auto-editor path/to/your/video.mp4
```

<h2 align="center">Installing</h2>

See [Installing](https://auto-editor.com/installing) for more information.


<h2 align="center">Cutting</h2>

Change the **pace** of the edited video by using `--margin`.

`--margin` adds in some "silent" sections to make the editing feel nicer.

```
# Add 0.2 seconds of padding before and after to make the edit nicer.
# `0.2s` is the default value for `--margin`
auto-editor example.mp4 --margin 0.2sec

# Add 0.3 seconds of padding before, 1.5 seconds after
auto-editor example.mp4 --margin 0.3s,1.5sec
```

### Methods for Making Automatic Cuts
The `--edit` option is how auto-editor makes automated cuts.

For example, edit out motionlessness in a video by setting `--edit motion`.

```
# cut out sections where the total motion is less than 2%.
auto-editor example.mp4 --edit motion:threshold=0.02

# `--edit audio:threshold=0.04,stream=all` is used by defaut.
auto-editor example.mp4

# Different tracks can be set with different attribute.
auto-editor multi-track.mov --edit "(or audio:stream=0 audio:threshold=10%,stream=1)"
```

Different editing methods can be used together.
```
# 'threshold' is always the first argument for edit-method objects
auto-editor example.mp4 --edit "(or audio:0.03 motion:0.06)"
```

### AI-Assisted Editing

This fork adds an experimental `--ai` pass that transcribes the input with a
local whisper.cpp ggml model, sends small timeline windows to an LLM planner,
and applies the returned cuts, speed changes, phrase-boundary adjustments, and
face-aware zooms through the normal auto-editor renderer.

When the planner emits a zoomed `keep` segment, the zoom is stored as a
keyframed animation on that clip: the face track is sampled at ~8 Hz with
a 0.20 s smoothstep ease-in and ease-out on the zoom factor, and the
renderer (or any NLE that imports the exported project) interpolates the
scale/position per frame. Result: the crop glides continuously into the
speaker's face instead of stepping in discrete sub-windows.

The same keyframe list is emitted natively in every supported project
export — Kdenlive (MLT `qtblend` Transform filter with an animated `rect`
property), Shotcut (MLT `affine` filter with an animated `transition.rect`
property), Premiere / older Resolve (FCP7 `Basic Motion` filter with
keyframed `scale` and `center` parameters) and Final Cut Pro 11 /
modern Resolve (FCPXML `<adjust-transform>` with `<keyframeAnimation>`
on `scale` and `position`). Open the exported project in your editor of
choice and the zoom keyframes show up as draggable handles you can
fine-tune by hand.

`--ai` currently supports OpenAI first and requires Python OpenCV for face
tracking:

```
OPENAI_API_KEY=... auto-editor example.mp4 \
  --ai \
  --ai-whisper-model path/to/ggml-model.bin
```

You can also put the key in a local `.env` file. `.env` is ignored by Git:

```
OPENAI_API_KEY=sk-...
```

Useful options:
- `--ai-model MODEL` sets the OpenAI model. The default is `gpt-5.4-mini`.
- `--ai-chunk-secs SECS` controls LLM planning window size. The default is 45.
- `--ai-language LANG` passes a fixed language to Whisper instead of `auto`.
- `--ai-whisper-command PATH` points to `whisper-cli` when FFmpeg lacks the
  `whisper` filter.
- `--ai-whisper-python PATH` points to a Python executable with
  `openai-whisper` installed. On Arch, `extra/python-openai-whisper` makes
  system `python3` work.
- `--ai-face-script PATH` points to a custom OpenCV helper.
- `--ai-python PATH` points to the Python executable used for OpenCV. If unset,
  `.venv/bin/python` is used when present, otherwise `python3`.
- `--ai-no-cache` disables the artifact cache (see below) for a single run;
  neither reads nor writes will touch disk.

#### Debugging AI plans

Three flags expose the AI pipeline's intermediate artifacts without having
to wait for a full render:

- `--ai-dump-plan PATH` writes the full per-chunk edit plan (including
  every segment's action, speed, zoom and reason) to `PATH` as JSON after
  planning finishes. Diff, grep, or hand-edit before rerunning.
- `--ai-dry-run` plans with AI (and dumps the plan / faces if those flags
  are also set) but skips the actual render. It prints
  `AI dry run complete.` and exits 0. Useful for iterating on prompts and
  chunk sizes without burning encoder time.
- `--ai-debug-faces PATH` writes the raw face-detection JSON (the same
  payload that lives in the cache) to `PATH`. Same schema the YuNet helper
  emits.

Example workflow — plan and inspect without rendering:

```
OPENAI_API_KEY=... auto-editor example.mp4 --ai \
  --ai-whisper-model path/to/ggml-model.bin \
  --ai-dry-run --ai-dump-plan plan.json --ai-debug-faces faces.json
```

Caching: every `--ai` run caches three expensive artifacts to
`$XDG_CACHE_HOME/auto-editor-ai/` (or `~/.cache/auto-editor-ai/` if
`XDG_CACHE_HOME` is empty; `%LOCALAPPDATA%\auto-editor-ai\` on Windows):
the Whisper transcript, the YuNet face-detection JSON, and the per-chunk
OpenAI edit plans. Subsequent runs on the same input reuse the cache
automatically — rerunning `--ai` after tweaking `--ai-chunk-secs`,
`--ai-model`, `--ai-whisper-model`, or `--ai-language` invalidates only the
affected artifacts, so iteration stays cheap. Corrupted or unparseable
cache entries are treated as misses and overwritten on the next successful
run. Pass `--ai-no-cache` to force a full rebuild.

Face detection uses OpenCV's YuNet DNN detector. The ONNX weights
(~230 KB) are auto-downloaded on first run to
`~/.cache/auto-editor-ai/models/` (or `$XDG_CACHE_HOME/auto-editor-ai/models/`
if set). `--ai-face-script PATH` still overrides the whole helper if you
want to supply your own detector.

Recommended local Python setup:

```
python -m venv .venv
.venv/bin/pip install -r requirements-ai.txt
```

On Arch Linux, install the native development/runtime packages first:

```
sudo pacman -S --needed base-devel git nim nimble pkgconf ffmpeg python python-pip python-virtualenv
```

For the `--ai` path with a dynamic/system FFmpeg build, also install a
whisper.cpp CLI provider if your FFmpeg does not list the `whisper` filter:

```
sudo pacman -S --needed whisper.cpp
```

If your package source names the binary differently, pass it explicitly with
`--ai-whisper-command /path/to/whisper-cli`.

You can also use `dB` unit, a volume unit familiar to video-editors (case sensitive):
```
auto-editor example.mp4 --edit audio:-19dB
auto-editor example.mp4 --edit audio:-7dB
auto-editor example.mp4 --edit motion:-19dB
```

### See What Auto-Editor Cuts Out
To export what auto-editor normally cuts out. Set `--when-normal` to `cut` and `--when-silent` to `nil` (leave as is). This is the reverse of the usual default values.

```
auto-editor example.mp4 --when-normal cut --when-silent nil
```

<h2 align="center">Exporting to Editors</h2>

Create an XML file that can be imported to Adobe Premiere Pro using this command:

```
auto-editor example.mp4 --export premiere
```

Auto-Editor can also export to:
- DaVinci Resolve with `--export resolve`
- Final Cut Pro with `--export final-cut-pro`
- ShotCut with `--export shotcut`
- Kdenlive with `--export kdenlive`
- Individual media clips with `--export clip-sequence`

### Naming Timelines
Some editors support naming timelines. By default, auto-editor will use the name "Auto-Editor Media Group". For `premiere` `resolve` and `final-cut-pro` export options, you can change the name with the following syntax.

```
# for POSIX shells
auto-editor example.mp4 --export 'premiere:name="Your name here"'

# for Powershell
auto-editor example.mp4 --export 'premiere:name=""Your name here""'
```

### Split by Clip

If you want to split the clips, but don't want auto-editor to do any more editing. There's a simple command.
```
auto-editor example.mp4 --when-silent nil --when-normal nil --export premiere
```

<h2 align="center">Importing timeline files</h2>
Auto-Editor can read fcp7 xml files and render them as media files:

```
auto-editor myFcp7File.xml -o render.mp4
```

Available Importers:
 - Auto-Editor timeline files (`.v1`, `.v2`, `.v3`)
 - FCP7 XML (experimental)

PRs implementing more importers are encouraged.

<h2 align="center">Manual Editing</h2>

Use the `--cut-out` option to always remove a section.

```
# Cut out the first 30 seconds.
auto-editor example.mp4 --cut-out 0,30sec

# Cut out the first 30 frames.
auto-editor example.mp4 --cut-out 0,30

# Always leave in the first 30 seconds.
auto-editor example.mp4 --add-in 0,30sec

# Cut out the last 10 seconds.
auto-editor example.mp4 --cut-out -10sec,end

# You can do multiple at once.
auto-editor example.mp4 --cut-out 0,10 15sec,20sec
auto-editor example.mp4 --add-in 30sec,40sec 120,150sec
```

And of course, you can use any `--edit` configuration.

If you don't want **any automatic cuts**, you can use `--edit none` or `--edit all`

```
# Cut out the first 5 seconds, leave the rest untouched.
auto-editor example.mp4 --edit none --cut-out 0,5sec

# Leave in the first 5 seconds, cut everything else out.
auto-editor example.mp4 --edit all --add-in 0,5sec
```

<h2 align="center">More Options</h2>

List all available options:

```
auto-editor --help
```

## Articles
 - [How to Install Auto-Editor](https://auto-editor.com/installing)
 - [All the Options (And What They Do)](https://auto-editor.com/ref/options)
 - [Docs](https://auto-editor.com/docs)
 - [Blog](https://basswood-io.com/blog/)

## GUI Application
There is a graphical application [available](https://app.auto-editor.com) under a propriety license. No GUI code, or proprietary code/assets, are included in this repository.

## Copyright
Everything in this repository is under the [Public Domain](https://github.com/WyattBlue/auto-editor/blob/master/LICENSE). Binary artifacts in the "Releases" section may be under various open source licenses.
