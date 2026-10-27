// Shows the sprites in a .storyblk file, Storymap's prepared blocks as spec.md beside this page
// specifies: each block's sprites for the isometric view, tinted by its colour maps.

const MAGIC = "STORYBLK";
const CONTAINER_VERSION = 1;
const HEADER_LENGTH = 24;
// The sections this viewer reads, each with the layout version it reads of it (spec §7). It skips
// any others.
const SECTIONS = new Map([
	["blocks", 1],
	["materials", 1],
	["colour_codes", 1],
	["texture_colours", 1],
	["colour_maps", 1],
	["sprites", 1],
	["sprite_layers", 1],
]);
const TEXTURE_COLOURS_LENGTH = 93;
const SPRITE_LENGTH = 16;
const NONE8 = 0xff;
const NONE32 = 0xffffffff;
// Block flags, and Sprite flags (spec §4).
const SHAPE = 4;
const TINTED = 8;
const SPRITE_TINTED = 1;
const GAMES = new Map([["vintagestory", "Vintage Story"]]);

// A tile's box at 1×, in cube's squares: the square and half as much again around it.
const BOX = 1.5;

// Tinted layers are tinted as at a temperate place at sea level in midsummer (src/vs/Tint.zig).
const TEMPERATURE = 165;
const RAINFALL = 110;
const PROGRESS = 0.5;
const WHITE = [255, 255, 255];

const DATABASE = "storyblk";
const STORE = "files";
const KEY = "current";
// Where this viewer kept a pictures.bin before it read .storyblk files.
const OLD_DATABASE = "storymap-pictures";

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
// A String's text is its bytes as they are: a leading byte order mark is part of it.
const decoder = new TextDecoder("utf-8", { ignoreBOM: true });

const $ = (id) => document.getElementById(id);
const blocksView = $("blocks");
const blockDialog = $("detail");
const fileDialog = $("file");
const menu = $("open-menu");
const openButton = $("open");
const dropOverlay = $("drop");
const toastElement = $("toast");

let shown = null; // { contents, file, box, blocks, groups }
let zoom = 2;
let current = null; // the block open in its dialog
let colourMapURLs = []; // the colour map images the file's details show

// Reading a .storyblk

function rejectFile(what) {
	throw new Error(`This .storyblk is damaged: ${what}.`);
}

// Takes little-endian fields one after another from `at`, rejecting the file at `end`.
class Fields {
	constructor(view, at, end, part) {
		this.view = view;
		this.at = at;
		this.end = end;
		this.part = part;
	}

	// Moves past `length` bytes, returning where they start.
	advance(length) {
		if (length > this.end - this.at) rejectFile(`${this.part} is cut short`);
		const at = this.at;
		this.at += length;
		return at;
	}

	takeU8() {
		return this.view.getUint8(this.advance(1));
	}

	takeU16() {
		return this.view.getUint16(this.advance(2), true);
	}

	takeU32() {
		return this.view.getUint32(this.advance(4), true);
	}

	// Past what a number holds exactly, Infinity, which lies past any file.
	takeU64() {
		const value = this.view.getBigUint64(this.advance(8), true);
		return value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : Infinity;
	}

	takeBytes(length) {
		return new Uint8Array(this.view.buffer, this.advance(length), length);
	}

	takeString() {
		return decoder.decode(this.takeBytes(this.takeU16()));
	}

	takeStrings() {
		const out = [];
		for (let n = this.takeU8(); n > 0; n--) out.push(this.takeString());
		return out;
	}
}

