#!/usr/bin/env python3
"""Verify the public demo and record real browser interactions for a captioned MP4.

Requires Python Playwright, Chromium, ffmpeg, and ffprobe. No product credentials.
"""
import argparse
import functools
import json
import shutil
import subprocess
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        # Exercise the production policy; localhost does not need HTTPS upgrades.
        config = json.loads((ROOT / 'vercel.json').read_text())
        policy = config['headers'][0]['headers'][0]['value']
        self.send_header('Content-Security-Policy', policy.replace('; upgrade-insecure-requests', ''))
        super().end_headers()

    def log_message(self, *_):
        pass

    def copyfile(self, source, outputfile):
        try:
            super().copyfile(source, outputfile)
        except (BrokenPipeError, ConnectionResetError):
            # Browsers intentionally stop metadata-only video downloads.
            pass


def fonts(context, directory):
    if not directory:
        return
    css = "@font-face{font-family:'DM Sans';font-style:normal;font-weight:100 900;src:url(https://fonts.gstatic.com/fizz-demo-dm.ttf)}@font-face{font-family:'Space Grotesk';font-style:normal;font-weight:300 700;src:url(https://fonts.gstatic.com/fizz-demo-space.ttf)}"
    context.route('https://fonts.googleapis.com/**', lambda route: route.fulfill(status=200, content_type='text/css', body=css))
    def serve_font(route):
        filename = 'DMSans.ttf' if route.request.url.endswith('-dm.ttf') else 'SpaceGrotesk.ttf'
        route.fulfill(status=200, content_type='font/ttf', body=(directory / filename).read_bytes())
    context.route('https://fonts.gstatic.com/fizz-demo-*.ttf', serve_font)


