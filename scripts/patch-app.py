#!/usr/bin/env python3
import os
import re
import sys
from pathlib import Path

USAGE = "usage: patch-app.py <unpacked-app-dir> <patch-dir>"

NAVBAR_CLASS_PREFIX = "_navbar_"
NAVBAR_HEIGHT_FALLBACK_PX = 50
NAVBAR_HEIGHT_PLACEHOLDER = "__TITLEBAR_HEIGHT__"
RELEASE_REPO_PLACEHOLDER = "__RELEASE_REPO__"
DEFAULT_RELEASE_REPO = "SilkePilon/input-linux"

PREAMBLE_ALREADY_APPLIED = "enable-transparent-visuals"
EDGE_JS_ALREADY_APPLIED = ".NET runtime not available"
TRAY_ICON_ALREADY_APPLIED = '"win32"?"tray_icon.ico"'
TRAY_GUARD_ALREADY_APPLIED = "|tray_service| failed to create tray"
WINDOW_CHROME_ALREADY_APPLIED = "autoHideMenuBar:!0"
WINDOW_BRIDGE_ALREADY_APPLIED = "inputLinuxWindow"

MAIN_MODULES = (
    "linux-window-controls.js",
    "linux-app-menu.js",
    "linux-udev.js",
    "smoke-test.js",
)

failures = []
notes = []


def note(message):
    notes.append(message)
    print(f"  {message}")


def fail(message):
    failures.append(message)
    print(f"  FAILED: {message}", file=sys.stderr)


def read(path):
    return path.read_text(encoding="utf-8")


def write(path, text):
    path.write_text(text, encoding="utf-8")


def substitute(text, pattern, replacement, description, expected=1):
    new_text, count = re.subn(pattern, replacement, text, count=expected)
    if count == 0:
        fail(f"{description}: pattern not found")
        return text
    note(f"{description}: patched ({count} site{'s' if count != 1 else ''})")
    return new_text


def fragment_marker(tag, stem):
    if tag == "head":
        return f'<meta name="input-linux-patch" content="{stem}">'
    return f'<div hidden data-input-linux-patch="{stem}"></div>'


def prepend_linux_preamble(app_dir, patch_dir):
    target = app_dir / "dist-electron/main/index.js"
    content = read(target)

    if PREAMBLE_ALREADY_APPLIED in content:
        note("linux preamble: already present, skipping")
        return

    preamble = read(patch_dir / "dist-electron/main/index.js").rstrip("\n")
    write(target, preamble + "\n" + content)
    note("linux preamble: prepended to dist-electron/main/index.js")


def release_repo():
    configured = os.environ.get("RELEASE_REPO") or os.environ.get("GITHUB_REPOSITORY")
    return configured if configured and "/" in configured else DEFAULT_RELEASE_REPO


def inject_html_fragments(app_dir, patch_dir, navbar_height):
    target = app_dir / "dist/index.html"
    html = read(target)

    for tag in ("head", "body"):
        fragments = sorted((patch_dir / "dist").glob(f"index-{tag}-*.html"))
        if not fragments:
            fail(f"html fragments: no index-{tag}-*.html found in {patch_dir / 'dist'}")
            continue

        for fragment in fragments:
            marker = fragment_marker(tag, fragment.stem)
            if marker in html:
                note(f"{fragment.name}: already injected, skipping")
                continue
            if f"</{tag}>" not in html:
                fail(f"{fragment.name}: no </{tag}> in dist/index.html")
                continue
            content = (
                read(fragment)
                .replace(NAVBAR_HEIGHT_PLACEHOLDER, str(navbar_height))
                .replace(RELEASE_REPO_PLACEHOLDER, release_repo())
            )
            html = html.replace(
                f"</{tag}>", f"{marker}\n{content}\n  </{tag}>", 1
            )
            note(f"{fragment.name}: injected before </{tag}>")

    write(target, html)


