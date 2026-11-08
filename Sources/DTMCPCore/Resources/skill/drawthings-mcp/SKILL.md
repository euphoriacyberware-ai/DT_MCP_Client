---
name: drawthings-mcp
description: Generate and edit images and video with a Draw Things server through the DT MCP Client tools. Use when the user asks you to create, draw, edit, inpaint, restyle or animate a picture, or to make a video clip.
---

# Draw Things image and video generation

You control a Draw Things server through MCP tools. Generation is **asynchronous**: you start a job, then wait for it. Files are saved on the user's computer and the tools return their paths.

## The workflow (follow in order)

1. `get_server_status`. If `connected` is not `"true"`, stop and tell the user what the `error` says. Do not retry in a loop.
2. `list_models` (use `query` to narrow). Pick a model. Never invent a file name; use the `file` value exactly. If the user already told you which model to use, check the list but do not switch models when it is missing (see the rules below).
3. `get_model_recommendations` with that model. Use the returned `native_size` for width and height.
   - If it returns `sampler`, `steps`, `guidance_scale` and `shift`, pass them.
   - If they are missing, do not guess. Omit them to use the user's defaults, or ask the user what the model needs.
4. `generate_image` (or `generate_video`). It returns a `job_id` immediately with status `queued`.
5. `wait_for_job` with that `job_id` (try `timeout_seconds` 120). If the status is still `queued` or `running`, call it again. Images take seconds to a minute or two; video takes longer.
6. When the status is `completed`, read `outputs` (absolute file paths) and tell the user where the files are. You can open the image yourself only if you have a way to view files.

Statuses: `queued`, `running`, `completed`, `failed`, `cancelled`. A `failed` job has an `error` message; read it (see "When something goes wrong").

## Tools

| Tool | Use it to |
|---|---|
| `get_server_status` | Check the connection. Call first. |
| `list_models` / `list_loras` / `list_controlnets` / `list_upscalers` | See what is installed. All accept `query`, `limit`, `include_deprecated`. LoRA and ControlNet lists also accept `compatible_with` (a model file). |
| `get_model_recommendations` | Get size and settings for a model. |
| `generate_image` | Text-to-image, img2img, inpaint, ControlNet, optional upscaling. |
| `generate_video` | Video from text, or from a start image. |
| `extract_frames` | Save the first, last or any frames of an existing .mp4 as PNG files. |
| `process_video` | Make a new video from an .mp4 or frames folder: upscale, smoother motion or slow motion, change frame rate. |
| `wait_for_job` / `get_job` / `list_jobs` | Follow jobs. Prefer `wait_for_job`. |
| `cancel_job` | Stop a queued or running job. |

Jobs run one at a time. If you start several, they queue in order.

## Rules that prevent most failures

- `width` and `height` must be positive **multiples of 64**. Stay near the model's `native_size`; much larger sizes are slow and often rejected by the user's limits.
- Use model, LoRA, ControlNet and upscaler file names that the list tools returned. **Exception: the user named it.** The server's lists can be incomplete. If the user gives an exact file name (for example `my_model_q8p.ckpt`) that is missing from the list, pass it exactly as written. `generate_image` does not reject unlisted model or LoRA names; the server will say if it truly lacks the file. Never swap in a different model or LoRA because the list lacks the one requested.
- **Never guess settings.** If a model has no recommendation (`get_model_recommendations` returns no sampler, steps, guidance or shift), do not invent values from similar models. Use the user's stated settings, or omit them and use the app defaults, or ask the user. One wrong value can produce no image or a bad one.
- A LoRA or ControlNet must match the model's family. Use `compatible_with` with the model file when listing.
- If a LoRA has a `trigger_prefix`, include that text in your prompt.
- Image paths you pass in (`init_image`, `mask_image`, control `image`) must be **absolute paths inside a folder the user granted** in the app. The output folder counts, so you can refine earlier results. If a call says the path is outside the granted folders, ask the user to add that folder in the app. Do not try other locations.
- Omit `seed` for a random result. The seed that was used is in the job; reuse it with a small prompt change to keep the same composition.
- Do not call `wait_for_job` or `get_job` repeatedly with no delay. One `wait_for_job` already waits.
- Describe what you want, not what you do not want. Put things to avoid in `negative_prompt` only if the model uses one.