// The file's sections this viewer reads, checked as spec §5 says.
function parse(buffer) {
	const view = new DataView(buffer);
	if (buffer.byteLength < HEADER_LENGTH || decoder.decode(new Uint8Array(buffer, 0, 8)) !== MAGIC) throw new Error("This isn't a .storyblk file.");
	const version = view.getUint8(8);
	if (version !== CONTAINER_VERSION) throw new Error(`This .storyblk is container version ${version}, which this viewer doesn't read.`);
	const sectionCount = view.getUint16(10, true);
	const infoLength = view.getUint32(12, true);
	if (infoLength > buffer.byteLength - HEADER_LENGTH) rejectFile("its info is cut short");

	const info = new Fields(view, HEADER_LENGTH, HEADER_LENGTH + infoLength, "its info");
	const game = info.takeString();
	const gameVersion = info.takeString();
	const mods = [];
	for (let n = info.takeU16(); n > 0; n--) mods.push({ file: info.takeString(), id: info.takeString(), name: info.takeString(), version: info.takeString() });

	const table = new Fields(view, HEADER_LENGTH + infoLength, buffer.byteLength, "its section table");
	const listed = [];
	for (let n = 0; n < sectionCount; n++) {
		listed.push({ offset: table.takeU64(), length: table.takeU32(), layoutVersion: table.takeU8(), generatorVersion: table.takeU16(), name: table.takeString() });
	}
	const isInPlace = (section) => section.offset >= table.at && section.offset % 8 === 0 && section.length <= buffer.byteLength - section.offset;
	const sections = new Map();
	for (const section of listed) {
		const layout = SECTIONS.get(section.name);
		if (layout === undefined) continue;
		if (sections.has(section.name)) rejectFile(`it has two ${section.name} sections`);
		if (section.layoutVersion !== layout) throw new Error(`This .storyblk's ${section.name} section is layout version ${section.layoutVersion}, which this viewer doesn't read.`);
		if (!isInPlace(section)) rejectFile(`its ${section.name} section isn't where its table says`);
		sections.set(section.name, section);
	}
	for (const name of SECTIONS.keys()) if (!sections.has(name)) rejectFile(`it has no ${name} section`);
	const openSection = (name) => {
		const section = sections.get(name);
		return new Fields(view, section.offset, section.offset + section.length, `its ${name} section`);
	};

	const materials = openSection("materials").takeStrings();
	const colourCodes = openSection("colour_codes").takeStrings();

	const textures = openSection("texture_colours");
	const textureCount = textures.takeU32();
	if (sections.get("texture_colours").length !== 4 + TEXTURE_COLOURS_LENGTH * textureCount) rejectFile("its texture_colours section isn't the length its count gives");
	const textureColours = textures.takeBytes(TEXTURE_COLOURS_LENGTH * textureCount);

	const maps = openSection("colour_maps");
	const colourMaps = [];
	for (let n = maps.takeU8(); n > 0; n--) {
		const code = maps.takeString();
		const padding = maps.takeU8();
		const flags = maps.takeU8();
		colourMaps.push({ code, padding, tropical: (flags & 1) !== 0, image: maps.takeBytes(maps.takeU32()) });
	}

	const spriteSection = sections.get("sprites");
	const spriteFields = openSection("sprites");
	const spriteCount = spriteFields.takeU32();
	const blockWidth = spriteFields.takeU16();
	if (spriteSection.length !== 8 + SPRITE_LENGTH * spriteCount) rejectFile("its sprites section isn't the length its count gives");
	const layerSection = sections.get("sprite_layers");
	const sprites = {
		count: spriteCount,
		offset: new Uint32Array(spriteCount),
		left: new Int16Array(spriteCount),
		top: new Int16Array(spriteCount),
		width: new Uint16Array(spriteCount),
		height: new Uint16Array(spriteCount),
		flags: new Uint32Array(spriteCount),
	};
	for (let i = 0; i < spriteCount; i++) {
		const at = spriteSection.offset + 8 + i * SPRITE_LENGTH;
		const offset = view.getUint32(at, true);
		const width = view.getUint16(at + 8, true);
		const height = view.getUint16(at + 10, true);
		const flags = view.getUint32(at + 12, true);
		const pixels = width * height;
		const length = pixels * (flags & SPRITE_TINTED ? 8 : 4) + Math.ceil((pixels * 2) / 4) * 4;
		if (offset % 4 !== 0) rejectFile(`sprite ${i}'s layers don't start on a multiple of 4`);
		if (offset + length > layerSection.length) rejectFile(`sprite ${i} goes past the end of its sprite_layers section`);
		sprites.offset[i] = offset;
		sprites.left[i] = view.getInt16(at + 4, true);
		sprites.top[i] = view.getInt16(at + 6, true);
		sprites.width[i] = width;
		sprites.height[i] = height;
		sprites.flags[i] = flags;
	}

	const blockFields = openSection("blocks");
	const blocks = [];
	const isOutside = (value, count, none) => value !== none && value >= count;
	for (let index = 0, count = blockFields.takeU32(); index < count; index++) {
		const block = {
			index,
			code: blockFields.takeString(),
			material: blockFields.takeU8(),
			colourCode: blockFields.takeU8(),
			colour: blockFields.takeU32(),
			grain: blockFields.takeU32(),
			climateColourMap: blockFields.takeU8(),
			seasonColourMap: blockFields.takeU8(),
			height: blockFields.takeU8(),
			drawOffset: blockFields.takeU8(),
			flags: blockFields.takeU8(),
			first: blockFields.takeU32(),
			variants: blockFields.takeU16(),
			alternates: blockFields.takeU16(),
			turns: blockFields.takeU8(),
		};
		if (
			block.material >= materials.length ||
			block.colourCode >= colourCodes.length ||
			isOutside(block.colour, textureCount, NONE32) ||
			isOutside(block.grain, textureCount, NONE32) ||
			isOutside(block.climateColourMap, colourMaps.length, NONE8) ||
			isOutside(block.seasonColourMap, colourMaps.length, NONE8)
		) {
			rejectFile(`block ${index} names an entry its tables don't have`);
		}
		if (block.variants > 0 && (block.alternates === 0 || block.turns === 0)) rejectFile(`block ${index} has variants but no shapes or turns`);
		block.count = block.variants * block.alternates * block.turns;
		if (block.count > 0 && block.first + block.count > spriteCount) rejectFile(`block ${index}'s sprites go past the last sprite`);
		blocks.push(block);
	}

	// Domains aren't needed to show sprites, only to list in the file's details: read when they can
	// be, and left out when they can't.
	const domainSections = listed.filter((section) => section.name === "domains");
	let domains = null;
	if (domainSections.length === 1 && domainSections[0].layoutVersion === 1 && isInPlace(domainSections[0])) {
		const section = domainSections[0];
		try {
			const fields = new Fields(view, section.offset, section.offset + section.length, "its domains section");
			domains = [];
			for (let n = fields.takeU16(); n > 0; n--) domains.push(fields.takeString());
		} catch {
			domains = null;
		}
	}

	return {
		version,
		hash: view.getBigUint64(16, true),
		sections: listed,
		game,
		gameVersion,
		mods,
		domains,
		materials,
		colourCodes,
		textureColours,
		colourMaps,
		blockWidth,
		sprites,
		layers: new Uint8Array(buffer, layerSection.offset, layerSection.length),
		blocks,
	};
}

