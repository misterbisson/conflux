#!/usr/bin/env python3
"""Writes App/Credits.html: the licences of everything compiled into the app.

The Mac app ships compiled code from other projects, and their licences ask
for their notices to travel with it. macOS shows a bundled Credits.html in the
app's About window, so that's where they go.

    tools/notices/make-notices.py --llama DIR [--iroh-metadata JSON ...]

--llama DIR
    llama.cpp's licence files at the build Package.swift pins: LICENSE,
    licenses/LICENSE-jsonhpp, and the vendored vendor/stb/stb_image.h and
    vendor/miniaudio/miniaudio.h, whose licences are at their ends.
    tools/notices/fetch-llama-licenses.sh fetches them.

--iroh-metadata JSON
    `cargo metadata --format-version 1 --filter-platform TARGET` run in
    apple-iroh at the tag Package.swift pins, once per macOS target
    (aarch64-apple-darwin, x86_64-apple-darwin).
    tools/notices/iroh-metadata.sh writes both. Only crates compiled into the
    library count: normal dependencies, not build or dev dependencies, and
    not procedural macros or what only they use. cargo metadata reads the
    crates' manifests and licence files, and compiles and runs nothing.

The starter model the app ships, SmolVLM-256M-Instruct, is Apache 2.0. Its
repositories publish no licence file, only the licence's name, so its notice
is the licence's text as Apache publishes it, Apache-2.0.txt here, and names
the revision tools/ci/fetch-starter-model.sh pins.

Each crate's own licence files are copied as published. A crate that ships
none is given the MIT licence, which every such crate offers, with its
authors as the copyright holders. Identical texts are printed once.

Run it again whenever Package.swift moves llama.cpp or apple-iroh, or
fetch-starter-model.sh moves the starter model. tools/ci/check-app.sh fails
when Credits.html names other versions than those pins.
"""

import argparse
import html
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LICENCE_FILE = re.compile(r"(?i)^(licen[cs]e|copying|notice|copyright|unlicense)")

MIT = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


def pinned(name):
    """The version Package.swift pins for a binary target."""
    text = open(os.path.join(ROOT, "Package.swift"), encoding="utf-8").read()
    if name == "llama":
        match = re.search(r"llama\.cpp/releases/download/(b\d+)/", text)
    else:
        match = re.search(r"apple-iroh/releases/download/(v[\d.]+)/", text)
    return match.group(1) if match else None


def tail_from(text, marker):
    index = text.rfind(marker)
    if index < 0:
        sys.exit(f"make-notices: no licence block starting {marker!r}")
    block = text[index:]
    # The block sits in a closing comment.
    return block.split("*/")[0].rstrip() + "\n"


def llama_section(directory):
    def read(name):
        with open(os.path.join(directory, name), encoding="utf-8", errors="replace") as handle:
            return handle.read()

    return [
        ("llama.cpp and ggml", "https://github.com/ggml-org/llama.cpp", "MIT", [read("LICENSE")]),
        ("stb_image, vendored by llama.cpp", "https://github.com/nothings/stb", "MIT or public domain",
         [tail_from(read("stb_image.h"), "This software is available under 2 licenses")]),
        ("miniaudio, vendored by llama.cpp", "https://github.com/mackron/miniaudio", "MIT-0 or public domain",
         [tail_from(read("miniaudio.h"), "This software is available as a choice of the following licenses")]),
        ("JSON for Modern C++, used by llama.cpp", "https://github.com/nlohmann/json", "MIT",
         [read("LICENSE-jsonhpp")]),
    ]


def shipped_crates(paths):
    crates = {}
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            metadata = json.load(handle)
        packages = {package["id"]: package for package in metadata["packages"]}
        nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
        root = metadata["resolve"]["root"]

        def proc_macro(package):
            return any("proc-macro" in target["kind"] for target in package["targets"])

        seen, stack = set(), [root]
        while stack:
            current = stack.pop()
            if current in seen:
                continue
            seen.add(current)
            for dep in nodes[current]["deps"]:
                normal = any(kind["kind"] is None for kind in dep["dep_kinds"])
                if normal and not proc_macro(packages[dep["pkg"]]):
                    stack.append(dep["pkg"])
        for package_id in seen:
            if package_id != root:
                package = packages[package_id]
                crates[(package["name"], package["version"])] = package
    return [crates[key] for key in sorted(crates)]


def crate_texts(package):
    directory = os.path.dirname(package["manifest_path"])
    names = sorted(name for name in os.listdir(directory) if LICENCE_FILE.match(name)
                   and os.path.isfile(os.path.join(directory, name)))
    if package.get("license_file"):
        names.append(package["license_file"])
    texts = []
    for name in dict.fromkeys(names):
        with open(os.path.join(directory, name), encoding="utf-8", errors="replace") as handle:
            texts.append(handle.read())
    if not texts:
        expression = package.get("license") or ""
        if "MIT" not in expression.replace("MIT-0", ""):
            sys.exit(f"make-notices: {package['name']} {package['version']} ships no licence file and "
                     f"doesn't offer MIT ({expression!r}); add its text by hand")
        authors = ", ".join(re.sub(r"\s*<[^>]*>", "", author) for author in package.get("authors") or [])
        holder = authors or f"the {package['name']} authors"
        texts.append(f"MIT License (chosen from {expression})\n\nCopyright (c) {holder}\n\n{MIT}")
    return texts


