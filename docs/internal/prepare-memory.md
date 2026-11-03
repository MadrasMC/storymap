# Memory of `storymap prepare`

How the peak memory of `storymap prepare` changed when the prepared blocks moved from a folder of files to one `.storyblk` file, the changes that brought it from 2,385 MiB to 92 MiB, what drawing every rotation added to it, and how that was taken back.

## Measurements

All figures are for preparing Vintage Story 1.22.7 with one mod, Primitive Survival 5.1.4: 14,781 blocks and 55,096 sprites, in a 187 MiB file, on Windows in a ReleaseFast build.
From 4a5c21c on, it's 55,559 sprites in each rotation.

| term | meaning |
| --- | --- |
| private | peak private memory (`PeakPagedMemorySize64`): what the process holds that only it can use |
| working set | peak physical memory in use by the process (`PeakWorkingSet64`), including mapped files |
| reading, drawing, writing | the stages of preparing, the first two taking about 2 s and 5 s, or 21 s for every rotation |

Stage figures were sampled every 20 ms, so they can miss a short spike.
Totals come from the system's own peak counters.
Arena figures come from `queryCapacity` and counting allocators in throwaway builds.

## Results

| commit | change | private | working set |
| --- | --- | --- | --- |
| 5f45caa | folder of files | 505 MiB | 489 MiB |
| 6302c66 | one `.storyblk` file | 2,385 MiB | 1,238 MiB |
| 83bfd70 | sprites drawn into a reserved buffer | 712 MiB | 660 MiB |
| 820d569 | reading's temporary data freed before drawing | 563 MiB | 484 MiB |
| dd06565 | colour maps stored decoded | 560 MiB | 484 MiB |
| 118fc82 | block types read one file at a time | 294 MiB | 258 MiB |
| 8490221 | `storymap prepare` stops after writing | 283 MiB | 249 MiB |
| 1de4ff2 | contents freed before writing | 261 MiB | 250 MiB |
| 4ee9f37 | sprites drawn in place | 261 MiB | 250 MiB |
| 70210be | shape files kept per block type, boxes not duplicated | 261 MiB | 250 MiB |
| d089f5f | sprites drawn into a mapped partial file | 117 MiB | 126 MiB |
| 5f343d6 | per-file arena capped, entries grown outside an arena | 92 MiB | 126 MiB |
| d97fc40 | sprites written from a 1 MiB buffer instead of a mapped window | 92 MiB | 73 MiB |
| 4a5c21c | a cube's north and west faces kept | 99 MiB | 77 MiB |
| 4704e21 | sprite records written in place | 93 MiB | 77 MiB |
| 5ff45ed | each overlay decoded once | 93 MiB | 78 MiB |
| 0519a02 | each image made in place | 93 MiB | 78 MiB |
| 522fb7b | texture colours taken from decoded images | 93 MiB | 78 MiB |
| fe4cb32 | every rotation drawn, identical pixels shared | 116 MiB | 84 MiB |
| b6e58bf | the last four steps merged with every rotation | 119 MiB | 81 MiB |
| f501fc5 | sprite hash table outside the arena, for drawing only | 93 MiB | 79 MiB |

Up to 4a5c21c, reading stayed at about 2 s, and drawing at about 5 s, perhaps 0.2 s slower with the mapped file.
From 83bfd70 on, each step's file was compared byte for byte with the last commit's and matched, apart from colour maps changing format in dd06565, and 8490221, which was compared between `storymap prepare` and a render instead.
The switch itself changed 9,527 of the 55,096 sprites a little, and 57 in size, as the text format rounded boxes and texture coordinates to 1/100,000 and the file keeps them exact: with that rounding put back, every sprite matched byte for byte.

## Folder of files

Before the change, a prepared set was a folder of `blocks.txt`, `textures.bin`, `pictures.bin` and `colormaps/`.
Preparing wrote the text and images, freed everything, then loaded the set again to draw the sprites.
Drawing kept each sprite in an arena and streamed the result to `pictures.bin` through a small buffer.

The folder's format was simple to write in stages: what one stage finished could leave memory before the next began.

## One file

6302c66 replaced the folder with one `prepared.storyblk`.
Sprites are now drawn from the blocks in memory, and every section is handed to the container's writer as one block of bytes, so nothing could be streamed.
That took the peak from 505 MiB to 2,385 MiB.

