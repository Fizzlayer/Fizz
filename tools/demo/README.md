# Public dashboard demo and Twitter walkthrough

`public/demo.html` is a self-contained sample workspace linked from the landing page. It uses the product's shared styles and sensor icons. `public/demo.js` supplies six evolving sample sensors, simulated history, local Fizz replies, editable threshold rules, and a phone alert preview. It does not load authentication code or make product API requests. Resetting or reloading restores the sample workspace.

The capture runner verifies the complete interaction on desktop and mobile, then records actual Chromium interactions with Playwright. FFmpeg adds explanatory text above and below the screen capture and exports an H.264 MP4 with a 4:3 frame at 1600×1200, 30 fps, and fast-start metadata. The explanation is visible with sound off. It also saves captions, a poster, scene timings, screenshots, and verification results.

Requirements: Python with `playwright`, the Chromium executable, FFmpeg (with libx264 and drawtext), FFprobe, and fontconfig. Playwright also needs its recording FFmpeg binary (`playwright install ffmpeg`).

```sh
python tools/demo/walkthrough.py
python tools/demo/walkthrough.py --verify-only
python tools/demo/walkthrough.py --record-only
python tools/demo/walkthrough.py --render-only
```

Optional: supply `--brand-font-dir /path/to/fonts` containing `DMSans.ttf` and `SpaceGrotesk.ttf` to use the exact brand fonts without contacting Google Fonts. The local verification server uses the production Content Security Policy. Verification asserts that the demo sends no product API requests.

Deliverables default to `output/demo/`. The raw screen capture and scene timings are saved before export so `--render-only` can retry an export without recording again. The MP4 is a separate social asset; recording it does not replace the existing landing-page product video.