def patch_edge_js(app_dir):
    target = app_dir / "node_modules/electron-edge-js/lib/edge.js"
    if not target.exists():
        fail(f"edge.js: {target} does not exist")
        return

    content = read(target)
    if EDGE_JS_ALREADY_APPLIED in content:
        note("edge.js: already patched, skipping")
        return

    content = substitute(
        content,
        r"edge\s*=\s*require\(edgeNative\);",
        "try {\n"
        "        edge = require(edgeNative);\n"
        "    } catch (e) {\n"
        "        if (process.env.EDGE_DEBUG) {\n"
        "            console.warn('electron-edge-js: .NET runtime not available, "
        "C# interop disabled:', e.message);\n"
        "        }\n"
        "    }",
        "edge.js require(edgeNative) guard",
    )

    content = substitute(
        content,
        r"exports\.func\s*=\s*function\s*\(([^)]*)\)\s*\{",
        lambda m: (
            f"exports.func = function ({m.group(1)}) {{\n"
            "    if (!edge) {\n"
            "        return function (input, callback) {\n"
            "            if (typeof callback === 'function') {\n"
            "                callback(new Error('electron-edge-js: .NET runtime not "
            "available on this system'), null);\n"
            "            }\n"
            "        };\n"
            "    }"
        ),
        "edge.js exports.func guard",
    )

    write(target, content)


def patch_tray(app_dir):
    target = app_dir / "dist-electron/main/index.js"
    content = read(target)

    if TRAY_ICON_ALREADY_APPLIED in content.replace(" ", ""):
        note("tray icon path: already patched, skipping")
    else:
        content = substitute(
            content,
            r'process\.platform\s*===\s*"darwin"\s*\?\s*"tray_icon_Template\.png"'
            r'\s*:\s*"tray_icon\.ico"',
            'process.platform==="win32"?"tray_icon.ico":"tray_icon_Template.png"',
            "tray icon path (use PNG off Windows)",
        )

    if TRAY_GUARD_ALREADY_APPLIED in content:
        note("tray creation guard: already patched, skipping")
    else:
        content = substitute(
            content,
            r"(?<![\w.$])([\w$]+)\.get\(\)\.trayService\.createNewTray\(\)",
            lambda m: (
                "(()=>{try{"
                f"{m.group(1)}.get().trayService.createNewTray()"
                "}catch(trayErr){console.error('|tray_service| failed to create tray: '"
                "+trayErr)}})()"
            ),
            "tray creation guard",
        )

    write(target, content)


def detect_navbar_height(app_dir):
    declared_height = re.compile(
        r"\." + re.escape(NAVBAR_CLASS_PREFIX) + r"[\w-]+\s*\{[^}]*?height:\s*(\d+)px"
    )
    for stylesheet in sorted((app_dir / "dist/assets").glob("*.css")):
        match = declared_height.search(read(stylesheet))
        if match:
            return int(match.group(1))
    note(f"navbar height: not found in stylesheets, using {NAVBAR_HEIGHT_FALLBACK_PX}px")
    return NAVBAR_HEIGHT_FALLBACK_PX


def patch_window_chrome(app_dir):
    target = app_dir / "dist-electron/main/index.js"
    content = read(target)

    if WINDOW_CHROME_ALREADY_APPLIED in content:
        note("window chrome: already patched, skipping")
        return

    content = substitute(
        content,
        r'\.\.\.\s*process\.platform\s*===\s*"darwin"\s*\?\s*\{\s*backgroundColor\s*:'
        r'\s*"#000000"\s*\}\s*:\s*\{\s*\}',
        '...process.platform==="darwin"?{backgroundColor:"#000000"}:{},'
        '...(process.platform==="linux"?{'
        'backgroundColor:"#00000000",'
        "transparent:!0,"
        "resizable:!0,"
        "autoHideMenuBar:!0,"
        "frame:!1"
        '}:{})',
        "window chrome (frameless window on Linux)",
    )

    write(target, content)