| arena contents at the peak | size |
| --- | --- |
| everything from reading: JSON, asset files, tables, images, boxes | 502 MiB |
| each sprite's layers, in separate allocations | about 190 MiB |
| `sprite_layers` as one block, the pixels a second time | 185 MiB |
| old copies of that block, and unused arena space | about 1.3 GiB |

The last row was the surprise, and came from how arenas grow:

- `Io.Writer.Allocating` grows a buffer by half each time.
- An arena only reclaims its most recent allocation, and the two section buffers took turns growing, so every old copy stayed.
- Each new arena block is sized at 1.5 times the previous block plus the request, so much of the space was never used.

Private memory reached 2,385 MiB while the working set stayed at 1,238 MiB, because that spare space was committed and never touched.

## Steps

### Reserved buffer

83bfd70 drew each sprite into a 90 KiB scratch buffer and appended it to `sprite_layers`, so the pixels were held once.
`sprite_layers` got its own address range of 4 GiB, the largest a section can be, committed 16 MiB at a time, so it never moved or copied.
The old copies, the unused arena space and the duplicate all went: 2,385 MiB to 712 MiB.

### Temporary arena

820d569 gave `Prepared.prepare` a temporary arena for what only reading needs, freed before drawing, and copied block strings, finished images and boxes into the arena that stays.
Drawing fell to 288 MiB, but reading stayed at 563 MiB and became the peak.

### Decoded colour maps

dd06565 stored colour maps as raw pixels instead of PNGs, 580 KiB instead of 271 KiB.
It's listed for completeness: a render stopped decoding them and reads them in place, and preparing's peak hardly moved.

### Reading one file at a time

The first pass over block types asked for 415 MiB, and the arena held 502 MiB:

| part | size |
| --- | --- |
| block types: 612 files, parsed and expanded | 130 MiB |
| shape files, parsed | 132 MiB |
| other shape work: keys, per-block results, geometries | 153 MiB |
| world properties | 0.2 MiB |

The second pass, reading textures, didn't grow the arena at all, so textures weren't the cause, as first suspected.

118fc82 added `BlockTypes.Reader`, which hands out one block type file's blocks at a time, and a per-file arena reset after each.
`Shapes` was split so per-lookup results went in that arena and only files and geometries lasted.
Reading fell to 252 MiB, and the peak to 294 MiB, now in the last stage.

### Freeing before writing

8490221 split `blocks` so `storymap prepare` stops after writing: its `run` threw away the result of opening the file.
A render that prepares now frees everything before it opens the file.

1de4ff2 moved the encoded sections to their own small arena, so the rest could be freed before the write.
An arena can only be freed whole, so 2.5 MiB of sections had been keeping about 55 MiB of images and boxes alive.

Together these took the peak to 261 MiB, and drawing became the limit: `sprite_layers` and the contents arena were both needed.

### Drawing in place

4ee9f37 removed the scratch buffer: `Sections.add` hands out the sprite's space in `sprite_layers`, and `cubeSprite` and `shapeSprite` write there.
This saved a copy rather than memory, and made the mapped file straightforward.

### Shape files

70210be made two changes:

- Parsed shape files now last only for the block type reading them. A file is needed only for a way of placing it not met yet, as geometries are cached, so re-reading cost nothing measurable.
- `BlockTypes` builds `world.Shape.Box` values directly in the contents arena, where they were built once and then copied.

Reading fell from 252 MiB to 117 MiB.

### Mapped partial file

Drawing still held `sprite_layers` in memory, though it's only ever written out.
d089f5f drew sprites straight into the partial file through a moving 64 MiB window (`FileBuffer`).

| step | what happens |
| --- | --- |
| 1 | `planSprites` works out every run of sprites without drawing |
| 2 | the sprite count gives the `sprites` section's length, and so where `sprite_layers` starts |
| 3 | sprites are drawn into the file through the window |
| 4 | the sections before it are encoded and written |
| 5 | the file is cut to length and renamed |

The block sections' lengths don't depend on the sprites, as their records are of fixed size, so they could be encoded once for their lengths and again for their contents.

Drawing fell from 252 MiB to 64 MiB, which left reading's 117 MiB as the peak.
Working set is 126 MiB, as it includes the mapped window, but those pages are backed by the file and the system can drop them.

### Reading's last 25 MiB

At 117 MiB, three arenas held 114 MiB:

