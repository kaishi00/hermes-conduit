#!/usr/bin/env python3
"""Builds Conduit/Resources/ProviderLogos.xcassets from lobe-icons' SVGs.

    curl -sO https://registry.npmjs.org/@lobehub/icons-static-svg/-/icons-static-svg-1.102.0.tgz
    tar xzf icons-static-svg-1.102.0.tgz
    pip install cairosvg
    python3 scripts/make-provider-logos.py package/icons Conduit/Resources/ProviderLogos.xcassets

Each logo becomes a vector PDF. A single-colour logo is a template image,
so it takes the text colour; a "-color" one keeps its brand colours. A
logo added here also needs its Hermes slugs in ProviderLogo.bySlug
(Conduit/Views/Components/ProviderLogoView.swift). Pick a single-colour
logo when the coloured one has black parts, which vanish in Dark Mode.
"""
import json, os, re, shutil, sys, tempfile
import cairosvg

SRC = sys.argv[1]; FINAL = sys.argv[2].rstrip("/")
# asset name -> lobe-icons file (without .svg)
LOGOS = {
 "anthropic":"anthropic", "arcee":"arcee-color", "bedrock":"bedrock-color", "azure":"azureai-color",
 "cerebras":"cerebras-color", "chutes":"chutes", "cohere":"cohere", "commandcode":"commandcode",
 "copilot":"githubcopilot", "deepinfra":"deepinfra-color", "deepseek":"deepseek-color", "fireworks":"fireworks-color",
 "gemini":"gemini-color", "gmi":"gmicloud", "groq":"groq", "huggingface":"huggingface-color", "kilocode":"kilocode",
 "kimi":"kimi", "lmstudio":"lmstudio", "meta":"meta-color", "minimax":"minimax-color", "mistral":"mistral-color",
 "nebius":"nebius", "nous":"nousresearch", "novita":"novita-color", "nvidia":"nvidia-color", "ollama":"ollama",
 "openai":"openai", "opencode":"opencode", "openrouter":"openrouter", "perplexity":"perplexity-color",
 "qwen":"qwen-color", "sambanova":"sambanova-color", "siliconflow":"siliconcloud-color", "stepfun":"stepfun-color",
 "tencent":"tencent-color", "together":"together-color", "upstage":"upstage-color", "vercel":"vercel",
 "vertex":"vertexai-color", "vllm":"vllm-color", "xai":"xai", "zai":"zai",
}
# Built in a temporary folder outside the app's sources and swapped in only
# once every logo converted, so a wrong source folder leaves the catalog as
# it was and nothing behind.
BUILD = tempfile.TemporaryDirectory()
OUT = os.path.join(BUILD.name, "ProviderLogos.xcassets")
os.makedirs(OUT)
json.dump({"info":{"author":"xcode","version":1}}, open(f"{OUT}/Contents.json","w"), indent=2)
for name, src in sorted(LOGOS.items()):
    svg = open(f"{SRC}/{src}.svg").read()
    svg = svg.replace('height="1em"', 'height="24"').replace('width="1em"', 'width="24"')
    svg = re.sub(r'<title>.*?</title>', '', svg)
    template = not src.endswith("-color")
    d = f"{OUT}/provider-{name}.imageset"; os.makedirs(d, exist_ok=True)
    cairosvg.svg2pdf(bytestring=svg.encode(), write_to=f"{d}/provider-{name}.pdf")
    props = {"preserves-vector-representation": True}
    if template: props["template-rendering-intent"] = "template"
    json.dump({"images":[{"filename":f"provider-{name}.pdf","idiom":"universal"}],
               "info":{"author":"xcode","version":1},"properties":props}, open(f"{d}/Contents.json","w"), indent=2)
shutil.rmtree(FINAL, ignore_errors=True)
shutil.move(OUT, FINAL)
BUILD.cleanup()
print(len(LOGOS))
