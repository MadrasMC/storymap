# Themes

The map viewer is two parts. The map itself, in [`src/viewer.html`](../src/viewer.html), is the same for everyone: the tiles, panning and zooming, the zoom steps, and the place kept in the page's address. A **theme** draws everything around it: where the map sits on the page, a title, the position and scale, zoom controls, a grid, and what to show when there's no map. Storymap inlines the theme into `index.html` when it renders, so the page still opens straight from the disk. A theme also says how the map itself is coloured ([Map colours](#map-colours)).

## Choosing a theme

Pass `--theme` when rendering:

```bash
zig build run -- path/to/save.vcdbs out --theme plain
```

- **`printed`** (the default, [`src/themes/printed`](../src/themes/printed)): the map as a printed sheet, with a neatline, a grid labelled in the margin, a title cartouche, a scale bar and a key of hills for zooming.
- **`plain`** ([`src/themes/plain`](../src/themes/plain)): the map filling the window, with its name, the position, a scale and zoom buttons in small panels, light or dark with the reader's setting. It's short on purpose, so it's a good place to start your own.
- **A folder of your own:** `--theme path/to/my-theme`, holding a `theme.css` and a `theme.js` as described below. Copying `src/themes/plain` is the quickest start.

## Files

A theme is a stylesheet and a script, and the map's colours:

- **`theme.css`** styles the page, and places the map: the page puts `#map` over the whole window (`position: fixed; inset: 0`), and the theme moves or frames it, e.g. `#map { inset: 2rem; border: 1px solid; }`. The map's size is measured from there, so a theme's stylesheet decides how much of the window the map gets.
- **`theme.js`** builds everything the theme draws and keeps it up to date, as below.
- **`topdown/style.txt`** colours the map when it's rendered ([Map colours](#map-colours)). A theme without one colours its map as the Printed theme does.

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
| `map.view` | `{ name, title }` of the view shown, e.g. `"topdown"`, `"Top-down"`, or `null`. |
| `map.rendered` | When the map was rendered, as a `Date`, or `null`. |
| `map.zoomIn()`, `map.zoomOut()` | Step the zoom, as the + and − keys do. |
| `map.fit()` | Show the whole map, as the 0 key does. |
| `map.toScreen(x, z)` | Where a position in the game is on the map, as `{ x, y }` in pixels from its top-left corner. |
| `map.toGame(x, y)` | The position in the game at a point on the map, as `{ x, z }`. |

Positions are as the game shows them, from its origin: in Vintage Story, the world's centre.

### What `update` is given

| | |
| --- | --- |
| `view.scale` | Screen pixels per block: 1 is full detail, 4 the closest zoom, ⅛ eight blocks to a pixel. |
| `view.centre` | The position at the centre of the map, `{ x, z }`. |
| `view.position` | The block under the pointer, or at the centre without one, as whole numbers `{ x, z }`. |
| `view.width`, `view.height` | The map's size in pixels. |
| `view.left`, `view.top` | Where its top-left corner is in the window, for things placed outside it. |
| `view.fit` | Whether the zoom is the view of the whole map. |
| `view.loading` | Whether tiles in view are taking a while to load. |

`update` is called after every redraw and whenever the pointer moves, so it should be quick.

### `fail`

Called instead of `update` when there's no map to show: the page has no map data, the view is one this viewer can't draw, the world has nothing generated yet, or no tile loads. The message says which, in a sentence; the map has stopped, and `map.zoomIn()` and the rest do nothing.

## Map colours

`topdown/style.txt` says how the top-down map is coloured when it's rendered: a drawing style, then a colour for every type of block on the map, and for two inks. One entry per line; a line starting with `#` is a comment. The Printed theme's:

```
style relief

land        #E4D2A0
desert      #E4D2A0
forest      #E4D2A0
plant       #E4D2A0
settlement  #E4D2A0
road        #E4D2A0
devastation #E4D2A0
glacier     #E4D2A0
lake        #B8C8B8
ocean       #B0C2C6
lava        #B85A30
ink         #4A301A
wateredge   #5C462E
```

- **The types** are the game's own map types, which every block has, from its map colour code ([rendering.md](rendering.md#block-colours)): ground (`land`, `desert` for sand and gravel, `forest` for wood and leaves, `plant`, `settlement` for most building blocks, `road`, `devastation`, `glacier` for snow and ice) and liquids (`lake` for water, `ocean` for saltwater, `lava`).
- **`style relief`** draws a relief map. A type's colour is its colour at sea level: lower ground darkens towards `ink`, reaching it at the lowest, and higher ground pales towards white. Slopes facing the north-west are lit, the others shaded. Liquids darken with depth, and `wateredge` outlines water where it meets land.
- **`style shaded`** draws the map as the game draws its own: each type's colour as it is, at any height, lit or shaded by the game's own hill shading. It looks under snow at what's beneath, and lakes aren't shaded but edged in `wateredge` where they meet anything else. `ink` isn't used. The plain theme uses it with the game's own colours.
- **Every entry is needed**, once, and a colour is `#RRGGBB`. A missing, repeated or unknown entry stops the render with a message saying which, on which line.
