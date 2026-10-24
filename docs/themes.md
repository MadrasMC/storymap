# Themes

The map viewer is two parts. The map itself, in [`src/viewer/viewer.html`](../src/viewer/viewer.html), is the same for everyone: the tiles, panning and zooming, the zoom steps, and the place kept in the page's address. A **theme** draws everything around it: where the map sits on the page, a title, the position and scale, zoom controls, a grid, and what to show when there's no map. Storymap inlines the theme into `index.html` when it renders, so the page still opens straight from the disk. A theme also says how the map itself is drawn ([Map style](#map-style)).

## Choosing a theme

Pass `--theme` when rendering:

```bash
zig build run -- path/to/save.vcdbs out --theme plain
```

- **`printed`** (the default, [`src/theme/printed`](../src/theme/printed)): the map as a printed sheet, with a neatline, a grid labelled in the margin, a title cartouche, a scale bar and a key of hills for zooming.
- **`plain`** ([`src/theme/plain`](../src/theme/plain)): the map as the game draws its own, filling the window, with its name, the position, a scale and zoom buttons in small panels, light or dark with the reader's setting. It's short on purpose, so it's a good place to start your own.
- **A folder of your own:** `--theme path/to/my-theme`, holding a `theme.css` and a `theme.js` as described below. Copying `src/theme/plain` is the quickest start.

`--style` draws the map in another style than the theme's, with the theme's colours ([Map style](#map-style)):

```bash
zig build run -- path/to/save.vcdbs out --style game:coloured
```

## Files

A theme is a stylesheet and a script, and the map's colours:

- **`theme.css`** styles the page, and places the map: the page puts `#map` over the whole window (`position: fixed; inset: 0`), and the theme moves or frames it, e.g. `#map { inset: 2rem; border: 1px solid; }`. The map's size is measured from there, so a theme's stylesheet decides how much of the window the map gets.
- **`theme.js`** builds everything the theme draws and keeps it up to date, as below.
- **`topdown/style.txt`** says how the map is drawn when it's rendered ([Map style](#map-style)). A theme without one draws its map as the Printed theme does.
- **`isometric/style.txt`** says how the isometric view is drawn ([Isometric style](#isometric-style)). A theme without one draws it in its top-down style.

The stylesheet and script are inlined, so the stylesheet can't contain `</style` and the script can't contain `</script`. Anything they load has to come with them, for the same reason a page opened from the disk can't fetch files beside it: fonts and images go in as `data:` URLs.

## The script

The script calls `Storymap.theme` once, with a function that's given the map and a layer to draw in. The function builds the theme's elements and returns what to call as the view changes:

```js
Storymap.theme((map, ui) => {
	// Build the theme's elements into ui.
	return {
		resize() {},       // Optional: the map's size changed, before the next update.
		update(view) {},   // The view changed: draw from it.
		fail(message) {},  // The map can't be shown: say why.
	};
});
```

### The layer to draw in

`ui` is an empty element over the whole window, above the map (`position: fixed; inset: 0`), so a theme places its elements with `position: absolute` and window coordinates, in the margins or over the map. It lets pointers through to the map, so dragging, the wheel and pinching still reach it, except on what the theme puts in it: its children take pointers again. That rule has no specificity, so a theme's own `pointer-events: none` wins, for something drawn over the map that shouldn't catch the pointer, like a frame.

To draw on the map itself, lay an element over it using the map's box from `update` (`view.left`, `view.top`, `view.width`, `view.height`). Printed's grid is an SVG sized that way, with `overflow: hidden` so its lines stop at the map's edge.

A theme can still reach anywhere in the page if it needs to; `ui` is so it doesn't have to.

### What the map gives a theme

| | |
| --- | --- |
| `map.element` | The map's element, `#map`, where the tiles are drawn. The theme's stylesheet places it. |
| `map.game` | `{ name, version }` of the game the world is from, e.g. `"Vintage Story"`, `"1.22.7"`, the version that last saved the world, or `null`. |
| `map.world` | `{ name }`, or `null` when the page has no map. |
| `map.view` | `{ name, title, projection }` of the view shown, e.g. `"topdown"`, `"Top-down"`, `"topdown"`, or `null`. It changes when the view does. |
| `map.views` | Every view the map has, each `{ name, title, projection }`, the first shown at the start. |
| `map.rendered` | When the map was rendered, as a `Date`, or `null`. |
| `map.zoomIn()`, `map.zoomOut()` | Step the zoom, as the + and − keys do. |
| `map.fit()` | Show the whole map, as the 0 key does. |
| `map.showView(name)` | Show another view, at the same place in the world. |
| `map.toScreen(x, z)` | Where a position in the game is on the map, as `{ x, y }` in pixels from its top-left corner, or `null` in a view without positions. |
| `map.toGame(x, y)` | The position in the game at a point on the map, as `{ x, z }`, or `null` in a view without positions. |

Positions are as the game shows them, from its origin: in Vintage Story, the world's centre. The isometric view has no positions to show, as each point on it covers a whole line of blocks, so a theme leaves out what's drawn from them there, such as a grid or the coordinates.

### What `update` is given

| | |
| --- | --- |
| `view.scale` | Screen pixels per tile pixel at full detail: 1 is full detail, 4 the closest zoom, ⅛ eight tile pixels to a screen pixel. In the top-down view a tile pixel is a block. |
| `view.centre` | The position at the centre of the map, `{ x, z }`, or `null` in a view without positions. |
| `view.position` | The block under the pointer, or at the centre without one, as whole numbers `{ x, z }`, or `null` in a view without positions. |
| `view.width`, `view.height` | The map's size in pixels. |
| `view.left`, `view.top` | Where its top-left corner is in the window, for things placed outside it. |
| `view.fit` | Whether the zoom is the view of the whole map. |
| `view.loading` | Whether tiles in view are taking a while to load. |

`update` is called after every redraw and whenever the pointer moves, so it should be quick.

### `fail`

Called instead of `update` when there's no map to show: the page has no map data, it has no view this viewer can draw, the world has nothing generated yet, or no tile loads. The message says which, in a sentence; the map has stopped, and `map.zoomIn()` and the rest do nothing.

## Map style

`topdown/style.txt` says how the top-down map is drawn when it's rendered: a style, then, for Storymap's own styles, a colour for every type of block on the map, and for two inks. One entry per line; a line starting with `#` is a comment. The Printed theme's:

```
style relief

land        #E4D2A0
desert      #EDDCA6
forest      #D4C997
plant       #DBD19C
settlement  #DEBFA0
road        #CDB08A
devastation #C9BBA0
glacier     #F2F0E6
lake        #B8C8B8
ocean       #B0C2C6
lava        #B85A30
ink         #4A301A
wateredge   #5C462E
```

The plain theme's, which draws the map as the game draws its own:

```
style game
```

- **The styles** are Storymap's own, `relief`, and the game's own, `game` for the game's default or `game:<name>` for one by name. A Storymap style takes the theme's colours; the game's styles take the game's own, and ignore any the file gives. A style that isn't one of these, or one the game doesn't have, stops the render with a message listing the ones there are.
- **`style relief`** draws a relief map. A type's colour is its colour at sea level: lower ground darkens towards `ink`, reaching it at the lowest, and higher ground pales towards white. Slopes facing the north-west are lit, the others shaded. Liquids darken with depth, and `wateredge` outlines water where it meets land.
- **The types** are Storymap's map types, which the game's reader sorts each block into, for Vintage Story by its map colour code ([rendering.md](rendering.md#block-colours)): ground (`land`, `desert` for sand and gravel, `forest` for wood and leaves, `plant`, `settlement` for most building blocks, `road`, `devastation`, `glacier` for snow and ice) and liquids (`lake` for water, `ocean` for saltwater, `lava`).
- **Only `style` is needed.** A colour left out is the Printed theme's, so a style can give just the colours it changes. A colour is `#RRGGBB`, given once; a repeated or unknown entry stops the render with a message saying which, on which line.

### Vintage Story's styles

- **`style game:shaded`**, or `style game`, draws the map as the game draws its own world map: each type's colour as it is, at any height, lit or shaded by the game's own hill shading. It looks under snow at what's beneath, and lakes aren't shaded but edged where they meet anything else.
- **`style game:coloured`** draws the map as the game draws its colour-accurate one: each block in the colour of its texture, with a grain of colours from across it, and the same hill shading on everything, water included. Nothing is looked under, and there are no edges. Blocks without a texture take their type's colour. Grass, leaves and water are tinted by the climate where they are and by the season on the save's date, or the one `--season` gives: `spring`, `summer`, `fall` or `winter` ([rendering.md](rendering.md#climate-and-season-tint)).

## Isometric style

`isometric/style.txt` says how the isometric view (`--isometric`) is drawn, in the same form as `topdown/style.txt`:

- **`style relief`** draws every block as a cube in its type's colour, darkening and paling with height as the relief map does, with its top, south and east faces lit differently. Colours the file leaves out are the theme's top-down colours, so the Printed theme's is just `style relief`.
- **`style game`** draws blocks the game draws as plain cubes, such as soil, rock and sand, in the game's own textures, and other blocks as cubes in their texture's average colour, with the same lighting of each face. Grass, leaves and water are tinted by the climate where they are and by the season, as in `game:coloured`, `--season` included. It's the Plain theme's style.

A theme without the file draws the isometric view in its top-down style: `relief` with the same colours, or `game` for any of the game's styles. `--style` sets only the top-down style.
