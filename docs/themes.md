# Themes

The map viewer is two parts. The map itself, in [`src/viewer.html`](../src/viewer.html), is the same for everyone: the tiles, panning and zooming, the zoom steps, and the place kept in the page's address. A **theme** draws everything around it: where the map sits on the page, a title, the position and scale, zoom controls, a grid, and what to show when there's no map. Storymap inlines the theme into `index.html` when it renders, so the page still opens straight from the disk.

## Choosing a theme

Pass `--theme` when rendering:

```bash
zig build run -- path/to/save.vcdbs out --theme plain
```

- **`printed`** (the default, [`src/themes/printed`](../src/themes/printed)): the map as a printed sheet, with a neatline, a grid labelled in the margin, a title cartouche, a scale bar and a key of hills for zooming.
- **`plain`** ([`src/themes/plain`](../src/themes/plain)): the map filling the window, with its name, the position, a scale and zoom buttons in small panels, light or dark with the reader's setting. It's short on purpose, so it's a good place to start your own.
- **A folder of your own:** `--theme path/to/my-theme`, holding a `theme.css` and a `theme.js` as described below. Copying `src/themes/plain` is the quickest start.

## Files

A theme is a stylesheet and a script:

- **`theme.css`** styles the page, and places the map: the page puts `#map` over the whole window (`position: fixed; inset: 0`), and the theme moves or frames it, e.g. `#map { inset: 2rem; border: 1px solid; }`. The map's size is measured from there, so a theme's stylesheet decides how much of the window the map gets.
- **`theme.js`** builds everything the theme draws and keeps it up to date, as below.

Both are inlined, so the stylesheet can't contain `</style` and the script can't contain `</script`. Anything they load has to come with them, for the same reason a page opened from the disk can't fetch files beside it: fonts and images go in as `data:` URLs.

## The script

The script calls `Storymap.theme` once, with a function that's given the map. The function builds the theme's elements and returns what to call as the view changes:

```js
Storymap.theme((map) => {
	// Build the theme's elements, around map.element or inside it.
	return {
		resize() {},       // Optional: the map's size changed, before the next update.
		update(view) {},   // The view changed: draw from it.
		fail(message) {},  // The map can't be shown: say why.
	};
});
```

### What the map gives a theme

| | |
| --- | --- |
| `map.element` | The map's element, `#map`. Elements added inside it (a grid, say) sit over the tiles. |
| `map.world` | `{ name, gameVersion }`, or `null` when the page has no map. |
| `map.view` | `{ name, title }` of the view shown, e.g. `"topdown"`, `"Top-down"`, or `null`. |
| `map.rendered` | When the map was rendered, as a `Date`, or `null`. |
| `map.zoomIn()`, `map.zoomOut()` | Step the zoom, as the + and − keys do. |
| `map.fit()` | Show the whole map, as the 0 key does. |
| `map.toScreen(x, z)` | Where a position in the game is on the map, as `{ x, y }` in pixels from its top-left corner. |
| `map.toGame(x, y)` | The position in the game at a point on the map, as `{ x, z }`. |

Positions are the game's, relative to the world's centre, as the game shows them.

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
