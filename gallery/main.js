// Shows the pictures in a Storymap pictures.bin, the isometric view's pictures of a game's blocks,
// as src/renderer/Pictures.zig writes them. A prepared blocks folder's blocks.txt and colormaps,
// when given with it, name the blocks and tint them.

const MAGIC = "SMPICTS\0";
// The layout is the same from version 3 on; later versions only changed what's drawn. A changed
// layout fails parse's size checks.
const FIRST_VERSION = 3;
const HEADER_SIZE = 24;
const ENTRY_SIZE = 12;
const STORED_SIZE = 16;

// A tile's box is this many picture pixels across at 1×: a cube's square and a little around it.
const BOX = 48;

// Tinted layers are tinted as at a temperate place at sea level in midsummer (src/vs/Tint.zig).
const TEMPERATURE = 165;
const RAINFALL = 110;
const PROGRESS = 0.5;
// The tint without blocks.txt or its colour maps: climatePlantTint and seasonalGrass there.
const DEFAULT_TINT = [133, 165, 13];
const WHITE = [255, 255, 255];

const DATABASE = "storymap-pictures";
const STORE = "sets";
const KEY = "current";

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

const $ = (id) => document.getElementById(id);
const blocksView = $("blocks");
const dialog = $("detail");
const menu = $("open-menu");
const openButton = $("open");
const dropOverlay = $("drop");
const toastElement = $("toast");

let shown = null; // { set, record, blocks, groups }
let zoom = 2;
let current = null; // the block open in the dialog
let closing = false;

// Reading pictures.bin

function parse(buffer) {
	if (buffer.byteLength < HEADER_SIZE) throw new Error("This isn't a pictures.bin: it's too short.");
	const view = new DataView(buffer);
	const magic = String.fromCharCode(...new Uint8Array(buffer, 0, 8));
	if (magic !== MAGIC) throw new Error("This isn't a pictures.bin.");
	const version = view.getUint32(8, true);
	const entryCount = view.getUint32(12, true);
	const pictureCount = view.getUint32(16, true);
	const dataLength = view.getUint32(20, true);
	if (version < FIRST_VERSION) throw new Error(`This pictures.bin is version ${version}, older than this viewer reads. Render again to redraw it.`);
	const storedAt = HEADER_SIZE + entryCount * ENTRY_SIZE;
	const dataAt = storedAt + pictureCount * STORED_SIZE;
	if (buffer.byteLength !== dataAt + dataLength) throw new Error(`This pictures.bin (version ${version}) isn't laid out as this viewer reads.`);

	const entries = [];
	for (let i = 0; i < entryCount; i++) {
		const at = HEADER_SIZE + i * ENTRY_SIZE;
		const entry = {
			first: view.getUint32(at, true),
			variants: view.getUint16(at + 4, true),
			alternates: view.getUint16(at + 6, true),
			turns: view.getUint8(at + 8),
			flags: view.getUint8(at + 9),
		};
		if (entry.variants > 0 && (entry.alternates === 0 || entry.turns === 0)) throw new Error(`Block ${i} in this pictures.bin has no shapes or turns.`);
		if (entry.first + entry.variants * entry.alternates * entry.turns > pictureCount) throw new Error(`Block ${i} in this pictures.bin names pictures it doesn't have.`);
		entries.push(entry);
	}

	const stored = {
		offset: new Uint32Array(pictureCount),
		left: new Int16Array(pictureCount),
		top: new Int16Array(pictureCount),
		width: new Uint16Array(pictureCount),
		height: new Uint16Array(pictureCount),
		flags: new Uint32Array(pictureCount),
	};
	for (let i = 0; i < pictureCount; i++) {
		const at = storedAt + i * STORED_SIZE;
		const offset = view.getUint32(at, true);
		const width = view.getUint16(at + 8, true);
		const height = view.getUint16(at + 10, true);
		const flags = view.getUint32(at + 12, true);
		const pixels = width * height;
		const length = pixels * (flags & 1 ? 8 : 4) + Math.ceil((pixels * 2) / 4) * 4;
		if (offset % 4 !== 0 || offset + length > dataLength) throw new Error(`Picture ${i} in this pictures.bin runs past its end.`);
		stored.offset[i] = offset;
		stored.left[i] = view.getInt16(at + 4, true);
		stored.top[i] = view.getInt16(at + 6, true);
		stored.width[i] = width;
		stored.height[i] = height;
		stored.flags[i] = flags;
	}
	return { version, entries, stored, data: new Uint8Array(buffer, dataAt, dataLength) };
}