def verify(browser, base, output, font_dir):
    results = []
    for name, viewport, mobile in [('desktop', {'width': 1440, 'height': 1000}, False), ('mobile', {'width': 390, 'height': 844}, True)]:
        context = browser.new_context(viewport=viewport, is_mobile=mobile, has_touch=mobile)
        fonts(context, font_dir)
        page = context.new_page()
        errors, api_requests, failed_assets = [], [], []
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.on('request', lambda request: api_requests.append(request.url) if '/api/' in request.url else None)
        page.on('response', lambda response: failed_assets.append((response.url, response.status)) if response.url.startswith(base) and response.status >= 400 else None)
        page.goto(base, wait_until='networkidle')
        page.locator('.hero-secondary').click()
        page.wait_for_url('**/demo.html')
        page.wait_for_selector('#demo-sensors .live-card')
        assert page.locator('#demo-sensors .live-card:visible').count() == 6
        assert 'simulated' in page.locator('.demo-banner').inner_text()
        page.locator('#pause-demo').click()
        page.locator('[data-filter="storage"]').click()
        assert page.locator('#demo-sensors .live-card:visible').count() == 3
        page.locator('[data-filter="greenhouse"]').click()
        assert page.locator('#demo-sensors .live-card:visible').count() == 2
        page.locator('[data-filter="all"]').click()
        page.locator('#sensor-cold-room').click()
        assert page.locator('#sensor-dialog').is_visible()
        assert page.locator('#detail-chart svg').count() == 1
        page.keyboard.press('Escape')
        assert page.locator('#sensor-cold-room').evaluate('e => e === document.activeElement')
        cold_reading = page.locator('#sensor-cold-room .live-value').inner_text()
        page.locator('[data-prompt^="Give me"]').click()
        page.wait_for_selector('#demo-chat .agent:not(.thinking):nth-last-child(1)')
        assert cold_reading in page.locator('#demo-chat .agent').last.inner_text()
        page.locator('#alert-builder summary').click()
        page.locator('#rule-threshold').fill('7')
        page.locator('#demo-alert-form button').click()
        assert page.locator('#enabled-count').inner_text() == '3'
        page.locator('#demo-alert-form button').click()
        assert page.locator('#enabled-count').inner_text() == '3', 'Duplicate alert'
        page.locator('#simulate-spike').click()
        assert page.locator('#workspace-health').inner_text() == 'Needs a look'
        assert page.locator('#sensor-cold-room .live-value').inner_text() == '9.2 °C'
        assert page.locator('#demo-events .demo-event').count() == 2
        page.locator('#demo-events button').first.click()
        assert page.locator('#call-dialog').is_visible()
        assert 'No phone number is used' in page.locator('#call-dialog').inner_text()
        assert 'above 7 °C' in page.locator('#call-transcript').inner_text()
        page.keyboard.press('Escape')
        page.locator('#simulate-spike').click()
        assert page.locator('#workspace-health').inner_text() == 'All clear'
        page.locator('[data-rule-action="toggle"]').first.click()
        assert page.locator('#enabled-count').inner_text() == '2'
        page.locator('[data-rule-action="delete"]').first.click()
        assert page.locator('#demo-rules > li').count() == 2
        page.locator('#demo-chat-input').fill('Alert me if the cold room goes above 6 °C')
        page.locator('#demo-chat-form button').click()
        page.wait_for_selector('#demo-chat .agent:not(.thinking):nth-last-child(1)')
        assert 'Demo alert created' in page.locator('#demo-chat .agent').last.inner_text()
        page.locator('#demo-chat-input').fill('<img src=x onerror=alert(1)>')
        page.locator('#demo-chat-form button').click()
        page.wait_for_selector('#demo-chat .agent:not(.thinking):nth-last-child(1)')
        assert page.locator('#demo-chat img').count() == 0
        page.locator('[data-prompt^="Give me"]').click()
        page.locator('#reset-demo').click()
        page.wait_for_timeout(800)
        assert page.locator('#demo-chat .chat-message').count() == 1
        assert page.locator('#enabled-count').inner_text() == '2'
        assert page.locator('#demo-events .demo-event').count() == 0
        assert page.locator('#demo-sensors .live-card:visible').count() == 6
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), 'Horizontal overflow'
        page.evaluate('window.scrollTo(0, 0)')
        page.screenshot(path=str(output / f'demo-{name}.png'), full_page=True)
        assert not errors, errors
        assert not api_requests, api_requests
        assert not failed_assets, failed_assets
        # Reloading always starts a fresh sample workspace.
        page.reload(wait_until='networkidle')
        assert page.locator('#enabled-count').inner_text() == '2'
        result = {'viewport': name, 'filters': 'PASS', 'sensor_detail_and_focus': 'PASS', 'chat_and_chat_alert': 'PASS', 'create_trigger_preview_resolve': 'PASS', 'pause_delete_reset': 'PASS', 'overflow': 'PASS', 'page_errors': errors, 'product_api_requests': api_requests}
        print(json.dumps(result), flush=True)
        results.append(result)
        context.close()
    (output / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')


def record(browser, base, raw, font_dir):
    context = browser.new_context(viewport={'width': 1440, 'height': 900}, record_video_dir=str(raw), record_video_size={'width': 1440, 'height': 900})
    fonts(context, font_dir)
    created = time.monotonic()
    page = context.new_page()
    page.goto(base + '/demo.html', wait_until='networkidle')
    page.evaluate('document.fonts.ready')
    page.add_style_tag(content='html{scroll-behavior:smooth}.capture-pointer{position:fixed;z-index:2147483647;width:17px;height:17px;border:2px solid white;background:#178da9;border-radius:50%;box-shadow:0 0 0 5px #159fbc30,0 2px 6px #163c4650;pointer-events:none;left:-40px;top:-40px;transform:translate(-50%,-50%)}')
    page.evaluate("""() => {const dot=document.createElement('div');dot.className='capture-pointer';document.body.append(dot);document.addEventListener('mousemove',e=>{dot.style.left=e.clientX+'px';dot.style.top=e.clientY+'px';});}""")
    started = time.monotonic()
    scenes = []

    def scene(title, subtitle):
        scenes.append({'start': time.monotonic() - started, 'title': title, 'subtitle': subtitle})
        print('Recording: ' + title, flush=True)

    def hold(seconds):
        page.wait_for_timeout(int(seconds * 1000))

    def click(selector):
        locator = page.locator(selector).first
        locator.scroll_into_view_if_needed()
        box = locator.bounding_box()
        page.mouse.move(box['x'] + box['width'] / 2, box['y'] + box['height'] / 2, steps=16)
        hold(.25)
        locator.click()

    scene('Meet your physical world.', 'A populated workspace. No account or hardware needed.')
    hold(5)
    scene('Every sensor, in context.', 'Explore six sample sensors across three spaces.')
    click('[data-filter="storage"]')
    hold(3)
    scene('See the readings behind a signal.', 'Open a sensor to explore its simulated history.')
    click('#sensor-cold-room')
    hold(5)
    click('#sensor-dialog [data-close-dialog]')
    click('[data-filter="all"]')
    scene('Ask a question. Get context.', 'Fizz replies using the sample readings on screen.')
    click('[data-prompt^="Give me"]')
    hold(4)
    click('[data-prompt^="How is"]')
    hold(4)
    scene('Set a threshold in seconds.', 'Watch the cold room above 7 °C, with a phone call preview.')
    click('#alert-builder summary')
    page.locator('#rule-threshold').fill('7')
    hold(2)
    click('#demo-alert-form button')
    hold(4)
    scene('Catch the change as it happens.', 'A sample spike crosses the limit and triggers the alert.')
    click('#simulate-spike')
    hold(3)
    page.locator('#alerts').scroll_into_view_if_needed()
    hold(4)
    scene('Reach the right person.', 'Preview the phone alert. No real call is placed in this demo.')
    click('#demo-events button')
    hold(7)
    click('#call-dialog > [data-close-dialog].primary')
    scene('Back inside the limit.', 'Resolve the spike and watch the workspace return to all clear.')
    click('#simulate-spike')
    hold(5)
    scene('Your world has a sidekick.', 'Try it yourself at fizzlayer.com/demo.html')
    click('#reset-demo')
    page.evaluate('window.scrollTo({top:0,behavior:"smooth"})')
    hold(5)
    duration = time.monotonic() - started
    video = page.video
    context.close()
    return Path(video.path()), scenes, started - created, duration


def timestamp(seconds):
    ms = round(seconds * 1000)
    return f'{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02}.{ms % 1000:03}'


def render(source, scenes, offset, duration, output, font_dir):
    destination = output / 'fizzlayer-dashboard-walkthrough.mp4'
    font = str(font_dir / 'DMSans.ttf') if font_dir else subprocess.check_output(['fc-match', '-f', '%{file}', 'DejaVu Sans'], text=True)
    display = str(font_dir / 'SpaceGrotesk.ttf') if font_dir else font
    filters = [
        '[0:v]fps=30,scale=1440:900,pad=1600:1200:80:112:color=0x0b1722',
        f"drawtext=fontfile='{display}':text='Fizzlayer.':fontsize=40:fontcolor=0xf1f8fc:x=80:y=35",
        f"drawtext=fontfile='{font}':text='INTERACTIVE DEMO  /  SAMPLE DATA':fontsize=17:fontcolor=0x9bc6d5:x=w-tw-80:y=52",
    ]
    vtt = ['WEBVTT', '']
    for index, scene in enumerate(scenes):
        end = scenes[index + 1]['start'] if index + 1 < len(scenes) else duration
        for field, y, size, color in [('title', 1047, 39, '0xf2f9fc'), ('subtitle', 1110, 26, '0xa9c6d5')]:
            textfile = output / f'.caption-{index}-{field}.txt'
            textfile.write_text(scene[field])
            filters.append(f"drawtext=fontfile='{display if field == 'title' else font}':textfile='{textfile}':fontsize={size}:fontcolor={color}:x=80:y={y}:enable='gte(t,{scene['start']:.3f})*lt(t,{end:.3f})'")
        vtt.extend([f"{timestamp(scene['start'])} --> {timestamp(end)}", scene['title'], scene['subtitle'], ''])
    filters[-1] += '[out]'
    filterfile = output / '.walkthrough-filter.txt'
    filterfile.write_text(','.join(filters))
    subprocess.run(['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-ss', str(offset), '-i', str(source), '-t', str(duration), '-filter_complex', filterfile.read_text(), '-map', '[out]', '-an', '-c:v', 'libx264', '-preset', 'medium', '-crf', '19', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(destination)], check=True)
    (output / 'fizzlayer-dashboard-walkthrough.vtt').write_text('\n'.join(vtt))
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-ss', '3', '-i', str(destination), '-frames:v', '1', '-q:v', '2', str(output / 'fizzlayer-dashboard-walkthrough-poster.jpg')], check=True)
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration,size:stream=codec_name,width,height,pix_fmt,avg_frame_rate', '-of', 'json', str(destination)], text=True))
    stream = probe['streams'][0]
    assert (stream['width'], stream['height'], stream['codec_name'], stream['pix_fmt']) == (1600, 1200, 'h264', 'yuv420p'), probe
    subprocess.run(['ffmpeg', '-v', 'error', '-i', str(destination), '-f', 'null', '-'], check=True)
    (output / 'video-metadata.json').write_text(json.dumps(probe, indent=2) + '\n')
    for path in output.glob('.caption-*.txt'):
        path.unlink()
    filterfile.unlink()
    print(json.dumps({'video': str(destination), 'metadata': probe}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'output' / 'demo')
    parser.add_argument('--brand-font-dir', type=Path, help='Optional DMSans.ttf and SpaceGrotesk.ttf for offline capture.')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--verify-only', action='store_true')
    mode.add_argument('--record-only', action='store_true', help='Capture without repeating completed verification.')
    mode.add_argument('--render-only', action='store_true', help='Re-export the saved raw recording and scene timings.')
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    for binary in ['chromium', 'ffmpeg', 'ffprobe']:
        if not shutil.which(binary):
            parser.error(f'Missing required executable: {binary}')
    if args.render_only:
        saved = json.loads((args.output / 'walkthrough-scenes.json').read_text())
        render(args.output / saved['source'], saved['scenes'], saved['offset'], saved['duration'], args.output, args.brand_font_dir)
        return
    server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(ROOT / 'public')))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    print('Verifying landing page → public sample workspace → simulated interactions.', flush=True)
    try:
        with tempfile.TemporaryDirectory(prefix='fizzlayer-capture-') as directory, sync_playwright() as p:
            browser = p.chromium.launch(executable_path=shutil.which('chromium'), headless=True, args=['--no-sandbox', '--disable-dev-shm-usage'])
            try:
                if not args.record_only:
                    verify(browser, base, args.output, args.brand_font_dir)
                if not args.verify_only:
                    source, scenes, offset, duration = record(browser, base, Path(directory), args.brand_font_dir)
                    saved_source = args.output / 'walkthrough-source.webm'
                    shutil.copyfile(source, saved_source)
                    (args.output / 'walkthrough-scenes.json').write_text(json.dumps({'source': saved_source.name, 'offset': offset, 'duration': duration, 'scenes': scenes}, indent=2) + '\n')
                    render(saved_source, scenes, offset, duration, args.output, args.brand_font_dir)
            finally:
                browser.close()
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
