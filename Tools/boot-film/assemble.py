#!/usr/bin/env python3
"""Injects the shared drawings into every page that uses them, so the film
and the stills draw the same Lan and the same bird:
  character/lan.svg  -> between <!--CHARACTER--> markers
  character/bird.svg -> between <!--BIRD--> markers"""
import pathlib, re
here = pathlib.Path(__file__).parent
drawings = {"CHARACTER": "character/lan.svg", "BIRD": "character/bird.svg"}
for page in [here / "compositions/boot.html", *sorted((here / "stills").glob("*.html"))]:
    text = new = page.read_text()
    for marker, file in drawings.items():
        svg = (here / file).read_text()
        inner = svg[svg.index(">", svg.index("<svg")) + 1:svg.rindex("</svg>")].strip("\n")
        new = re.sub(rf"<!--{marker}-->.*?<!--/{marker}-->",
                     lambda m: f"<!--{marker}-->\n" + inner + f"\n<!--/{marker}-->", new, flags=re.S)
    if new != text:
        page.write_text(new)
        print("updated", page.relative_to(here))