// Sprite `index`, its tinted layer tinted by `tint`, drawn over its plain one as the renderer
// blends them (isometric.blend).
function drawSprite(canvas, contents, index, tint) {
	const sprites = contents.sprites;
	const width = sprites.width[index];
	const height = sprites.height[index];
	canvas.width = width;
	canvas.height = height;
	if (width === 0 || height === 0) return;
	const pixels = width * height;
	const at = sprites.offset[index];
	const plain = contents.layers.subarray(at, at + pixels * 4);
	const image = new ImageData(width, height);
	const out = image.data;
	out.set(plain);
	if (sprites.flags[index] & SPRITE_TINTED) {
		const layer = contents.layers.subarray(at + pixels * 4, at + pixels * 8);
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

// Tints

let pixelReader = null;

// The bitmap's pixels as its PNG holds them, as the renderer reads them (src/vs/Tint.zig): a 2D
// canvas would multiply their colours by their alpha. WebGL reads them unchanged.
function readPixels(bitmap) {
	const { width, height } = bitmap;
	pixelReader ??= new OffscreenCanvas(1, 1).getContext("webgl");
	const gl = pixelReader;
	if (!gl) {
		const context = new OffscreenCanvas(width, height).getContext("2d");
		context.drawImage(bitmap, 0, 0);
		return context.getImageData(0, 0, width, height).data;
	}
	const texture = gl.createTexture();
	gl.bindTexture(gl.TEXTURE_2D, texture);
	gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
	gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
	gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
	const framebuffer = gl.createFramebuffer();
	gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
	gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
	const pixels = new Uint8Array(width * height * 4);
	gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
	gl.bindFramebuffer(gl.FRAMEBUFFER, null);
	gl.deleteFramebuffer(framebuffer);
	gl.deleteTexture(texture);
	return pixels;
}

async function decodeColourMap(map) {
	const png = new Blob([map.image], { type: "image/png" });
	const bitmap = await createImageBitmap(png, { premultiplyAlpha: "none", colorSpaceConversion: "none" });
	const { width, height } = bitmap;
	const pixels = readPixels(bitmap);
	bitmap.close();
	if (width <= 2 * map.padding || height <= 2 * map.padding) return null;
	return { width, height, pixels, padding: map.padding, tropical: map.tropical };
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

// Gives each block its tint: white for one without colour maps, as the renderer leaves it.
async function tintBlocks(contents) {
	const maps = await Promise.all(contents.colourMaps.map((map) => decodeColourMap(map).catch(() => null)));
	// Null for a map that can't tint: one that can't be decoded, or is no wider or taller than twice
	// its padding.
	contents.colourMaps.forEach((map, i) => (map.size = maps[i] ? [maps[i].width, maps[i].height] : null));
	const byPair = new Map();
	for (const block of contents.blocks) {
		const pair = block.climateColourMap * 256 + block.seasonColourMap;
		let colour = byPair.get(pair);
		if (!colour) {
			const climate = block.climateColourMap === NONE8 ? null : maps[block.climateColourMap];
			const season = block.seasonColourMap === NONE8 ? null : maps[block.seasonColourMap];
			colour = climate || season ? tint(climate, season) : WHITE;
			byPair.set(pair, colour);
		}
		block.tint = colour;
	}
}

// Choosing what to open

// The newest .storyblk among what was dropped or chosen; a single file of another name is tried
// as one.
function choose(files) {
	const found = files.filter((f) => f.path.toLowerCase().endsWith(".storyblk"));
	if (found.length === 0 && files.length === 1) return files[0].file;
	if (found.length === 0) throw new Error("There's no .storyblk in what was opened.");
	found.sort((a, b) => b.file.lastModified - a.file.lastModified);
	return found[0].file;
}

async function filesOfDrop(dataTransfer) {
	// Entries must be taken while the drop event runs: the data transfer empties after it.
	const entries = [...dataTransfer.items].filter((item) => item.kind === "file").map((item) => item.webkitGetAsEntry?.()).filter(Boolean);
	if (entries.length === 0) return [...dataTransfer.files].map((file) => ({ path: file.name, file }));
	const files = [];
	await Promise.all(entries.map((entry) => collect(entry, files, true)));
	return files;
}

// Adds a dropped file, or a dropped folder's own files but not its subfolders': a render's tiles
// can lie beside the .storyblk.
async function collect(entry, files, descend) {
	if (entry.isFile) {
		const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
		files.push({ path: entry.fullPath.replace(/^\//, ""), file });
		return;
	}
	if (!entry.isDirectory || !descend) return;
	const reader = entry.createReader();
	for (;;) {
		const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
		if (batch.length === 0) break;
		await Promise.all(batch.map((child) => collect(child, files, false)));
	}
}

// Opening

async function read(file) {
	const contents = parse(await file.arrayBuffer());
	await tintBlocks(contents);
	return contents;
}

async function open(files) {
	let file;
	try {
		file = choose(files);
	} catch (error) {
		toast(error.message, true);
		return;
	}
	showLoading(`Reading ${file.name}`, formatBytes(file.size));
	try {
		show(await read(file), file);
		try {
			await save(file);
		} catch (error) {
			// Or the file this one replaced would come back next time.
			forget().catch(() => {});
			toast(`It couldn't be kept for next time: ${error.message}`, true);
		}
	} catch (error) {
		restoreView();
		toast(error.message, true);
	}
}

async function openSaved() {
	let file;
	try {
		file = await load();
	} catch {
		file = null;
	}
	if (!(file instanceof Blob)) {
		showEmpty();
		return;
	}
	showLoading(`Opening ${file.name}`, formatBytes(file.size));
	try {
		show(await read(file), file);
	} catch (error) {
		showEmpty();
		toast(`The saved .storyblk can't be read: ${error.message}`, true);
		forget().catch(() => {});
	}
}

async function closeFile() {
	shown = null;
	for (const url of colourMapURLs) URL.revokeObjectURL(url);
	colourMapURLs = [];
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

const save = (file) => transact("readwrite", (store) => store.put(file, KEY));
const load = () => transact("readonly", (store) => store.get(KEY));
const forget = () => transact("readwrite", (store) => store.delete(KEY));

// Views

function showEmpty() {
	document.body.classList.add("empty");
	$("file-label").replaceChildren();
	$("file-name").hidden = true;
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

function nameGame(contents) {
	return GAMES.get(contents.game) ?? contents.game;
}

// The file's name in bold, then its game and how many mods.
function describeFile(contents, file) {
	const parts = [[nameGame(contents), contents.gameVersion].filter(Boolean).join(" ")];
	if (contents.mods.length > 0) parts.push(`${contents.mods.length.toLocaleString("en")} ${contents.mods.length === 1 ? "mod" : "mods"}`);
	const rest = parts.filter(Boolean).join(" · ");
	return [make("b", "", file.name), ...(rest ? [" · " + rest] : [])];
}

function showBlocks() {
	document.body.classList.remove("empty");
	$("file-label").replaceChildren(...describeFile(shown.contents, shown.file));
	$("file-name").hidden = false;
	$("empty").hidden = true;
	$("loading").hidden = true;
	blocksView.hidden = false;
}

function describe(contents) {
	const blocks = [];
	for (const block of contents.blocks) {
		if (block.variants === 0) continue;
		const colon = block.code.indexOf(":");
		const domain = colon < 0 ? "" : block.code.slice(0, colon + 1);
		const name = block.code.slice(colon + 1);
		const dash = name.indexOf("-");
		block.group = domain + (dash < 0 ? name : name.slice(0, dash));
		block.label = dash < 0 ? name : name.slice(dash + 1);
		block.search = block.code.toLowerCase() + " #" + block.index;
		blocks.push(block);
	}
	return blocks;
}

const tileObserver = new IntersectionObserver(
	(entries) => {
		for (const entry of entries) {
			if (!entry.isIntersecting) continue;
			tileObserver.unobserve(entry.target);
			const block = entry.target.block;
			drawSprite(block.canvas, shown.contents, block.first, block.tint);
		}
	},
	{ rootMargin: "800px 0px" },
);

function fit(width, height) {
	return Math.max(1, Math.min(zoom, Math.floor((shown.box * zoom) / Math.max(width, height, 1))));
}

function sizeTile(block) {
	const sprites = shown.contents.sprites;
	const width = sprites.width[block.first];
	const height = sprites.height[block.first];
	const scale = fit(width, height);
	block.canvas.style.width = width * scale + "px";
	block.canvas.style.height = height * scale + "px";
}

function show(contents, file) {
	tileObserver.disconnect();
	shown = { contents, file, box: Math.round(contents.blockWidth * BOX), blocks: describe(contents), groups: [] };
	document.documentElement.style.setProperty("--box", shown.box * zoom + "px");
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
	block.canvas.className = "sprite";
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
	shape: (b) => (b.flags & SHAPE) !== 0,
	alternates: (b) => b.alternates > 1,
	turns: (b) => b.turns > 1,
	variants: (b) => b.variants > 1,
	tinted: (b) => (b.flags & TINTED) !== 0,
};

function applyFilter() {
	if (!shown) return;
	const text = $("search").value.trim().toLowerCase();
	const filter = filters[$("filter").value];
	let blockCount = 0;
	let spriteCount = 0;
	// Blocks drawn alike share their sprites, which count once.
	const counted = new Uint8Array(shown.contents.sprites.count);
	for (const group of shown.groups) {
		let inGroup = 0;
		for (const block of group.blocks) {
			const visible = filter(block) && (!text || block.search.includes(text));
			block.tile.hidden = !visible;
			if (!visible) continue;
			inGroup++;
			for (let i = block.first; i < block.first + block.count; i++) {
				spriteCount += 1 - counted[i];
				counted[i] = 1;
			}
		}
		group.section.hidden = inGroup === 0;
		group.count.textContent = inGroup.toLocaleString("en");
		blockCount += inGroup;
	}
	const blocks = document.createElement("span");
	blocks.textContent = `${blockCount.toLocaleString("en")} blocks`;
	const sprites = document.createElement("span");
	sprites.textContent = `${spriteCount.toLocaleString("en")} sprites`;
	$("count").replaceChildren(blocks, sprites);
}

function setZoom(value) {
	zoom = value;
	if (!shown) return;
	document.documentElement.style.setProperty("--box", shown.box * zoom + "px");
	for (const block of shown.blocks) sizeTile(block);
	if (blockDialog.open) fillDetail(current);
}

// Detail

// The blocks the filter shows, in the order the page shows them: group by group, by name.
function visibleBlocks() {
	return shown.groups.filter((group) => !group.section.hidden).flatMap((group) => group.blocks.filter((block) => !block.tile.hidden));
}

function formatHex(bytes) {
	return "#" + [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function fillDetail(block) {
	current = block;
	const contents = shown.contents;
	const sprites = contents.sprites;
	$("detail-code").textContent = block.code;
	const meta = [];
	const addItem = (text) => {
		const span = document.createElement("span");
		span.textContent = text;
		meta.push(span);
		return span;
	};
	if (block.variants > 1) addItem(`${block.variants} variants`);
	if (block.alternates > 1) addItem(`${block.alternates} shapes`);
	if (block.turns > 1) addItem(`${block.turns} turns`);
	const material = addItem(contents.materials[block.material]);
	if (block.colour !== NONE32) {
		const at = block.colour * TEXTURE_COLOURS_LENGTH;
		const colour = formatHex(contents.textureColours.subarray(at, at + 3));
		const swatch = document.createElement("i");
		swatch.className = "swatch";
		swatch.style.background = colour;
		swatch.title = colour;
		material.prepend(swatch);
	}
	addItem(contents.colourCodes[block.colourCode]);
	addItem(`#${block.first}`);
	$("detail-meta").replaceChildren(...meta);

	// Every cell the same size, just around all of the block's sprites, each where it lies against
	// the cube's square; the square itself for a block whose sprites are all empty.
	let left = Infinity;
	let top = Infinity;
	let right = -Infinity;
	let bottom = -Infinity;
	for (let i = block.first; i < block.first + block.count; i++) {
		if (sprites.width[i] === 0 || sprites.height[i] === 0) continue;
		left = Math.min(left, sprites.left[i]);
		top = Math.min(top, sprites.top[i]);
		right = Math.max(right, sprites.left[i] + sprites.width[i]);
		bottom = Math.max(bottom, sprites.top[i] + sprites.height[i]);
	}
	if (left === Infinity) [left, top, right, bottom] = [0, 0, contents.blockWidth, contents.blockWidth];
	const scale = fit(right - left, bottom - top);

	const perTurn = block.variants * block.alternates;
	const container = $("detail-sprites");
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
			canvas.className = "sprite";
			canvas.style.position = "absolute";
			canvas.style.left = (sprites.left[index] - left) * scale + "px";
			canvas.style.top = (sprites.top[index] - top) * scale + "px";
			canvas.style.width = sprites.width[index] * scale + "px";
			canvas.style.height = sprites.height[index] * scale + "px";
			drawSprite(canvas, contents, index, block.tint);
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
	openModal(blockDialog);
}

async function closeDetail() {
	if (!(await closeModal(blockDialog))) return;
	if (current?.tile.isConnected && !current.tile.hidden) current.tile.focus();
}

// The file's details

function make(tag, className, ...children) {
	const node = document.createElement(tag);
	if (className) node.className = className;
	node.append(...children);
	return node;
}

function makeSection(title, ...content) {
	return make("section", "facts", make("h3", "", title), ...content);
}

function makePairs(pairs) {
	return make("dl", "pairs", ...pairs.flatMap(([term, value]) => [make("dt", "", term), make("dd", "", String(value))]));
}

// A table of `rows`, its columns from `numeric` on aligned right; rows with `muted` set are greyed.
function makeTable(headers, rows, numeric) {
	const cell = (tag, text, i) => make(tag, i >= numeric ? "number" : "", String(text));
	const head = make("thead", "", make("tr", "", ...headers.map((text, i) => cell("th", text, i))));
	const body = make("tbody", "", ...rows.map((row) => make("tr", row.muted ? "muted" : "", ...row.cells.map((text, i) => cell("td", text, i)))));
	return make("div", "table", make("table", "", head, body));
}

function makeNames(names) {
	return names.length > 0 ? make("p", "names", ...names.map((name) => make("span", "", name))) : make("p", "names", "–");
}

function formatCount(count) {
	return count === null || count === undefined ? "–" : count.toLocaleString("en");
}

function fillFileDetails() {
	const { contents, file } = shown;
	for (const url of colourMapURLs) URL.revokeObjectURL(url);
	colourMapURLs = [];
	$("file-title").textContent = file.name;

	const counts = new Map([
		["blocks", contents.blocks.length],
		["materials", contents.materials.length],
		["colour_codes", contents.colourCodes.length],
		["texture_colours", contents.textureColours.length / TEXTURE_COLOURS_LENGTH],
		["colour_maps", contents.colourMaps.length],
		["domains", contents.domains?.length],
		["sprites", contents.sprites.count],
	]);
	const isRead = (name) => SECTIONS.has(name) || (name === "domains" && contents.domains !== null);
	const sections = contents.sections.map((section) => ({
		muted: !isRead(section.name),
		cells: [section.name, formatCount(isRead(section.name) ? counts.get(section.name) : null), formatCount(section.offset), formatCount(section.length), section.layoutVersion, section.generatorVersion],
	}));

	const blocks = contents.blocks;
	let tintedSprites = 0;
	for (let i = 0; i < contents.sprites.count; i++) if (contents.sprites.flags[i] & SPRITE_TINTED) tintedSprites++;

	const maps = contents.colourMaps.map((map) => {
		const url = URL.createObjectURL(new Blob([map.image], { type: "image/png" }));
		colourMapURLs.push(url);
		const image = make("img", "");
		image.src = url;
		image.alt = "";
		const facts = map.size ? [`${map.size[0]} × ${map.size[1]}`, `padding ${map.padding}`] : ["can't tint"];
		if (map.tropical) facts.push("tropical");
		return make("figure", "colour-map", make("div", "colour-map-image", image), make("figcaption", "", make("code", "", map.code), make("span", "", facts.join(" · "))));
	});

	$("file-body").replaceChildren(
		makeSection(
			"File",
			makePairs([
				["Size", `${formatBytes(file.size)} (${formatCount(file.size)} bytes)`],
				["Container version", contents.version],
				["Hash", contents.hash.toString(16).padStart(16, "0")],
				["Game", [nameGame(contents), contents.gameVersion].filter(Boolean).join(" ") || "–"],
			]),
		),
		makeSection("Sections", makeTable(["Section", "Count", "Offset", "Length", "Layout version", "Generator version"], sections, 1)),
		makeSection(
			"Blocks",
			makePairs([
				["With sprites", formatCount(blocks.filter((b) => b.variants > 0).length)],
				["In shapes", formatCount(blocks.filter((b) => b.flags & SHAPE).length)],
				["Tinted", formatCount(blocks.filter((b) => b.flags & TINTED).length)],
				["Turned", formatCount(blocks.filter((b) => b.turns > 1).length)],
			]),
		),
		makeSection(
			"Sprites",
			makePairs([
				["Block width", `${contents.blockWidth} px`],
				["Tinted", formatCount(tintedSprites)],
				["Layers", formatBytes(contents.layers.length)],
			]),
		),
		makeSection(
			"Mods",
			contents.mods.length > 0
				? makeTable(["File", "ID", "Name", "Version"], contents.mods.map((mod) => ({ cells: [mod.file, mod.id || "–", mod.name || "–", mod.version || "–"] })), 4)
				: make("p", "names", "–"),
		),
		makeSection("Materials", makeNames(contents.materials)),
		makeSection("Colour codes", makeNames(contents.colourCodes)),
		makeSection("Domains", makeNames(contents.domains ?? [])),
		makeSection("Colour maps", make("div", "colour-maps", ...maps)),
	);
	$("file-body").scrollTop = 0;
}

function openFileDetails() {
	if (!shown) return;
	fillFileDetails();
	openModal(fileDialog);
}

async function closeFileDetails() {
	if (await closeModal(fileDialog)) $("file-name").focus();
}

// Dialogs

// On phones, dialogs are sheets from the bottom (style.css), and slide up from it.
const phone = matchMedia("(max-width: 47.99rem)");
const dialogFrames = [{ opacity: 0, transform: "translateY(0.625rem) scale(0.98)" }, { opacity: 1, transform: "none" }];
const sheetFrames = [{ transform: "translateY(100%)" }, { transform: "none" }];

function openModal(modal) {
	if (modal.open) return;
	modal.showModal();
	animate(modal, true, phone.matches ? sheetFrames : dialogFrames, { backdrop: true });
}

// Whether it closed: false if it wasn't open or was already closing.
async function closeModal(modal) {
	if (!modal.open || modal.closing) return false;
	modal.closing = true;
	await animate(modal, false, phone.matches ? sheetFrames : dialogFrames, { backdrop: true });
	modal.close();
	modal.closing = false;
	return true;
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
	$("close-file").hidden = !shown;
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
	if (action === "file") $("pick-file").click();
	else if (action === "close") closeFile();
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
$("pick-file").addEventListener("change", (event) => {
	const input = event.target;
	const files = [...input.files].map((file) => ({ path: file.name, file }));
	input.value = "";
	if (files.length > 0) open(files);
});

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
$("zoom").addEventListener("click", (event) => {
	const button = event.target.closest("button");
	if (!button) return;
	for (const each of $("zoom").querySelectorAll("button")) each.setAttribute("aria-pressed", String(each === button));
	setZoom(Number(button.dataset.zoom));
});

blocksView.addEventListener("click", (event) => {
	const tile = event.target.closest(".tile");
	if (tile) openDetail(tile.block);
});
$("close").addEventListener("click", closeDetail);
$("previous").addEventListener("click", () => step(-1));
$("next").addEventListener("click", () => step(1));
blockDialog.addEventListener("keydown", (event) => {
	if (event.key === "ArrowRight") step(1);
	else if (event.key === "ArrowLeft") step(-1);
	else return;
	event.preventDefault();
});
$("file-name").addEventListener("click", openFileDetails);
$("file-close").addEventListener("click", closeFileDetails);
for (const [modal, close] of [
	[blockDialog, closeDetail],
	[fileDialog, closeFileDetails],
]) {
	modal.addEventListener("cancel", (event) => {
		event.preventDefault();
		close();
	});
	modal.addEventListener("click", (event) => {
		// The dialog has no padding, so a click on the dialog itself is on its backdrop.
		if (event.target === modal) close();
	});
}

document.addEventListener("keydown", (event) => {
	if (event.key !== "/" || event.ctrlKey || event.metaKey || event.altKey) return;
	if (blockDialog.open || fileDialog.open || !shown || event.target.closest?.("input, select, textarea")) return;
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
	closeModal(fileDialog);
	open(await files);
});

try {
	indexedDB.deleteDatabase(OLD_DATABASE);
} catch {}
openSaved();
