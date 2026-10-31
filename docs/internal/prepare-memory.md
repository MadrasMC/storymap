# Memory of `storymap prepare`

How the peak memory of `storymap prepare` changed when the prepared blocks moved from a folder of files to one `.storyblk` file, and the changes that brought it from 2,385 MB to 92 MB.

## Measurements

All figures are for preparing Vintage Story 1.22.7 with one mod, Primitive Survival 5.1.4: 14,781 blocks and 55,096 sprites, in a 196 MB file, on Windows in a ReleaseFast build.

| term | meaning |
| --- | --- |
| private | peak private memory (`PeakPagedMemorySize64`): what the process holds that only it can use |
| working set | peak physical memory in use by the process (`PeakWorkingSet64`), including mapped files |
| reading, drawing, writing | the stages of preparing, the first two taking about 2 s and 5 s |

Stage figures were sampled every 20 ms, so they can miss a short spike.
Totals come from the system's own peak counters.
Arena figures come from `queryCapacity` and counting allocators in throwaway builds.

## Results

| commit | change | private | working set |
| --- | --- | --- | --- |
| 5f45caa | folder of files | 505 MB | 489 MB |
| 6302c66 | one `.storyblk` file | 2,385 MB | 1,238 MB |
| 83bfd70 | sprites drawn into a reserved buffer | 712 MB | 660 MB |
| 820d569 | reading's temporary data freed before drawing | 563 MB | 484 MB |
| dd06565 | colour maps stored decoded | 560 MB | 484 MB |
| 118fc82 | block types read one file at a time | 294 MB | 258 MB |
| 8490221 | `storymap prepare` stops after writing | 283 MB | 249 MB |
| 1de4ff2 | contents freed before writing | 261 MB | 250 MB |
| 4ee9f37 | sprites drawn in place | 261 MB | 250 MB |
| 70210be | shape files kept per block type, boxes not duplicated | 261 MB | 250 MB |
| d089f5f | sprites drawn into a mapped partial file | 117 MB | 126 MB |
| 5f343d6 | per-file arena capped, entries grown outside an arena | 92 MB | 126 MB |

Reading stayed at about 2 s throughout, and drawing at about 5 s, perhaps 0.2 s slower with the mapped file.
From 83bfd70 on, each step's file was compared byte for byte with the last commit's and matched, apart from colour maps changing format in dd06565, and 8490221, which was compared between `storymap prepare` and a render instead.

## Folder of files

Before the change, a prepared set was a folder of `blocks.txt`, `textures.bin`, `pictures.bin` and `colormaps/`.
Preparing wrote the text and images, freed everything, then loaded the set again to draw the sprites.
Drawing kept each sprite in an arena and streamed the result to `pictures.bin` through a small buffer.

The folder's format was simple to write in stages: what one stage finished could leave memory before the next began.

## One file

6302c66 replaced the folder with one `prepared.storyblk`.
Sprites are now drawn from the blocks in memory, and every section is handed to the container's writer as one block of bytes, so nothing could be streamed.
That took the peak from 505 MB to 2,385 MB.

| arena contents at the peak | size |
| --- | --- |
| everything from reading: JSON, asset files, tables, images, boxes | 502 MB |
| each sprite's layers, in separate allocations | about 190 MB |
| `sprite_layers` as one block, the pixels a second time | 193 MB |
| old copies of that block, and unused arena space | about 1.3 GB |

The last row was the surprise, and came from how arenas grow:

- `Io.Writer.Allocating` grows a buffer by half each time.
- An arena only reclaims its most recent allocation, and the two section buffers took turns growing, so every old copy stayed.
- Each new arena block is sized at 1.5 times the previous block plus the request, so much of the space was never used.

Private memory reached 2,385 MB while the working set stayed at 1,238 MB, because that spare space was committed and never touched.

## Steps

### Reserved buffer

83bfd70 drew each sprite into a 92 KB scratch buffer and appended it to `sprite_layers`, so the pixels were held once.
`sprite_layers` got its own address range of 4 GiB, the largest a section can be, committed 16 MiB at a time, so it never moved or copied.
The old copies, the unused arena space and the duplicate all went: 2,385 MB to 712 MB.

### Temporary arena

820d569 gave `Prepared.prepare` a temporary arena for what only reading needs, freed before drawing, and copied block strings, finished images and boxes into the arena that stays.
Drawing fell to 288 MB, but reading stayed at 563 MB and became the peak.

### Decoded colour maps

