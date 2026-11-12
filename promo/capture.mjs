// Usage: node capture.mjs stills 1.5 5.9 ...   -> frames/still-<t>.png
//        node capture.mjs video                -> promo.mp4 (1920x1080, 30fps, H.264)
import puppeteer from 'puppeteer-core';
import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const [mode, ...args] = process.argv.slice(2);
const FPS = 30;

const browser = await puppeteer.launch({ executablePath: CHROME, headless: true,
  userDataDir: process.env.TMPDIR + '/callrec-chrome', args: ['--disable-crash-reporter', '--disable-breakpad', '--disable-crashpad-for-testing', '--no-sandbox', '--disable-features=ProcessSingleton', '--hide-scrollbars', '--force-color-profile=srgb', '--font-render-hinting=none'] });
const page = await browser.newPage();
await page.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 });
await page.goto(pathToFileURL('index.html').href + '?capture=1', { waitUntil: 'networkidle0' });
await page.waitForFunction('window.__ready === true');
await page.evaluate(() => document.fonts.ready);
const shot = async t => { await page.evaluate(t => render(t), t); return page.screenshot({ type: 'png' }); };

if (mode === 'stills') {
  mkdirSync('frames', { recursive: true });
  const { writeFileSync } = await import('node:fs');
  for (const a of args) writeFileSync(`frames/still-${a}.png`, await shot(parseFloat(a)));
} else if (mode === 'poster') {
  const { writeFileSync } = await import('node:fs');
  writeFileSync('poster.png', await shot(parseFloat(args[0])));
} else {
  const DUR = await page.evaluate(() => window.DUR);
  const n = Math.round(DUR * FPS);
  const ff = spawn('ffmpeg', ['-y', '-f', 'image2pipe', '-framerate', String(FPS), '-c:v', 'png', '-i', '-',
    '-c:v', 'libx264', '-preset', 'slow', '-crf', '20', '-tune', 'animation', '-pix_fmt', 'yuv420p',
    '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
    '-movflags', '+faststart', 'promo.mp4'], { stdio: ['pipe', 'inherit', 'inherit'] });
  for (let i = 0; i < n; i++) {
    const buf = await shot(i / FPS);
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 75 === 0) console.log(`frame ${i}/${n}`);
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
}
await browser.close();
