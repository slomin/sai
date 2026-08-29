# Sai macOS icon sources

These two 1024×1024 PNGs are the curated source masters for the two
installed identities in ADR 0019. GPT image generation produced the raster
geometry; the checked-in masters, rather than another model run, are the
reproducible input to the shipping assets.

Keeping the curated raster treatment is deliberate: its slight tonal variation
is part of the approved artwork, rather than an attempt at a token-perfect
vector asset. The palette values in the prompts are art direction, not a claim
that every sampled pixel equals those hex values. `prepare` preserves the
masters as approved instead of posterising them or redrawing their geometry.

- `sai-stable-1024.png`: the canonical Sai mark — a near-white ground, an
  ink square and the red square it holds.
- `sai-dev-1024.png`: the same mark with a large diagonal green upper-right
  corner. The changed silhouette remains visible without colour or text.

The stable master was generated with this prompt:

> Create the canonical Sai macOS app icon from its existing modernist mark:
> a centered deep-ink square holding one centered red square, on Sai's
> near-white ground. Use only `#FBFAF8`, `#121110` and `#E5342A`; keep the
> geometry crisp, simple and symmetric, with no text, badge or extra symbol.

The dev master was edited from stable with this prompt:

> Preserve the Sai mark and its centered red square. Cut the ink square's
> upper-right corner with one large 45-degree diagonal and fill that section
> with Sai green `#3FA66A`; make the region large enough to survive 16px and
> grayscale. Add no text, badge, stripe or extra symbol.

From the repository root, regenerate every committed catalog derivative and
manifest, then verify that nothing is stale:

```sh
swift tool/app-icons.swift prepare
swift tool/app-icons.swift check
```

The tool applies the macOS transparent margin and rounded tile, writes 16,
32, 64, 128, 256, 512 and 1024px PNGs, rejects Flutter's retired placeholder,
allows only tightly bounded CoreGraphics resampling drift across macOS
versions, and requires stable and dev to remain distinct in grayscale at every
size.