// Picture `index`, its tinted layer tinted by `tint`, drawn over its plain one as the renderer
// blends them (isometric.blend).
function drawPicture(canvas, set, index, tint) {
	const width = set.stored.width[index];
	const height = set.stored.height[index];
	canvas.width = width;
	canvas.height = height;
	if (width === 0 || height === 0) return;
	const pixels = width * height;
	const at = set.stored.offset[index];
	const plain = set.data.subarray(at, at + pixels * 4);
	const image = new ImageData(width, height);
	const out = image.data;
	out.set(plain);
	if (set.stored.flags[index] & 1) {
		const layer = set.data.subarray(at + pixels * 4, at + pixels * 8);
		for (let p = 0; p < pixels * 4; p += 4) {
			const a = layer[p + 3];
			if (a === 0) continue;
			for (let c = 0; c < 3; c++) {
				const tinted = Math.floor((layer[p + c] * tint[c]) / 255);
				out[p + c] = Math.floor((tinted * a + plain[p + c] * (255 - a)) / 255);
			}
			out[p + 3] = 255;
		}
	}
	canvas.getContext("2d").putImageData(image, 0, 0);
}

// Reading blocks.txt and the colour maps

function parseBlocks(text) {
	if (!text.startsWith("storymap blocks ")) throw new Error("This blocks.txt isn't one Storymap prepared.");
	const names = [];
	const climates = [];
	const seasons = [];
	const maps = [];
	let start = 0;
	while (start < text.length) {
		let end = text.indexOf("\n", start);
		if (end < 0) end = text.length;
		if (text.startsWith("block ", start)) {
			// Only the first fields are needed; a block's line can run to thousands of characters.
			const fields = text.slice(start, Math.min(end, start + 512)).split(" ", 8);
			names.push(fields[1]);
			climates.push(fields[6]);
			seasons.push(fields[7]);
		} else if (text.startsWith("colormap ", start)) {
			const fields = text.slice(start, end).trim().split(" ");
			maps.push({ code: fields[1], padding: Number(fields[2]), tropical: fields[3] === "1" });
		}
		start = end + 1;
	}
	return { names, climates, seasons, maps };
}

async function decodeColourMap(file, padding, tropical) {
	const bitmap = await createImageBitmap(file);
	const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
	const context = canvas.getContext("2d");
	context.drawImage(bitmap, 0, 0);
	const pixels = context.getImageData(0, 0, bitmap.width, bitmap.height).data;
	bitmap.close();
	if (bitmap.width <= 2 * padding || bitmap.height <= 2 * padding) return null;
	return { width: canvas.width, height: canvas.height, pixels, padding, tropical };
}

function colourAt(map, across, down) {
	const p = map.padding;
	const x = p + Math.min(Math.floor(across * (map.width - 2 * p)), map.width - 2 * p - 1);
	const y = p + Math.min(Math.floor(down * (map.height - 2 * p)), map.height - 2 * p - 1);
	const at = (y * map.width + x) * 4;
	return [map.pixels[at], map.pixels[at + 1], map.pixels[at + 2]];
}

function seasonAt(map, progress) {
	const x = Math.min(Math.floor(clamp(progress, 0.01, 0.99) * map.width), map.width - 1);
	const sums = [0, 0, 0];
	for (let y = 0; y < map.height; y++) {
		const at = (y * map.width + x) * 4;
		for (let c = 0; c < 3; c++) sums[c] += map.pixels[at + c];
	}
	return sums.map((sum) => Math.floor(sum / map.height));
}

function clamp(value, low, high) {
	return Math.min(Math.max(value, low), high);
}