def starter_model():
    """The starter model's repository and revision, from the script that fetches it."""
    with open(os.path.join(ROOT, "tools", "ci", "fetch-starter-model.sh"), encoding="utf-8") as handle:
        script = handle.read()
    repository = re.search(r"^repository=(\S+)$", script, re.M)
    revision = re.search(r"^revision=([0-9a-f]{40})$", script, re.M)
    if not repository or not revision:
        sys.exit("make-notices: no repository= and revision= in tools/ci/fetch-starter-model.sh")
    return repository.group(1), revision.group(1)


def starter_html(ref):
    """The starter model's notice. `ref` numbers its licence text."""
    repository, revision = starter_model()
    with open(os.path.join(ROOT, "tools", "notices", "Apache-2.0.txt"), encoding="utf-8") as handle:
        number = ref(handle.read())
    base = "https://huggingface.co/HuggingFaceTB/SmolVLM-256M-Instruct"
    return (f'<h2>SmolVLM-256M-Instruct, the starter model</h2><p>By Hugging Face, <a href="{base}">{base}</a>'
            f' · Apache-2.0 · <a href="#t{number}">licence {number}</a>. Included as GGUF from '
            f'<a href="https://huggingface.co/{html.escape(repository)}">{html.escape(repository)}</a> at revision '
            f'<span id="starter-revision">{html.escape(revision)}</span>.</p>')


def render(sections, iroh_version, crates):
    llama = pinned("llama")
    texts, order = {}, []

    def ref(text):
        key = text.strip()
        if key not in texts:
            texts[key] = len(texts) + 1
            order.append(key)
        return texts[key]

    out = [
        "<!DOCTYPE html>",
        '<html><head><meta charset="utf-8"><title>Acknowledgements</title>',
        "<style>body{font:11px -apple-system,sans-serif}h2{font-size:12px;margin:1.4em 0 .3em}"
        "pre{font:10px ui-monospace,monospace;white-space:pre-wrap}li{margin:.15em 0}</style></head><body>",
        "<!-- Written by tools/notices/make-notices.py. Don't edit by hand. -->",
        f'<p id="versions">llama.cpp {html.escape(llama or "?")}'
        + (f" · apple-iroh {html.escape(iroh_version)}" if iroh_version else "") + "</p>",
        "<p>conflux is MIT licensed. It includes software from the projects below, "
        "under their own licences.</p>",
    ]
    for title, url, licence, bodies in sections:
        numbers = [ref(body) for body in bodies]
        out.append(f'<h2>{html.escape(title)}</h2><p><a href="{url}">{url}</a> · {html.escape(licence)} · '
                   + ", ".join(f'<a href="#t{n}">licence {n}</a>' for n in numbers) + "</p>")
    if crates:
        out.append(f"<h2>apple-iroh {html.escape(iroh_version)} and the Rust crates compiled into it</h2>")
        out.append('<p><a href="https://github.com/misterbisson/apple-iroh">'
                   "https://github.com/misterbisson/apple-iroh</a>, MIT, packages "
                   '<a href="https://github.com/n0-computer/iroh">iroh</a> and these crates:</p><ul>')
        for package in crates:
            numbers = [ref(text) for text in crate_texts(package)]
            repository = package.get("repository") or ""
            link = f' <a href="{html.escape(repository)}">source</a>' if repository else ""
            out.append(f"<li>{html.escape(package['name'])} {html.escape(package['version'])} · "
                       f"{html.escape(package.get('license') or 'see licence')} · "
                       + ", ".join(f'<a href="#t{n}">licence {n}</a>' for n in numbers) + link + "</li>")
        out.append("</ul>")
    out.append(starter_html(ref))
    out.append("<h2>Licences</h2>")
    for number, text in enumerate(order, 1):
        out.append(f'<h3 id="t{number}">Licence {number}</h3><pre>{html.escape(text)}</pre>')
    out.append("</body></html>")
    return "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--llama", required=True)
    parser.add_argument("--iroh-metadata", action="append", default=[])
    parser.add_argument("--out", default=os.path.join(ROOT, "App", "Credits.html"))
    args = parser.parse_args()

    iroh_version = pinned("iroh")
    if bool(iroh_version) != bool(args.iroh_metadata):
        sys.exit("make-notices: Package.swift " + ("pins apple-iroh; pass --iroh-metadata"
                                                   if iroh_version else "doesn't pin apple-iroh; drop --iroh-metadata"))
    crates = shipped_crates(args.iroh_metadata) if args.iroh_metadata else []
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(render(llama_section(args.llama), iroh_version, crates))
    print(f"wrote {os.path.relpath(args.out, ROOT)}: llama.cpp {pinned('llama')}"
          + (f", apple-iroh {iroh_version} with {len(crates)} crates" if crates else ""))


if __name__ == "__main__":
    main()