| arena | asked for | held |
| --- | --- | --- |
| contents: images, boxes, entries, strings | 51.3 MiB | 57 MiB |
| reading: tables, geometries, seen codes | 25.8 MiB | 33 MiB |
| per-file, at its largest | 17.3 MiB | 24.3 MiB |

5f343d6 made two changes:

- The per-file arena keeps at most 4 MiB between files. `reset(.retain_capacity)` had kept the 24 MiB of `plant/mushroom.json` for every file after it.
- The block entries grow from `gpa`, which frees old copies.

That reached 92 MiB.

### Buffer instead of a mapping

Mapping the partial file brought platform code: Windows' own mapping calls, to get round `Io.File.MemoryMap` ignoring its offset, and space reserved up front on Linux and macOS, because a full disk stops a program writing to a mapped page.
It saved little in return: one copy of 185 MiB, which takes milliseconds of a 5-second draw, and a mapped window pays for it in page faults.

`FileBuffer` now hands out room in a 1 MiB buffer on the stack, so sprites are still drawn in place, and writes it to the file whenever it's full, about 190 positional writes.
Nothing above `FileBuffer` changed, and the file stayed byte-identical.

| over 6 alternating runs | mapped window | 1 MiB buffer |
| --- | --- | --- |
| private | 92 MiB | 92 MiB |
| working set | 126 MiB | 73 MiB |
| drawing | 4.8 s | 4.7 s |

A full disk is now an ordinary write error on every system.

### Sprite records

The peak had risen to 95–99 MiB by 66c9e18, and it was in drawing: 94 MiB sampled against reading's 84 MiB.
Each sprite's record went on a list that grew as sprites were drawn, and the finished list was copied into the `sprites` section.
The plan already gives the number of sprites, so the list only repeated what was known.

4704e21 sizes the section once, from `plan.count`, and `Sections.add` writes each record in its place.
Drawing and writing fell to 65 MiB.

### Overlays

An overlay is a texture drawn over others, such as an ore over each rock.
Reading decoded overlays 1,601 times for 260 distinct files.

5ff45ed decodes each one the first time and keeps it in the reading arena, about 1 MiB in all.
That saved about 0.2 s of reading, measured in only two undisturbed pairs of runs.

### Images

`Images.make` decoded each texture into the per-file arena, and `Images.index` then copied the finished image to contents.
0519a02 has `make` choose where each step writes, so the last step's image is already in contents.
A plain texture decodes straight there, and one with a half or a turn is written there by that step.

stb's own buffer is still copied once, into that place.
The peak didn't change, as the copies had been short-lived.

### Texture colours

A block's colours were worked out from the PNG, read and decoded apart from its images, so 1,451 of the 1,613 colour textures were decoded twice.

| measure | value |
| --- | --- |
| PNGs read for images | 3,729 |
| PNGs read for colours | 1,613 |
| PNGs read for both | 1,451 |
| time decoding for colours | 86 ms |

522fb7b names a block's colour and grain textures before its images are made.
When `make` decodes one of those files, it takes the colours before crops, overlays and turns change the pixels, and keeps them only for that block.
Decodes for colours fell from 1,613 to 427, which leaves textures with no image, and those whose image was made for another block.

That's a gain of about 0.1 s, too small to measure in these runs.

### Every rotation

The file now holds the isometric view in 4 rotations, 222,236 sprites, of which 83,384 are unique.
Each sprite is hashed as it's drawn, in the buffer, and one seen before is taken back out of it, so pixels still go to the file as they're drawn.
The entries and the table of hashes are sized once, from the plan.

| over 3 alternating runs | one rotation | every rotation |
| --- | --- | --- |
| private | 99 MiB | 116 MiB |
| working set | 77 MiB | 84 MiB |
| drawing | 5.2 s | 21.2 s |
| file | 189.5 MiB | 321.9 MiB |

Reading didn't change, so the 17 MiB is after it: mostly the table of hashes, and the arena block it took (see Sprite hash table).
Without sharing, the pixels alone would be 748 MiB, not 317 MiB.

These two runs used the system's peak counters after the process exited, with both binaries in one folder.

### Merging the steps with every rotation

The steps from 4704e21 to 522fb7b were made beside fe4cb32, and b6e58bf merged them with it.
The `sprites` section is now sized for every rotation and written in place, and sprites share their layers as before.
The file is byte-identical to fe4cb32's.

