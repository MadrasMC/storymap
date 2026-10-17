// The printed theme: the map as a printed sheet, inside a double neatline on a paper margin, with
// the grid's coordinates in the margin, a title cartouche, a panel with the position and a scale
// bar, and a key of hills for zooming. See docs/themes.md for what a theme is given and does.
Storymap.theme((map, ui) => {
	"use strict";
	const q = (selector) => document.querySelector(selector);
	const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
	// A hill as old maps draw them, each one drawn on its own, as if with a pen.
	const hills = {
		out: `<g transform="translate(0 -4) scale(0.45)"><path class="f" d="M-9.8 -0.1C-7.2 -1.6 -4.8 -10.2 -1.6 -11.4C1 -12 6.2 -2.2 10.1 -0.3Z"/><path class="o" d="M-9.8 -0.1C-7.2 -1.6 -4.8 -10.2 -1.6 -11.4C-0.9 -11.7 -0.3 -11.6 0.1 -11.3M0.9 -10.9C3.3 -8.6 6.2 -2.2 10.1 -0.3"/><path class="h" d="M1.8 -9.2L2.1 0M4.4 -6.1L4.6 -0.1M7 -2.9L7.3 0.1"/></g>
			<g transform="translate(-5.5 0) scale(0.55)"><path class="f" d="M-9.6 0.2C-6.2 -1.4 -3.4 -12.8 -0.4 -13.2C2.8 -11.8 5.6 -3 9.8 -0.2Z"/><path class="o" d="M-9.6 0.2C-6.2 -1.4 -3.4 -12.8 -0.4 -13.2C0.2 -13.3 0.6 -12.9 0.4 -12.5M0.2 -12.9C2.8 -11.8 5.6 -3 9.8 -0.2"/><path class="h" d="M1.4 -11.6L0.9 0M3 -9.4L3.1 0.1M4.8 -6.4L5.3 0M6.7 -3.4L7.2 0.2"/></g>
			<g transform="translate(5.5 0) scale(0.55)"><path class="f" d="M-10.6 0C-7.6 -0.2 -5 -8.6 -2.2 -10.6C0 -11.9 2 -11.2 3 -10.2C5.4 -8 7 -1.8 10.8 0.3Z"/><path class="o" d="M-10.6 0C-7.6 -0.2 -5 -8.6 -2.2 -10.6M-3.4 -10.4C-1.6 -11.6 1.4 -11.6 3 -10.2C5.4 -8 7 -1.8 10.8 0.3"/><path class="h" d="M2.4 -9.6L2.2 0.1M4 -7.4L4.4 0M6.3 -4L6.5 0.1M8.1 -1.7L8.6 0.1"/></g>`,
		in: `<g transform="scale(1.1)"><path class="f" d="M-10.5 0.3C-6.5 -0.8 -2.8 -11.6 0.6 -12.6C2.4 -13 6 -4 10.6 0.2Z"/><path class="o" d="M-10.5 0.3C-6.5 -0.8 -2.8 -11.6 0.6 -12.6C1.6 -12.9 2.5 -12 2.9 -10.3M-0.2 -12.3C1.2 -12.9 2.6 -11.6 4 -9.4C6 -6 7.4 -1.6 10.6 0.2"/><path class="h" d="M2 -11L1.6 0.1M3.6 -9.3L3.8 -0.1M5.2 -6.8L5.6 0.2M6.8 -4.2L7.1 0M8.4 -1.9L8.9 0.2"/></g>`,
	};
	ui.insertAdjacentHTML("beforeend", `
		<svg id="grid" aria-hidden="true"><path id="grid-lines"/></svg>
		<div class="neatline" aria-hidden="true"></div>
		<div class="ticks" id="ticks" aria-hidden="true"></div>
		<h1 class="title" id="title"><span class="kind" id="kind">A view of</span><span class="name" id="name">Storymap</span><span class="version" id="version"></span><span class="rendered" id="rendered"></span></h1>
		<div class="panel readout">
			<span class="line"><span id="coords" aria-hidden="true"></span><span id="status" role="status"></span></span>
			<span class="scale" aria-hidden="true"><i id="scale-bar"></i><span id="scale-label"></span></span>
		</div>
		<div class="panel controls">
			<button type="button" id="zoom-out" aria-label="Zoom out" title="Zoom out (−)">
				<svg class="hills" viewBox="-14 -16 28 18" aria-hidden="true">${hills.out}</svg>
				<svg class="arrow" viewBox="0 0 8 10" aria-hidden="true"><path d="M3.7 0.8C4.5 3.2 3.5 5.4 4.2 7.6"/><path d="M1.1 5.1C2 6.1 3.1 7 4.3 8"/><path d="M4 8.3C4.8 7.2 5.8 6.3 6.9 5.5"/></svg>
			</button>
			<button type="button" class="zoom" id="fit" aria-label="Show the whole map" title="Whole map (0)">
				<span id="zoom"></span>
				<svg class="ring" viewBox="0 0 60 26" preserveAspectRatio="none" aria-hidden="true"><path d="M47.5 4.2C38 0.6 16 0.9 7.4 7.2C1.6 11.6 2.4 19.8 15.6 23.1C29 26.4 49.8 24.2 56.2 17.4C61.2 12 57.6 6.2 46.2 3.5C41.4 2.4 35.8 2.7 29.8 4.2"/></svg>
			</button>
			<button type="button" id="zoom-in" aria-label="Zoom in" title="Zoom in (+)">
				<svg class="hills" viewBox="-14 -16 28 18" aria-hidden="true">${hills.in}</svg>
				<svg class="arrow" viewBox="0 0 8 10" aria-hidden="true"><path d="M4.3 9.4C3.7 7.6 4.5 5.6 3.9 3"/><path d="M1.2 5.6C2.1 4.7 3 3.7 3.8 2.6"/><path d="M3.5 2.3C4.5 3.4 5.6 4.3 6.9 5"/></svg>
			</button>
		</div>
		<p class="panel message" id="message" role="alert" hidden></p>`);
	const buttons = [...document.querySelectorAll(".controls button")];
	q("#zoom-in").addEventListener("click", () => map.zoomIn());
	q("#zoom-out").addEventListener("click", () => map.zoomOut());
	q("#fit").addEventListener("click", () => map.fit());

	// The cartouche: the kind of map, the world, and what it was made from and when.
	if (map.world?.name) q("#name").textContent = map.world.name;
	if (map.view) q("#kind").textContent = `A ${map.view.title.toLowerCase()} view of`;
	if (map.world?.gameVersion) q("#version").textContent = `Vintage Story ${map.world.gameVersion}`;
	if (map.rendered) q("#rendered").textContent = `Rendered ${map.rendered.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" })}`;

	// A name cut short, or lines left out on a short screen, open the cartouche to show it in full;
	// tapping again, outside or Escape closes it.
	const titleEl = q("#title");
	const nameEl = q("#name");
	const leftOut = [q("#kind"), q("#rendered")];
	let titleOpen = false;
	let sizing = null;
	function checkTruncated() {
		if (titleOpen || sizing) return;
		// Accents and descenders reach past the line box, so only a hidden line counts as cut short.
		const line = parseFloat(getComputedStyle(nameEl).lineHeight);
		const cut = nameEl.scrollWidth > nameEl.clientWidth + 1 || nameEl.scrollHeight > nameEl.clientHeight + line / 2
			|| leftOut.some((el) => el.textContent && getComputedStyle(el).display === "none");
		titleEl.classList.toggle("truncated", cut);
		if (cut) titleEl.tabIndex = 0;
		else titleEl.removeAttribute("tabindex");
	}
	function openTitle(open) {
		if (open === titleOpen || (open && !titleEl.classList.contains("truncated"))) return;
		titleOpen = open;
		// Turned around mid-way, it starts from where it is.
		const now = titleEl.getBoundingClientRect();
		const turning = sizing !== null;
		if (sizing) {
			sizing.cancel();
			sizing = null;
			titleEl.classList.remove("sizing");
		}
		// The box animates between its two sizes while showing the full name, which closing removes at the end.
		titleEl.classList.add("open");
		const full = titleEl.getBoundingClientRect();
		const contentWidth = nameEl.getBoundingClientRect().width;
		titleEl.classList.remove("open");
		const cut = titleEl.getBoundingClientRect();
		titleEl.classList.add("open");
		if (reduceMotion.matches) {
			titleEl.classList.toggle("open", open);
			return;
		}
		const [from, to] = open ? [turning ? now : cut, full] : [turning ? now : full, cut];
		titleEl.style.setProperty("--content-width", `${contentWidth}px`);
		titleEl.classList.add("sizing");
		sizing = titleEl.animate(
			[{ width: `${from.width}px`, height: `${from.height}px` }, { width: `${to.width}px`, height: `${to.height}px` }],
			{ duration: 200, easing: open ? "cubic-bezier(0.2, 0, 0, 1)" : "cubic-bezier(0.3, 0, 0.8, 0.15)", fill: "forwards" },
		);
		const animation = sizing;
		animation.finished.then(() => {
			if (sizing !== animation) return;
			titleEl.classList.remove("sizing");
			titleEl.classList.toggle("open", open);
			animation.cancel();
			sizing = null;
		}, () => {});
	}
	titleEl.addEventListener("click", () => openTitle(!titleOpen));
	titleEl.addEventListener("keydown", (e) => {
		if (e.key === "Enter" || e.key === " ") openTitle(!titleOpen);
		else if (e.key === "Escape") openTitle(false);
		else return;
		e.preventDefault();
		e.stopPropagation();
	});
	document.addEventListener("pointerdown", (e) => {
		if (!titleEl.contains(e.target)) openTitle(false);
	}, true);
	document.addEventListener("keydown", (e) => {
		if (e.key === "Escape") openTitle(false);
	});
	new ResizeObserver(checkTruncated).observe(titleEl);
	window.addEventListener("resize", checkTruncated);
	checkTruncated();

	// The coordinates' panel and the zoom key share one panel only where on their own they'd nearly
	// meet: side by side, the scale's row couldn't fit a 4rem bar and its label in full. It's
	// decided when the window changes size, not as the zoom or the coordinates change, so the
	// panels don't jump between the two.
	const readoutEl = q(".readout");
	const controlsEl = q(".controls");
	let merged = false;
	function arrange() {
		merged = false;
		ui.classList.remove("merged");
		scaleRoom();
		merged = room - scaleGap < 64 + labelWidth("1,000 blocks");
		ui.classList.toggle("merged", merged);
	}

	// The scale bar: the roundest length of 1, 2 or 5 times a power of ten that's at most 8rem
	// wide on screen, or 4rem where it shares its panel with the zoom key, and no longer than the
	// panel has room for beside its label. Where even a short bar leaves no room for the word, it's
	// shortened to "bl.", as printed scales abbreviate their units.
	const scaleBar = q("#scale-bar");
	const scaleLabel = q("#scale-label");
	const scaleEl = q(".readout .scale");
	const measure = document.createElement("canvas").getContext("2d");
	const labelWidth = (text) => measure.measureText(text).width;
	// The width the scale's row has, from the panel's left edge to short of the zoom key: 1.5rem
	// short side by side, or the panel's own padding where they share it. It changes only with
	// the layout, so it's measured once for each. Where it can't fit a 4rem bar beside
	// "1,000 blocks", the panel is compact: the scale says "bl." and the coordinates drop their
	// x and z, together and whatever the zoom, so neither flips as the numbers change.
	let roomFor = "";
	let room = 0;
	let scaleGap = 0;
	let compact = false;
	function scaleRoom() {
		const layout = `${merged} ${innerWidth}`;
		if (roomFor !== layout) {
			roomFor = layout;
			const padding = parseFloat(getComputedStyle(readoutEl).paddingLeft);
			const start = readoutEl.getBoundingClientRect().left + padding;
			const end = controlsEl.getBoundingClientRect().left - padding - (merged ? 0 : 24);
			room = end - start;
			scaleGap = parseFloat(getComputedStyle(scaleEl).columnGap);
			measure.font = getComputedStyle(scaleLabel).font;
			// A few pixels spare, as the label's measured width can differ slightly from how it's drawn.
			compact = room - scaleGap - 4 - labelWidth("1,000 blocks") < 64;
		}
		return room;
	}
	function showScale(scale) {
		const roundest = (longest) => {
			const widest = longest / scale;
			const power = 10 ** Math.floor(Math.log10(widest));
			return [5, 2, 1].map((m) => m * power).find((b) => b <= widest) ?? power;
		};
		const unit = (blocks) => (compact ? "bl." : blocks === 1 ? "block" : "blocks");
		const space = scaleRoom() - scaleGap - 4;
		const cap = merged ? 64 : 128;
		let blocks = roundest(cap);
		const longest = Math.min(cap, space - labelWidth(`${blocks.toLocaleString("en")} ${unit(blocks)}`));
		if (longest < cap) blocks = roundest(Math.max(longest, 16));
		scaleBar.style.width = `${Math.round(blocks * scale)}px`;
		scaleLabel.textContent = `${blocks.toLocaleString("en")} ${unit(blocks)}`;
	}

	// The position under the pointer, or at the centre of the screen without one, as the game shows it.
	const coordsEl = q("#coords");
	const number = (n) => (n < 0 ? `−${-n}` : String(n));
	function showCoords({ x, z }) {
		coordsEl.innerHTML = compact
			? `${number(x)}<span class="k">,</span> ${number(z)}`
			: `<span class="k">x</span> ${number(x)} <span class="k">z</span> ${number(z)}`;
	}

	// The zoom as a scale of screen pixels to blocks, the same for every world, written as maps and
	// drawings write theirs: 1 : 1 draws a block as one pixel, the tiles' full detail, 1 : 8 fits
	// eight blocks in a pixel, and 4 : 1 draws a block four pixels wide. A zoom the wheel or a pinch
	// left between whole numbers shows the nearest one in italic over a dotted line. At the view of
	// the whole map it's circled. Pressing the zoom shows the whole map.
	const zoomEl = q("#zoom");
	const fitEl = q("#fit");
	function showZoom(scale, fit) {
		fitEl.classList.toggle("fitted", fit);
		const ratio = scale >= 1 ? scale : 1 / scale;
		const rounded = Math.round(ratio);
		const [pixels, blocks] = scale >= 1 ? [rounded, 1] : [1, rounded];
		zoomEl.classList.toggle("near", Math.abs(ratio / rounded - 1) >= 0.005);
		const text = `${pixels}<span>:</span>${blocks.toLocaleString("en")}`;
		if (zoomEl.innerHTML !== text) zoomEl.innerHTML = text;
	}

	// The grid: a line every round number of blocks in the game's coordinates, 90 to 225 pixels
	// apart, with the coordinates in the margin on all four sides of the sheet. It's laid over the
	// map, which clips its lines at the map's edge.
	const grid = q("#grid");
	const gridLines = q("#grid-lines");
	const ticks = q("#ticks");
	let gridBox = "";
	function showGrid(view) {
		const box = `left:${view.left}px;top:${view.top}px;width:${view.width}px;height:${view.height}px`;
		if (box !== gridBox) grid.style.cssText = gridBox = box;
		const narrowest = 90 / view.scale;
		const power = 10 ** Math.floor(Math.log10(narrowest));
		const step = [1, 2, 5, 10].map((m) => m * power).find((b) => b >= narrowest);
		// Screen position of a game coordinate; lines sit on half pixels to stay one pixel wide.
		const sx = (x) => Math.round(map.toScreen(x, 0).x) + 0.5;
		const sy = (z) => Math.round(map.toScreen(0, z).y) + 0.5;
		const corner = map.toGame(0, 0);
		const firstX = Math.ceil(corner.x / step) * step;
		const firstZ = Math.ceil(corner.z / step) * step;
		const path = [];
		const labels = [];
		// Labels too near a corner would run into the other edge's.
		const clear = 24;
		for (let x = firstX; sx(x) < view.width; x += step) {
			path.push(`M${sx(x)} 0V${view.height}`);
			if (sx(x) > clear && sx(x) < view.width - clear) {
				const label = `style="left:${view.left + sx(x)}px">${number(x)}</span>`;
				labels.push(`<span class="x" ${label}`, `<span class="x end" ${label}`);
			}
		}
		for (let z = firstZ; sy(z) < view.height; z += step) {
			path.push(`M0 ${sy(z)}H${view.width}`);
			if (sy(z) > clear && sy(z) < view.height - clear) {
				const label = `style="top:${view.top + sy(z)}px">${number(z)}</span>`;
				labels.push(`<span class="z" ${label}`, `<span class="z end" ${label}`);
			}
		}
		gridLines.setAttribute("d", path.join(""));
		ticks.innerHTML = labels.join("");
	}

	const statusEl = q("#status");
	return {
		resize: arrange,
		update(view) {
			statusEl.textContent = view.loading ? "Loading…" : "";
			// The scale first: it settles whether the panel is compact, which the coordinates follow.
			showScale(view.scale);
			showCoords(view.position);
			showZoom(view.scale, view.fit);
			showGrid(view);
		},
		fail(message) {
			const el = q("#message");
			el.textContent = message;
			el.hidden = false;
			readoutEl.hidden = true;
			ticks.hidden = true;
			gridLines.removeAttribute("d");
			for (const button of buttons) button.disabled = true;
		},
	};
});