def bundled_scripts(app_dir):
    for source in sorted((app_dir / "dist-electron").rglob("*")):
        if source.is_file() and source.suffix in (".js", ".cjs", ".mjs"):
            yield source


def rename_preloads(app_dir):
    preload_dir = app_dir / "dist-electron/preload"
    if not preload_dir.is_dir():
        fail(f"preload rename: {preload_dir} does not exist")
        return

    renamed = []
    for esm_preload in sorted(preload_dir.glob("*.mjs")):
        commonjs_preload = esm_preload.with_suffix(".cjs")
        esm_preload.rename(commonjs_preload)
        renamed.append(commonjs_preload.name)
        note(f"preload rename: {esm_preload.name} -> {commonjs_preload.name}")

    if not renamed and not any(preload_dir.glob("*.cjs")):
        fail("preload rename: no preload scripts found at all")
        return

    for source in bundled_scripts(app_dir):
        content = read(source)
        repointed = re.sub(r"(preload/[\w.-]+)\.mjs", r"\1.cjs", content)
        if repointed != content:
            write(source, repointed)
            note(f"preload rename: updated references in {source.relative_to(app_dir)}")

    stale = [
        str(source.relative_to(app_dir))
        for source in bundled_scripts(app_dir)
        if re.search(r"preload/[\w.-]+\.mjs", read(source))
    ]
    if stale:
        fail(f"preload rename: stale .mjs preload references remain in {', '.join(stale)}")


def expose_window_controls(app_dir, patch_dir):
    target = app_dir / "dist-electron/preload/preload.cjs"
    if not target.exists():
        fail("window controls bridge: dist-electron/preload/preload.cjs does not exist")
        return

    content = read(target)
    if WINDOW_BRIDGE_ALREADY_APPLIED in content:
        note("window controls bridge: already appended, skipping")
        return

    bridge = read(patch_dir / "dist-electron/preload/window-controls-preload.cjs")
    write(target, content.rstrip("\n") + "\n\n" + bridge)
    note("window controls bridge: appended to dist-electron/preload/preload.cjs")


def install_main_modules(app_dir):
    target = app_dir / "dist-electron/main/index.js"
    content = read(target)

    for filename in MAIN_MODULES:
        if not (app_dir / "dist-electron/main" / filename).exists():
            fail(f"{filename}: was not copied into the app")
            continue
        if f'"./{filename}"' in content or f"'./{filename}'" in content:
            note(f"{filename}: already imported, skipping")
            continue
        content += f'\nimport "./{filename}";\n'
        note(f"{filename}: imported from dist-electron/main/index.js")

    write(target, content)


def main(argv):
    if len(argv) != 3:
        print(USAGE, file=sys.stderr)
        return 2

    app_dir = Path(argv[1]).resolve()
    patch_dir = Path(argv[2]).resolve()

    navbar_height = detect_navbar_height(app_dir)
    note(f"app header height: {navbar_height}px")

    for patch in (
        lambda: prepend_linux_preamble(app_dir, patch_dir),
        lambda: inject_html_fragments(app_dir, patch_dir, navbar_height),
        lambda: patch_edge_js(app_dir),
        lambda: patch_tray(app_dir),
        lambda: patch_window_chrome(app_dir),
        lambda: rename_preloads(app_dir),
        lambda: expose_window_controls(app_dir, patch_dir),
        lambda: install_main_modules(app_dir),
    ):
        patch()

    if failures:
        print("", file=sys.stderr)
        print(f"✗ {len(failures)} patch(es) failed to apply:", file=sys.stderr)
        for failure in failures:
            print(f"    - {failure}", file=sys.stderr)
        print(
            "  The upstream bundle likely changed shape. Update scripts/patch-app.py.",
            file=sys.stderr,
        )
        return 1

    print(f"✓ All patches applied ({len(notes)} steps).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
