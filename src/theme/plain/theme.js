// The plain theme: the map filling the window, with its name, the position and a scale, and zoom
// buttons in small panels over it. Short on purpose, as a place to start a theme of your own;
// see docs/themes.md for what a theme is given and does.
Storymap.theme((map, ui) => {
	"use strict";
	const element = (html) => {
		const template = document.createElement("template");
		template.innerHTML = html.trim();
		return template.content.firstElementChild;
	};
	const icon = (d) => `<svg viewBox="0 0 16 16" aria-hidden="true"><path d="${d}"/></svg>`;

	// The world's name, and what it was made from and when.
	const title = element(`<div class="plain plain-title"><h1></h1><p></p></div>`);
	title.querySelector("h1").textContent = map.world?.name || "Storymap";
	const about = [
		[map.game?.name, map.game?.version].filter(Boolean).join(" "),
		map.rendered && `Rendered ${map.rendered.toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" })}`,
	].filter(Boolean).join(" · ");
	title.querySelector("p").textContent = about;
	title.querySelector("p").hidden = !about;

	// The position under the pointer, the scale, and whether tiles are still loading.
	const status = element(`<div class="plain plain-status"><span class="position" aria-hidden="true"></span><span class="scale" aria-hidden="true"><i></i><span></span></span><span class="loading" role="status"></span></div>`);
	const position = status.querySelector(".position");
	const bar = status.querySelector(".scale i");
	const label = status.querySelector(".scale span");
	const loading = status.querySelector(".loading");

	const zoom = element(`<div class="plain plain-zoom">
		<button type="button" aria-label="Zoom in" title="Zoom in (+)">${icon("M8 3v10M3 8h10")}</button>
		<button type="button" aria-label="Zoom out" title="Zoom out (−)">${icon("M3 8h10")}</button>
		<button type="button" aria-label="Show the whole map" title="Whole map (0)">${icon("M3 6V3h3M10 3h3v3M13 10v3h-3M6 13H3v-3")}</button>
	</div>`);
	const buttons = [...zoom.querySelectorAll("button")];
	buttons[0].addEventListener("click", () => map.zoomIn());
	buttons[1].addEventListener("click", () => map.zoomOut());
	buttons[2].addEventListener("click", () => map.fit());

	// The views, where the map has more than one.
	const views = element(`<div class="plain plain-views" role="group" aria-label="Views"></div>`);
	const viewButtons = map.views.map((v) => {
		const button = element(`<button type="button"></button>`);
		button.textContent = v.title;
		button.addEventListener("click", () => map.showView(v.name));
		views.append(button);
		return { name: v.name, button };
	});
	views.hidden = viewButtons.length < 2;
	buttons.push(...viewButtons.map((v) => v.button));

	ui.append(title, status, zoom, views);
	const number = (n) => (n < 0 ? `−${-n}` : String(n));
	return {
		update(view) {
			for (const { name, button } of viewButtons) button.setAttribute("aria-pressed", String(map.view?.name === name));
			loading.textContent = view.loading ? "Loading…" : "";
			// A view without positions, such as the isometric one, has no position or scale, and
			// shows the panel only while tiles load.
			const positions = view.position !== null;
			status.hidden = !positions && !view.loading;
			position.hidden = !positions;
			bar.parentElement.hidden = !positions;
			if (!positions) return;
			position.textContent = `${number(view.position.x)}, ${number(view.position.z)}`;
			// A round number of blocks, 1, 2 or 5 times a power of ten, at most 80 pixels long.
			const widest = 80 / view.scale;
			const power = 10 ** Math.floor(Math.log10(widest));
			const blocks = [5, 2, 1].map((m) => m * power).find((b) => b <= widest) ?? power;
			bar.style.width = `${Math.round(blocks * view.scale)}px`;
			label.textContent = `${blocks.toLocaleString("en")} ${blocks === 1 ? "block" : "blocks"}`;
		},
		fail(message) {
			status.hidden = true;
			for (const button of buttons) button.disabled = true;
			const note = element(`<p class="plain plain-message" role="alert"></p>`);
			note.textContent = message;
			ui.append(note);
		},
	};
});
