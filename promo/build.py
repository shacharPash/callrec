"""Inline the real CallRec assets into a single self-contained index.html."""
import base64, pathlib
root = pathlib.Path(__file__).parent
uri = lambda f: 'data:image/png;base64,' + base64.b64encode((root / 'assets' / f).read_bytes()).decode()
html = (root / 'src' / 'index.template.html').read_text(encoding='utf-8')
for token, f in {'{{APP_ICON}}': 'app-icon.png', '{{MB_IDLE}}': 'menubar-icon.png', '{{MB_REC}}': 'menubar-icon-recording.png'}.items():
    assert token in html, token
    html = html.replace(token, uri(f))
(root / 'index.html').write_text(html, encoding='utf-8')
print('index.html', len(html.encode()) // 1024, 'KB')