// Tint.tint at sea level, where rainfall gains 40.
function tint(climate, season) {
	const t = clamp(clamp(TEMPERATURE, 0, 255) / 255, 0.001, 0.999);
	const r = clamp(clamp(RAINFALL + 40, 0, 255) / 255, 0.001, 0.999);
	let out = climate ? colourAt(climate, t, r) : [...WHITE];
	if (season) {
		let weight;
		if (season.tropical) {
			weight = clamp(t * 0.9 - 0.1, 0, 1) * clamp((2 * (0.5 - Math.cos((r * 255) / 42))) / 2.1, 0.1, 0.75);
		} else {
			const x = t * 255;
			weight = clamp(0.5 - Math.cos(x / 42) / 2.3 + Math.max(0, 128 - x) / 256 / 2 - Math.max(0, x - 130) / 200, 0, 1);
		}
		const colour = seasonAt(season, PROGRESS);
		out = out.map((value, c) => value + (colour[c] - value) * weight);
	}
	return out.map((value) => clamp(Math.round(value), 0, 255));
}

// Each block's tint, three bytes a block: white for one without colour maps, as the renderer
// leaves it.
async function tintsOf(blocks, colourMapFiles) {
	const maps = await Promise.all(
		blocks.maps.map(async (map) => {
			const file = colourMapFiles.get(map.code);
			if (!file) return null;
			try {
				return await decodeColourMap(file, map.padding, map.tropical);
			} catch {
				return null;
			}
		}),
	);
	const byPair = new Map();
	const tints = new Uint8Array(blocks.names.length * 3);
	for (let n = 0; n < blocks.names.length; n++) {
		const pair = blocks.climates[n] + " " + blocks.seasons[n];
		let colour = byPair.get(pair);
		if (!colour) {
			const climate = blocks.climates[n] === "-" ? undefined : maps[Number(blocks.climates[n])];
			const season = blocks.seasons[n] === "-" ? undefined : maps[Number(blocks.seasons[n])];
			if (climate === undefined && season === undefined) colour = WHITE;
			else if (!climate && !season) colour = DEFAULT_TINT;
			else colour = tint(climate, season);
			byPair.set(pair, colour);
		}
		tints.set(colour, n * 3);
	}
	return tints;
}

// Choosing what to open

function baseName(path) {
	return path.slice(path.lastIndexOf("/") + 1);
}

function folderOf(path) {
	const slash = path.lastIndexOf("/");
	return slash < 0 ? "" : path.slice(0, slash);
}

// From what was dropped or chosen, the newest pictures.bin and the blocks.txt and colour maps
// beside it: a whole blocks folder can hold several prepared sets.
function choose(files) {
	const pictures = files.filter((f) => baseName(f.path) === "pictures.bin");
	if (pictures.length === 0) throw new Error("There's no pictures.bin in what was opened.");
	pictures.sort((a, b) => b.file.lastModified - a.file.lastModified);
	const bin = pictures[0];
	const folder = folderOf(bin.path);
	const allBlocks = files.filter((f) => baseName(f.path) === "blocks.txt");
	const blocks = allBlocks.find((f) => folderOf(f.path) === folder) ?? (allBlocks.length === 1 ? allBlocks[0] : null);
	const colourMaps = new Map();
	const mapsFolder = folder ? folder + "/colormaps" : "colormaps";
	const images = files.filter((f) => f.path.toLowerCase().endsWith(".png"));
	images.sort((a, b) => (folderOf(b.path) === mapsFolder) - (folderOf(a.path) === mapsFolder));
	for (const image of images) {
		const code = baseName(image.path).slice(0, -4);
		if (!colourMaps.has(code)) colourMaps.set(code, image.file);
	}
	// The prepared set's folder is named by its key; files opened on their own have no name.
	const name = folder ? baseName(folder) : "";
	return { name, bin: bin.file, blocks: blocks?.file ?? null, colourMaps };
}

async function filesOfDrop(dataTransfer) {
	// Entries must be taken while the drop event runs: the data transfer empties after it.
	const entries = [...dataTransfer.items].filter((item) => item.kind === "file").map((item) => item.webkitGetAsEntry?.()).filter(Boolean);
	if (entries.length === 0) return [...dataTransfer.files].map((file) => ({ path: file.name, file }));
	const files = [];
	await Promise.all(entries.map((entry) => walk(entry, files)));
	return files;
}

