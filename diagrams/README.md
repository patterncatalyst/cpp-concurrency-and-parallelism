# Diagrams

Figures for this book are pairs of files in this directory:
`<name>.svg` (rendered, embedded in the site) and `<name>.excalidraw`
(editable source). No diagrams exist yet: this phase only documents
the palette so later figures stay consistent.

## Palette

This project uses a bespoke palette, not the `lgtm-diagram-generator`
default amber theme. Point the generator at these values explicitly:

| Role              | Hex       |
|-------------------|-----------|
| Background        | `#fdfbf7` |
| Blue (primary)    | `#4a73b8` |
| Green (success)   | `#5a8870` |
| Red (danger/heat) | `#c0392b` |
| Orange (warning)  | `#a06030` |
| Ink (text)        | `#1a1a1a` |
| Muted text        | `#444444` |

## Naming and embedding

Each figure is named `<NN>-<slug>` (chapter number plus a short slug,
e.g. `02-futex-wakeup`) and embedded in a chapter's Markdown body via:

```liquid
{% include excalidraw.html name="NN-slug" caption="Figure N.x: ..." %}
```

The include resolves the SVG at `/diagrams/<name>.svg` and offers the
`.excalidraw` source as a download at `/diagrams/<name>.excalidraw`. If
a figure hasn't been drawn yet, the include shows a placeholder so the
page doesn't break.

## Generating figures

When generating figures with `lgtm-diagram-generator`, pass this
palette explicitly: do not use the generator's amber default. Keep
background, ink, and muted-text values exact so figures read
consistently against this site's `site.css` light theme.
