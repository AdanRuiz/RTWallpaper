"""Regenerates space_rtx_wallpaper.md from docs/space_rtx_wallpaper.template.md plus the real sources.

Usage: python scripts/gen_space_doc.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ("8.1 Shaders HLSL", "src/shaders/Space.hlsl", "hlsl"),
    ("8.2 Escena y cámara (C++)", "src/scenes/SpaceScene.h", "cpp"),
    ("8.3 Astronomía y mecánica orbital (C++)", "src/space/Astro.h", "cpp"),
    ("8.4 Descargas HTTP con ETag (C++)", "src/space/Http.h", "cpp"),
    ("8.5 Decodificación de imágenes y mipmaps (C++)", "src/space/Image.h", "cpp"),
    ("8.6 Interfaz de escena (C++)", "src/scenes/Scene.h", "cpp"),
    ("8.7 Pruebas de escala física (C++)", "tests/astro_test.cpp", "cpp"),
]


def main():
    template = (ROOT / "docs/space_rtx_wallpaper.template.md").read_text(encoding="utf-8")
    parts = []
    for title, path, lang in SOURCES:
        code = (ROOT / path).read_text(encoding="utf-8").replace("\r\n", "\n").rstrip()
        parts.append(f"### {title} (`{path}`)\n\n```{lang}\n{code}\n```\n")
    out = template.replace("<!-- SOURCES -->", "\n".join(parts))
    (ROOT / "space_rtx_wallpaper.md").write_text(out, encoding="utf-8", newline="\n")
    print(f"space_rtx_wallpaper.md: {len(out.splitlines())} lines")


if __name__ == "__main__":
    main()