dd06565 stored colour maps as raw pixels instead of PNGs, 594 KB instead of 277 KB.
It's listed for completeness: a render stopped decoding them and reads them in place, and preparing's peak hardly moved.

### Reading one file at a time

The first pass over block types asked for 415 MB, and the arena held 502 MB:

| part | size |
| --- | --- |
| block types: 612 files, parsed and expanded | 130 MB |
| shape files, parsed | 132 MB |
| other shape work: keys, per-block results, geometries | 153 MB |
| world properties | 0.2 MB |

The second pass, reading textures, didn't grow the arena at all, so textures weren't the cause, as first suspected.

118fc82 added `BlockTypes.Reader`, which hands out one block type file's blocks at a time, and a per-file arena reset after each.
`Shapes` was split so per-lookup results went in that arena and only files and geometries lasted.
Reading fell to 252 MB, and the peak to 294 MB, now in the last stage.

### Freeing before writing

8490221 split `blocks` so `storymap prepare` stops after writing: its `run` threw away the result of opening the file.
A render that prepares now frees everything before it opens the file.

1de4ff2 moved the encoded sections to their own small arena, so the rest could be freed before the write.
An arena can only be freed whole, so 2.5 MB of sections had been keeping about 55 MB of images and boxes alive.

Together these took the peak to 261 MB, and drawing became the limit: `sprite_layers` and the contents arena were both needed.

### Drawing in place

4ee9f37 removed the scratch buffer: `Sections.add` hands out the sprite's space in `sprite_layers`, and `cubeSprite` and `shapeSprite` write there.
This saved a copy rather than memory, and made the mapped file straightforward.

### Shape files

70210be made two changes:

- Parsed shape files now last only for the block type reading them. A file is needed only for a way of placing it not met yet, as geometries are cached, so re-reading cost nothing measurable.
- `BlockTypes` builds `world.Shape.Box` values directly in the contents arena, where they were built once and then copied.

Reading fell from 252 MB to 117 MB.

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

Drawing fell from 252 MB to 64 MB, which left reading's 117 MB as the peak.
Working set is 126 MB, as it includes the mapped window, but those pages are backed by the file and the system can drop them.

### Reading's last 25 MB

At 117 MB, three arenas held 114 MB:

| arena | asked for | held |
| --- | --- | --- |
| contents: images, boxes, entries, strings | 51.3 MB | 57 MB |
| reading: tables, geometries, seen codes | 25.8 MB | 33 MB |
| per-file, at its largest | 17.3 MB | 24.3 MB |

5f343d6 made two changes:

- The per-file arena keeps at most 4 MiB between files. `reset(.retain_capacity)` had kept the 24 MB of `plant/mushroom.json` for every file after it.
- The block entries grow from `gpa`, which frees old copies.

That reached 92 MB.

## Estimates and measurements

Several estimates made along the way were wrong, and measuring settled each one.

| estimate | measured |
| --- | --- |
| the switch added about 190 MB | it added about 1.9 GB |
| textures fill reading's arena | they fit in its spare space |
| freeing textures per image is the easy gain | shape files and block types were the cause |
| skipping `open` takes the peak to 252 MB | 283 MB: most of the rise was writing |
| freeing contents takes the peak to 252 MB | 261 MB: encoding still needs them |
| the mapped file alone takes the peak to about 60–70 MB | 117 MB: reading was still higher |

## Findings

- **Arenas keep what they replace.** Anything that grows by reallocating should grow outside an arena, or be sized first.
- **Arenas free all at once.** Data with different lifetimes needs different arenas: what's small and needed later can pin everything beside it.
- **`std.heap.page_allocator` commits on Windows.** A large allocation counts against the commit limit even if never touched.
- **`Allocator.alloc` fills memory in safe builds.** That touches every page of a large allocation; `rawAlloc` doesn't.
- **`Io.File.MemoryMap` ignores its offset on Windows in Zig 0.17.** `createFileMap` passes `null` to `NtMapViewOfSection`, so `FileBuffer` maps windows itself there.
- **Renaming over an open or mapped file works on Windows in Zig 0.17.** A render keeps reading its old mapping while a prepare replaces the file.
- **A full disk stops a program writing to a mapped page.** `fallocate` on Linux, `F_PREALLOCATE` on macOS and extending the file on NTFS turn that into an error first.

## Remaining

At 92 MB, the peak is in reading, and drawing needs 64 MB.

Only Windows has run this: Linux and macOS have only been compiled, and only one mod has been tried (`TODO.md`, items 13 and 14).

Working set could fall below 100 MB too with a smaller window, at the cost of remapping more often.