## Recipes

### Text to image
```
generate_image { prompt, model, width, height }   // plus recommended steps/sampler/guidance_scale/shift
```
Write a concrete prompt: subject, setting, lighting, style, camera or medium. Example: "a red fox sitting in a snowy forest, golden hour, photo".

### Change an existing image (img2img)
```
generate_image { prompt, init_image: "/abs/path.png", strength: 0.6 }
```
- `strength` is how much the picture may change: low keeps it, high rewrites it.
- Fast "turbo" models barely change the picture below about 0.8. Use **0.85 to 0.95** for big changes such as a new scene or lighting, and 0.5 to 0.7 for small ones.
- If you leave out `width` and `height`, the size follows the image.

### Inpaint (change only part of an image)
```
generate_image { prompt, init_image, mask_image, mask_mode: "white" }
```
- The mask is a separate image, same shape as the init image. By default **white** marks the area to regenerate and **black** marks what to keep. Use `mask_mode: "black"` if your mask is the other way round, or `"alpha"` if transparent pixels mark the area.
- If you can run code, make the mask yourself and save it into a granted folder (the output folder is fine). Otherwise ask the user for one.
- The `prompt` should describe what goes **into the masked area**, not the whole picture. Example: "a small wooden sled in the snow".
- The job note reports how much of the image was regenerated. If that is 0% or 100%, the mask is probably wrong.

### ControlNet (follow a layout)
```
generate_image { prompt, model, controls: [ { file, image, hint_type?, weight?, guidance_end? } ] }
```
- First `list_controlnets` with `compatible_with` set to your model. If the list is empty, ControlNet is not available for that model; use img2img instead and tell the user.
- `image` must already be the **control map** (depth map, edge image, pose skeleton, scribble), not an ordinary photo. This tool does not create maps.
- `hint_type` is guessed from the file name; pass it (`depth`, `canny`, `pose`, `scribble`, `softedge`, `lineart`, `seg`, `mlsd`, `tile`) if the call asks for it.
- Lower `guidance_end` (for example 0.7) gives the model more freedom. `mode` can be `balanced`, `prompt` or `control`.

### Upscale
```
generate_image { prompt, init_image: "/abs/path.png", strength: 0.2, upscaler: "<file from list_upscalers>" }
```
- Upscaling happens as part of a generation; there is no separate upscale-only tool. Use a **low strength** (0.1 to 0.3) so the picture stays the same and only gets larger and sharper. Use the original prompt.
- The saved image is larger than `width` x `height` by the upscaler's factor (for example 2x).
- If `list_upscalers` is empty, tell the user no upscaler is installed.

### Video
```
generate_video { prompt, model, num_frames, width, height }   // optional init_image for a start frame
```
- You need a **video model** (names like Wan, LTX, Hunyuan). Search with `list_models` and `query`. If none is installed, tell the user; image models are rejected.
- Clip length is `num_frames` divided by the model's frame rate. Typical counts are 33, 49 or 81. Longer clips take much longer and may exceed the user's limit.
- `outputs` is `[the .mp4, the first frame as .png]`, plus `last_frame.png` if you set `save_last_frame`, plus a frames folder if you set `save_frames`. The `note` lists them in order. Use the PNG to check the first frame quickly.
- Video can take many minutes. Keep calling `wait_for_job` with `timeout_seconds` 300 until it finishes.
- Video does not support `mask_image`, `controls` or `batch_count`.
- `generate_video` accepts `loras` (for example a speed-up LoRA), and `shift_for_audio` for audio-capable models.

### Use the user's own Draw Things configuration
If the user gives you settings from Draw Things ("Copy Configuration" JSON, or a file with it), pass it as `config_json` (a JSON string or object) instead of copying values one by one.
```
generate_video { prompt, num_frames, config_json: "<the JSON>" }
```
- It carries everything the tool has no argument for: LoRAs and their modes, tiled decoding, TeaCache, `shiftForAudio` and more. Numeric samplers (`"sampler": 16`) work as written.
- Arguments you pass explicitly override it. Change only what the request needs: the `seed` (omit it for a new random one), `num_frames`, the prompt. Leave the rest alone, even if it looks odd.
- The user's configuration is deliberate for that model. Do not "correct" its sampler, steps, guidance or shift, and do not drop its LoRAs.
- If the call is rejected for the frame count, tell the user the limit is set in the app's Guardrails.