async function walk(entry, files) {
	if (entry.isFile) {
		const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
		files.push({ path: entry.fullPath.replace(/^\//, ""), file });
		return;
	}
	if (!entry.isDirectory) return;
	const reader = entry.createReader();
	for (;;) {
		const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
		if (batch.length === 0) break;
		await Promise.all(batch.map((child) => walk(child, files)));
	}
}

function filesOfInput(input) {
	return [...input.files].map((file) => ({ path: file.webkitRelativePath || file.name, file }));
}

// Opening

async function open(files) {
	let chosen;
	try {
		chosen = choose(files);
	} catch (error) {
		toast(error.message, true);
		return;
	}
	const title = `Reading ${chosen.name || "pictures.bin"}`;
	showLoading(title, `pictures.bin, ${formatBytes(chosen.bin.size)}`);
	try {
		const set = parse(await chosen.bin.arrayBuffer());
		let names = null;
		let tints = null;
		let warning = null;
		if (chosen.blocks) {
			showLoading(title, `blocks.txt, ${formatBytes(chosen.blocks.size)}`);
			try {
				const blocks = parseBlocks(await chosen.blocks.text());
				if (blocks.names.length !== set.entries.length) {
					warning = "That blocks.txt is for another pictures.bin, so blocks are shown by number.";
				} else {
					names = blocks.names;
					tints = await tintsOf(blocks, chosen.colourMaps);
				}
			} catch (error) {
				warning = `${error.message} Blocks are shown by number.`;
			}
		}
		const record = { name: chosen.name, pictures: chosen.bin, names, tints };
		show(set, record);
		if (warning) toast(warning, true);
		try {
			await save(record);
		} catch (error) {
			toast(`It couldn't be kept for next time: ${error.message}`, true);
		}
	} catch (error) {
		restoreView();
		toast(error.message, true);
	}
}

async function openSaved() {
	let record;
	try {
		record = await load();
	} catch {
		record = null;
	}
	if (!record) {
		showEmpty();
		return;
	}
	showLoading(`Opening ${record.name || "pictures.bin"}`, `pictures.bin, ${formatBytes(record.pictures.size)}`);
	try {
		show(parse(await record.pictures.arrayBuffer()), record);
	} catch (error) {
		showEmpty();
		toast(`The saved pictures.bin can't be read: ${error.message}`, true);
		forget().catch(() => {});
	}
}

async function closeSet() {
	shown = null;
	blocksView.replaceChildren();
	showEmpty();
	try {
		await forget();
	} catch (error) {
		toast(`It couldn't be removed: ${error.message}`, true);
	}
}

// Storage

function database() {
	return new Promise((resolve, reject) => {
		const request = indexedDB.open(DATABASE, 1);
		request.onupgradeneeded = () => request.result.createObjectStore(STORE);
		request.onsuccess = () => resolve(request.result);
		request.onerror = () => reject(request.error);
	});
}

async function transact(mode, act) {
	const db = await database();
	try {
		return await new Promise((resolve, reject) => {
			const transaction = db.transaction(STORE, mode);
			const request = act(transaction.objectStore(STORE));
			transaction.oncomplete = () => resolve(request.result);
			transaction.onerror = () => reject(transaction.error);
			transaction.onabort = () => reject(transaction.error ?? new Error("Storage was refused."));
		});
	} finally {
		db.close();
	}
}

const save = (record) => transact("readwrite", (store) => store.put(record, KEY));
const load = () => transact("readonly", (store) => store.get(KEY));
const forget = () => transact("readwrite", (store) => store.delete(KEY));

// Views

function showEmpty() {
	document.body.classList.add("empty");
	$("set-name").textContent = "";
	$("empty").hidden = false;
	$("loading").hidden = true;
	blocksView.hidden = true;
}

function showLoading(title, detail) {
	document.body.classList.add("empty");
	$("loading-title").textContent = title;
	$("loading-detail").textContent = detail;
	$("empty").hidden = true;
	$("loading").hidden = false;
	blocksView.hidden = true;
}

function restoreView() {
	if (shown) showBlocks();
	else showEmpty();
}

function showBlocks() {
	document.body.classList.remove("empty");
	$("set-name").textContent = shown.record.name;
	$("empty").hidden = true;
	$("loading").hidden = true;
	blocksView.hidden = false;
}

function describe(set, record) {
	const blocks = [];
	set.entries.forEach((entry, number) => {
		if (entry.variants === 0) return;
		const code = record.names ? record.names[number] : null;
		let group = "Blocks";
		let label = `#${number}`;
		if (code) {
			const colon = code.indexOf(":");
			const domain = colon < 0 ? "" : code.slice(0, colon + 1);
			const name = code.slice(colon + 1);
			const dash = name.indexOf("-");
			group = domain + (dash < 0 ? name : name.slice(0, dash));
			label = dash < 0 ? name : name.slice(dash + 1);
		}
		const colour = record.tints ? [...record.tints.subarray(number * 3, number * 3 + 3)] : entry.flags & 2 ? DEFAULT_TINT : WHITE;
		blocks.push({
			number,
			code: code ?? `Block ${number}`,
			search: (code ?? "").toLowerCase() + " #" + number,
			group,
			label,
			tint: colour,
			...entry,
			count: entry.variants * entry.alternates * entry.turns,
		});
	});
	return blocks;
}

const tileObserver = new IntersectionObserver(
	(entries) => {
		for (const entry of entries) {
			if (!entry.isIntersecting) continue;
			tileObserver.unobserve(entry.target);
			const block = entry.target.block;
			drawPicture(block.canvas, shown.set, block.first, block.tint);
		}
	},
	{ rootMargin: "800px 0px" },
);

function fit(width, height) {
	return Math.max(1, Math.min(zoom, Math.floor((BOX * zoom) / Math.max(width, height, 1))));
}

function sizeTile(block) {
	const stored = shown.set.stored;
	const width = stored.width[block.first];
	const height = stored.height[block.first];
	const scale = fit(width, height);
	block.canvas.style.width = width * scale + "px";
	block.canvas.style.height = height * scale + "px";
}

function show(set, record) {
	tileObserver.disconnect();
	shown = { set, record, blocks: describe(set, record), groups: [] };
	const byGroup = new Map();
	for (const block of shown.blocks) {
		if (!byGroup.has(block.group)) byGroup.set(block.group, []);
		byGroup.get(block.group).push(block);
	}
	const sections = [];
	for (const name of [...byGroup.keys()].sort()) {
		const section = document.createElement("section");
		section.className = "group";
		const heading = document.createElement("h2");
		const count = document.createElement("span");
		heading.append(name, count);
		const grid = document.createElement("div");
		grid.className = "tiles";
		const blocks = byGroup.get(name);
		for (const block of blocks) grid.append(tileOf(block));
		section.append(heading, grid);
		sections.push(section);
		shown.groups.push({ section, count, blocks });
	}
	blocksView.replaceChildren(...sections);
	showBlocks();
	applyFilter();
	window.scrollTo(0, 0);
}

function tileOf(block) {
	const tile = document.createElement("button");
	tile.type = "button";
	tile.className = "tile";
	tile.title = block.code;
	const frame = document.createElement("span");
	frame.className = "frame";
	block.canvas = document.createElement("canvas");
	block.canvas.className = "picture";
	sizeTile(block);
	frame.append(block.canvas);
	const label = document.createElement("span");
	label.className = "label";
	label.textContent = block.label;
	tile.append(frame, label);
	if (block.count > 1) {
		const number = document.createElement("span");
		number.className = "number";
		number.textContent = block.count;
		tile.append(number);
	}
	tile.block = block;
	block.tile = tile;
	tileObserver.observe(tile);
	return tile;
}

const filters = {
	all: () => true,
	shape: (b) => (b.flags & 1) !== 0,
	alternates: (b) => b.alternates > 1,
	turns: (b) => b.turns > 1,
	variants: (b) => b.variants > 1,
	tinted: (b) => (b.flags & 2) !== 0,
};

function applyFilter() {
	if (!shown) return;
	const text = $("search").value.trim().toLowerCase();
	const filter = filters[$("filter").value];
	let blockCount = 0;
	let pictureCount = 0;
	// Blocks drawn alike share their pictures.
	const counted = new Set();
	for (const group of shown.groups) {
		let inGroup = 0;
		for (const block of group.blocks) {
			const visible = filter(block) && (!text || block.search.includes(text));
			block.tile.hidden = !visible;
			if (!visible) continue;
			inGroup++;
			if (!counted.has(block.first)) pictureCount += block.count;
			counted.add(block.first);
		}
		group.section.hidden = inGroup === 0;
		group.count.textContent = inGroup.toLocaleString("en");
		blockCount += inGroup;
	}
	const blocks = document.createElement("span");
	blocks.textContent = `${blockCount.toLocaleString("en")} blocks`;
	const pictures = document.createElement("span");
	pictures.textContent = `${pictureCount.toLocaleString("en")} pictures`;
	$("count").replaceChildren(blocks, pictures);
}

function setZoom(value) {
	zoom = value;
	document.documentElement.style.setProperty("--box", BOX * zoom + "px");
	if (!shown) return;
	for (const block of shown.blocks) sizeTile(block);
	if (dialog.open) fillDetail(current);
}

// Detail

function visibleBlocks() {
	return shown.blocks.filter((block) => !block.tile.hidden && !block.tile.closest(".group").hidden);
}

function fillDetail(block) {
	current = block;
	const set = shown.set;
	const stored = set.stored;
	$("detail-code").textContent = block.code;
	const parts = [];
	if (block.variants > 1) parts.push(`${block.variants} variants`);
	if (block.alternates > 1) parts.push(`${block.alternates} shapes`);
	if (block.turns > 1) parts.push(`${block.turns} turns`);
	parts.push(`#${block.first}`);
	$("detail-meta").textContent = parts.join(" · ");

	// Every cell the same size, the cube's square at the same place in each.
	let left = 0;
	let top = 0;
	let right = 32;
	let bottom = 32;
	for (let i = block.first; i < block.first + block.count; i++) {
		left = Math.min(left, stored.left[i]);
		top = Math.min(top, stored.top[i]);
		right = Math.max(right, stored.left[i] + stored.width[i]);
		bottom = Math.max(bottom, stored.top[i] + stored.height[i]);
	}
	const scale = fit(right - left, bottom - top);

	const perTurn = block.variants * block.alternates;
	const container = $("detail-pictures");
	container.replaceChildren();
	for (let turn = 0; turn < block.turns; turn++) {
		const row = document.createElement("div");
		row.className = "turn";
		if (block.turns > 1) {
			const label = document.createElement("div");
			label.className = "turn-label";
			label.textContent = `Turn ${turn + 1}`;
			row.append(label);
		}
		const cells = document.createElement("div");
		cells.className = "cells";
		for (let k = 0; k < perTurn; k++) {
			const index = block.first + turn * perTurn + k;
			const variant = k % block.variants;
			const alternate = Math.floor(k / block.variants);
			const cell = document.createElement("div");
			cell.style.position = "relative";
			cell.style.width = (right - left) * scale + "px";
			cell.style.height = (bottom - top) * scale + "px";
			if (block.variants > 1 && alternate > 0 && variant === 0) cell.classList.add("shape-start");
			const canvas = document.createElement("canvas");
			canvas.className = "picture";
			canvas.style.position = "absolute";
			canvas.style.left = (stored.left[index] - left) * scale + "px";
			canvas.style.top = (stored.top[index] - top) * scale + "px";
			canvas.style.width = stored.width[index] * scale + "px";
			canvas.style.height = stored.height[index] * scale + "px";
			drawPicture(canvas, set, index, block.tint);
			const title = [`#${index}`];
			if (block.variants > 1) title.push(`variant ${variant + 1}`);
			if (block.alternates > 1) title.push(`shape ${alternate + 1}`);
			cell.title = title.join(" · ");
			cell.append(canvas);
			cells.append(cell);
		}
		row.append(cells);
		container.append(row);
	}
	container.scrollTop = 0;
	const visible = visibleBlocks();
	const at = visible.indexOf(block);
	$("previous").disabled = at <= 0;
	$("next").disabled = at < 0 || at >= visible.length - 1;
}

function openDetail(block) {
	fillDetail(block);
	if (dialog.open) return;
	dialog.showModal();
	animate(dialog, true, [{ opacity: 0, transform: "translateY(0.625rem) scale(0.98)" }, { opacity: 1, transform: "none" }], { backdrop: true });
}

async function closeDetail() {
	if (!dialog.open || closing) return;
	closing = true;
	await animate(dialog, false, [{ opacity: 0, transform: "translateY(0.625rem) scale(0.98)" }, { opacity: 1, transform: "none" }], { backdrop: true });
	dialog.close();
	closing = false;
	if (current?.tile.isConnected && !current.tile.hidden) current.tile.focus();
}

function step(direction) {
	const visible = visibleBlocks();
	const next = visible[visible.indexOf(current) + direction];
	if (next) fillDetail(next);
}

// Motion: every element that animates in animates out the same way, reversed.

function animate(element, entering, keyframes, { backdrop = false } = {}) {
	if (reducedMotion.matches) return Promise.resolve();
	const frames = entering ? keyframes : [...keyframes].reverse();
	const options = { duration: entering ? 180 : 140, easing: entering ? "cubic-bezier(0.2, 0.8, 0.2, 1)" : "ease-in", fill: "forwards" };
	const animations = [element.animate(frames, options)];
	if (backdrop) {
		const fade = [{ opacity: 0 }, { opacity: 1 }];
		animations.push(element.animate(entering ? fade : fade.reverse(), { ...options, pseudoElement: "::backdrop" }));
	}
	return Promise.all(animations.map((a) => a.finished)).then(
		() => animations.forEach((a) => a.cancel()),
		() => {},
	);
}

const menuFrames = [{ opacity: 0, transform: "translateY(-0.25rem)" }, { opacity: 1, transform: "none" }];

function openMenu() {
	if (menu.matches(":popover-open")) return;
	$("close-set").hidden = !shown;
	menu.showPopover();
	const button = openButton.getBoundingClientRect();
	const right = Math.min(button.right, document.documentElement.clientWidth - 8);
	menu.style.top = button.bottom + 6 + "px";
	menu.style.left = Math.max(8, right - menu.offsetWidth) + "px";
	openButton.setAttribute("aria-expanded", "true");
	animate(menu, true, menuFrames);
	menu.querySelector("button:not([hidden])").focus();
}

async function closeMenu(returnFocus = true) {
	if (!menu.matches(":popover-open") || menu.closing) return;
	menu.closing = true;
	openButton.setAttribute("aria-expanded", "false");
	await animate(menu, false, menuFrames);
	menu.hidePopover();
	menu.closing = false;
	if (returnFocus) openButton.focus();
}

const dropFrames = [{ opacity: 0 }, { opacity: 1 }];
let dragDepth = 0;

function showDrop() {
	if (dropOverlay.matches(":popover-open")) dropOverlay.hidePopover();
	// Shown after any open dialog, so it lies above it in the top layer.
	dropOverlay.showPopover();
	animate(dropOverlay, true, dropFrames);
}

async function hideDrop() {
	if (!dropOverlay.matches(":popover-open")) return;
	await animate(dropOverlay, false, dropFrames);
	if (dragDepth === 0 && dropOverlay.matches(":popover-open")) dropOverlay.hidePopover();
}

const toastFrames = [{ opacity: 0, transform: "translateY(0.5rem)" }, { opacity: 1, transform: "none" }];
let toastTimer = 0;

function toast(message, error = false) {
	clearTimeout(toastTimer);
	if (toastElement.matches(":popover-open")) toastElement.hidePopover();
	toastElement.textContent = message;
	toastElement.classList.toggle("error", error);
	toastElement.showPopover();
	animate(toastElement, true, toastFrames);
	toastTimer = setTimeout(hideToast, error ? 8000 : 4000);
}

async function hideToast() {
	if (!toastElement.matches(":popover-open")) return;
	await animate(toastElement, false, toastFrames);
	toastElement.hidePopover();
}

function formatBytes(bytes) {
	if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
	return `${(bytes / 1024 / 1024).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB`;
}

// Wiring

function pick(action) {
	if (action === "folder") $("pick-folder").click();
	else if (action === "files") $("pick-files").click();
	else if (action === "close") closeSet();
}

openButton.addEventListener("click", () => {
	if (menu.matches(":popover-open")) closeMenu();
	else openMenu();
});
menu.addEventListener("click", (event) => {
	const item = event.target.closest("button");
	if (!item) return;
	closeMenu(false);
	pick(item.dataset.action);
});
menu.addEventListener("keydown", (event) => {
	const items = [...menu.querySelectorAll("button:not([hidden])")];
	const at = items.indexOf(document.activeElement);
	if (event.key === "ArrowDown") items[(at + 1) % items.length].focus();
	else if (event.key === "ArrowUp") items[(at - 1 + items.length) % items.length].focus();
	else if (event.key === "Escape" || event.key === "Tab") closeMenu(event.key === "Escape");
	else return;
	event.preventDefault();
});
document.addEventListener("pointerdown", (event) => {
	if (menu.matches(":popover-open") && !menu.contains(event.target) && !openButton.contains(event.target)) closeMenu(false);
});
$("empty").addEventListener("click", (event) => {
	const button = event.target.closest("[data-action]");
	if (button) pick(button.dataset.action);
});
for (const input of [$("pick-files"), $("pick-folder")]) {
	input.addEventListener("change", () => {
		const files = filesOfInput(input);
		input.value = "";
		if (files.length > 0) open(files);
	});
}

$("search").addEventListener("input", applyFilter);
$("search").addEventListener("keydown", (event) => {
	if (event.key !== "Escape") return;
	if (event.target.value) {
		event.target.value = "";
		applyFilter();
	} else {
		event.target.blur();
	}
});
$("filter").addEventListener("change", applyFilter);
$("zoom").addEventListener("change", (event) => setZoom(Number(event.target.value)));

blocksView.addEventListener("click", (event) => {
	const tile = event.target.closest(".tile");
	if (tile) openDetail(tile.block);
});
$("close").addEventListener("click", closeDetail);
$("previous").addEventListener("click", () => step(-1));
$("next").addEventListener("click", () => step(1));
dialog.addEventListener("cancel", (event) => {
	event.preventDefault();
	closeDetail();
});
dialog.addEventListener("click", (event) => {
	// The dialog has no padding, so a click on the dialog itself is on its backdrop.
	if (event.target === dialog) closeDetail();
});
dialog.addEventListener("keydown", (event) => {
	if (event.key === "ArrowRight") step(1);
	else if (event.key === "ArrowLeft") step(-1);
	else return;
	event.preventDefault();
});

document.addEventListener("keydown", (event) => {
	if (event.key !== "/" || event.ctrlKey || event.metaKey || event.altKey) return;
	if (dialog.open || !shown || event.target.closest?.("input, select, textarea")) return;
	event.preventDefault();
	$("search").focus();
});

// Files dropped anywhere, an open dialog included: drag events reach the window from it too.
const carriesFiles = (event) => event.dataTransfer?.types.includes("Files");
window.addEventListener("dragenter", (event) => {
	if (!carriesFiles(event)) return;
	event.preventDefault();
	if (++dragDepth === 1) showDrop();
});
window.addEventListener("dragover", (event) => {
	if (!carriesFiles(event)) return;
	event.preventDefault();
	event.dataTransfer.dropEffect = "copy";
});
window.addEventListener("dragleave", (event) => {
	if (!carriesFiles(event)) return;
	if (--dragDepth <= 0) {
		dragDepth = 0;
		hideDrop();
	}
});
window.addEventListener("drop", async (event) => {
	if (!carriesFiles(event)) return;
	event.preventDefault();
	dragDepth = 0;
	hideDrop();
	const files = filesOfDrop(event.dataTransfer);
	closeMenu(false);
	closeDetail();
	open(await files);
});

openSaved();
