# Usage

```bash
storymap <save-file> [folder] [options]
storymap prepare [file] [options]
```

A render writes tiles and `index.html` to the folder, `out` by default.
`storymap --help` lists every option.

## Views

`--views` chooses what to draw, `topdown` by default.
Join views with `+`, and the page lets you switch between them.

| form | views |
| --- | --- |
| `--views topdown` | the top-down map |
| `--views isometric` | the isometric view, the same as `isometric@0` |
| `--views topdown+isometric` | both |
| `--views isometric@90` | the isometric view, turned |
| `--views isometric@0,90,180,270` | the isometric view from all four sides |

A rotation moves the viewer clockwise around the world:

| rotation | facing |
| --- | --- |
| 0 | north-west |
| 90 | north-east |
| 180 | south-east |
| 270 | south-west |

## Appearance

| option | use |
| --- | --- |
| `--theme <theme>` | what draws the page around the map, and the map's style: `printed` (the default), `plain`, or a theme's folder ([Themes](themes.md)) |
| `--style <style>` | how to draw the map, instead of the theme's style: `relief`, `game`, `game:shaded` or `game:coloured` ([Map style](themes.md#map-style)) |
| `--season <season>` | tint grass and leaves for `spring`, `summer`, `fall` or `winter`, instead of the season on the save's date |
| `--name <name>` | the world's name on the page, instead of the save's |

## Tile formats

Tiles are lossless PNG by default.

| option | format |
| --- | --- |
| `--webp` | lossless WebP |
| `--webp --lossy-from <level>` | WebP, lossy from this level up: level 0 is full detail, and level 2 is where blocks are 8 pixels wide |
| `--jpegxl` | lossless JPEG XL, which not every browser shows |

## Prepared blocks

A render needs the game's and mods' assets, prepared once into a file, `prepared.storyblk` by default.
The first render that needs it prepares it.
The file has every rotation, so one copied to a machine without the game can draw any of them.

| option | use |
| --- | --- |
| `--prepare` | prepare the blocks again before rendering |
| `--blocks <file>` | the prepared blocks file to use |
| `--game <folder>` | the game's install folder, if it isn't in the standard place |
| `--data <folder>` | the game's data folder, if it isn't in the standard place |

`storymap prepare [file]` prepares the file without rendering, and takes `--game` and `--data` too.

## Measuring

| option | use |
| --- | --- |
| `--no-write` | draw and encode the tiles without writing anything, to time the rest |
| `--json` | print the render's times and counts on stdout as one line of JSON |

[Performance](performance.md#measuring) has more.

## Clipping

Use `--clip` to draw a part of a world. 3 shapes are supported, as in the table below.

|Shape| **circle** | **square** | **rectangle** |
|---| --- | --- | --- |
|Syntax| `circle:radius@x,z` | `square:side@x,z` | `rect:widthxheight@x,z` or `rect:x,z..x,z` |
|Example| `--clip circle:100@196,-5964` | `--clip square:200@222,-5938` | `--clip rect:300x120@272,-5978` |
|Render| ![A round cut of a hillside](usage/clip-circle.png) | ![A square cut of the same hillside](usage/clip-square.png) | ![A long cut of the same hillside](usage/clip-rect.png) |

> Examples drawn with `--views isometric --theme plain`.