### Chain clips (continue a story)
```
generate_video { prompt: "scene 1", model, num_frames, save_last_frame: true }
generate_video { prompt: "what happens next", model, num_frames, init_image: "<last_frame.png from clip 1>" }
```
- Ask for `save_last_frame` on every clip you may continue. It is the exact picture, with no video compression.
- For a clip that already exists, call `extract_frames { video: "/abs/clip.mp4", frames: "last" }`.
- Keep the same model, size and seed settings so the clips match. Each clip is a separate file; there is no tool to join them, so tell the user the order.

### Work with frames
```
extract_frames { video, frames: "first" | "last" | "all" | 12 | [0, 40, 80] }
```
- Frame numbers start at 0. A list can hold up to 64 numbers. `"all"` writes a folder of PNGs (no audio) that you can pass to `process_video` as `source`.
- Files go to the output folder and the result lists the paths.

### Smooth motion, slow motion, upscale a video
```
process_video { source: "/abs/clip.mp4", interpolate_factor: 2 }          // smoother, same length
process_video { source: "/abs/clip.mp4", interpolate_factor: 2, frame_rate: 24 }   // slow motion (see below)
process_video { source: "/abs/clip.mp4", upscale_factor: 2 }              // bigger frames
```
- It returns a job. Use `wait_for_job` (long timeout) and read `outputs` for the new .mp4. The original is kept.
- `interpolate_factor` (2, 3 or 4) adds frames between the existing ones. The clip keeps its length and audio, and the frame rate rises by the factor. If you also pass `frame_rate`, the speed changes: for slow motion, pick a rate lower than source rate times the factor.
- `frame_rate` on its own speeds up or slows down the clip. Audio is dropped when the speed changes (the note says so). Pass `keep_audio: false` to drop it yourself.
- `upscale_factor` (2, 3 or 4) makes each side larger. Apple's ML upscaler runs only on newer macOS and for frames up to 1920x1080; otherwise a plain resize happens. **Read the job `note`**: it names the engine used. Do not promise added detail when it says `coreImageLanczos`.
- Both run on the user's Mac and are slow on long or large clips. If the call says it needs too much memory, lower the factor, or tell the user.
- Do one thing at a time if unsure: first interpolate, check the result, then upscale the output.
- To start from frames, pass the folder from `extract_frames` or `save_frames` as `source`. With no options, it rebuilds the .mp4.

## When something goes wrong

| Message or symptom | What to do |
|---|---|
| Not connected / connection error | Tell the user to check the Draw Things server and the app's Connection tab. |
| "No output folder is configured" | Ask the user to choose an output folder in the app's Folders tab. |
| "outside the folders the user has granted" | Ask the user to add the folder under Input Folders. |
| "exceeds the limits set by the user" | Lower size, steps or batch count. Do not argue with the limit. |
| "Unknown sampler" | Use one of the sampler names the message lists. |
| "The server returned no image" | The sampler, steps, guidance or shift do not suit the model. Call `get_model_recommendations`, use its values, or ask the user for the model's recommended settings. Do not retry the same settings. |
| "is not installed" or "different model family" | Call the matching list tool with `compatible_with` and choose from the result. |
| List is empty, or the model/LoRA you were asked to use is not in it | The server's list may be incomplete or "Enable Model Browsing" may be off. Try once without `query`. If the user gave the exact file name, use it as written. If they only described it, ask for the file name. Do not substitute another model or guess its settings. |
| "needs about N MB of memory" | Use a smaller `upscale_factor` or `interpolate_factor`, or process a shorter clip. Do not retry the same request. |
| "has no video track" / "neither a video file nor a frames folder" | `source` or `video` must be an .mp4 (or, for `process_video`, a frames folder). Check the path with `list_jobs` outputs. |
| Job `cancelled` | Someone cancelled it. Ask before starting it again. |

If a tool returns `isError`, read its message: it tells you what to change. Make one corrected attempt, then report to the user instead of looping.

## Reporting back

Tell the user: the file path(s), the model used, the size, and the seed. For video also the frame count and fps from the job `note`. Offer one concrete next step (a variation, an upscale, or a different model) instead of asking an open question.