| memory while writing | fe4cb32 | b6e58bf |
| --- | --- | --- |
| contents arena | 94.3 MiB | 102.4 MiB |
| sections arena | 17.8 MiB | 12.8 MiB |
| other process memory | 3.5 MiB | 3.5 MiB |
| total | 115.6 MiB | 118.7 MiB |
| private | 116 MiB | 119 MiB |

Holding the sprite records once took 5 MiB off the sections arena.
The contents arena grew by 8 MiB, as an arena sizes a new block at 1.5 times its last one plus the request.
On fe4cb32, the records' 3.4 MiB took the new block, and the table of hashes fitted in it.
After the merge, the table's 11 MiB takes it.

Drawing took 21.4–21.8 s on fe4cb32 and 21.3–22.0 s merged.

The peak lasts only for the second encoding, just before the contents arena is freed.
Samples and counters read while the process runs miss it, and showed 103 and 111 MiB.

### Sprite hash table

The table of hashes has 524,288 slots of 21 bytes, 10.5 MiB, as it's sized for every sprite before any are compared.
In the contents arena, it took a block of 45.1 MiB, and about 34 MiB of that was never touched.
That's why private memory stayed at 111 MiB through drawing while the working set was 78 MiB.

f501fc5 allocates the table from `gpa` and frees it when drawing ends, before the second encoding.
The contents arena stays at 57.3 MiB, its size after reading.
`Sections.shareLast` no longer allocates, as all the room is made first.

| over 3 alternating runs | before | after |
| --- | --- | --- |
| private | 118.8 MiB | 93.0–93.1 MiB |
| working set | 80.6 MiB | 78.9–79.0 MiB |
| contents arena after drawing | 102.4 MiB | 57.3 MiB |
| drawing | 21.1–21.4 s | 20.6–21.0 s |

These runs read the peak counters from the process's handle after it exited, so its last moments count.

## Estimates and measurements

Several estimates made along the way were wrong, and measuring settled each one.

| estimate | measured |
| --- | --- |
| the switch added about 190 MiB | it added about 1.9 GiB |
| textures fill reading's arena | they fit in its spare space |
| freeing textures per image is the easy gain | shape files and block types were the cause |
| skipping `open` takes the peak to 252 MiB | 283 MiB: most of the rise was writing |
| freeing contents takes the peak to 252 MiB | 261 MiB: encoding still needs them |
| the mapped file alone takes the peak to about 60–70 MiB | 117 MiB: reading was still higher |
| a few hundred textures are decoded for both colours and images | 1,451 of 1,613 |
| the merge added 8 MiB to the peak | 3 MiB: the earlier counters missed the last moments |
| moving the table of hashes takes the peak to about 85 MiB | 93 MiB: a short spike that samples miss |

## Findings

- **Arenas keep what they replace.** Anything that grows by reallocating should grow outside an arena, or be sized first.
- **Arenas free all at once.** Data with different lifetimes needs different arenas: what's small and needed later can pin everything beside it.
- **Arenas size a new block by the last one.** A large request late in a run can reserve far more than it uses, so it's better allocated on its own.
- **A running process's peak counters can miss its end.** Read them from its handle after it exits.
- **`std.heap.page_allocator` commits on Windows.** A large allocation counts against the commit limit even if never touched.
- **`Allocator.alloc` fills memory in safe builds.** That touches every page of a large allocation; `rawAlloc` doesn't.
- **`Io.File.MemoryMap` ignores its offset on Windows in Zig 0.17.** `createFileMap` passes `null` to `NtMapViewOfSection`.
- **Writing through a buffer can beat mapping.** It needs less code and holds less, and a mapping's page faults cost about what its saved copy does.
- **Renaming over an open or mapped file works on Windows in Zig 0.17.** A render keeps reading its old mapping while a prepare replaces the file.
- **A full disk stops a program writing to a mapped page.** `write` returns an error instead.

## Remaining

The peak is 93 MiB, the same as before every rotation was drawn.
Samples reach only 80–84 MiB, so it's a short spike, probably in reading, but it hasn't been found.
Drawing still takes about 4 times as long, as every sprite is drawn before it can be compared: skipping turned plants, which are mostly other turns of themselves, would save about 30% of the sprites.

Only Windows has run this: Linux and macOS have only been compiled, and only one mod has been tried (`TODO.md`, items 13 and 14).
