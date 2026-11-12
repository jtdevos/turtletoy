# TurtleToy Language & Creative Coding Guide

Welcome to **TurtleToy**, a whimsical creative-coding language and native Metal 2D SDF studio. TurtleToy blends the immediate joy of classic Logo turtle graphics with modern shader brushes, L-systems, kaleidoscopic symmetry, and live-scrubbable parameters.

---

## 1. Movement & Drawing Commands

| Command | Aliases | Arguments | Description |
| :--- | :--- | :--- | :--- |
| `fd <dist>` | `forward` | `distance` | Move the turtle forward by `<dist>` units in its current heading. |
| `bk <dist>` | `back` | `distance` | Move the turtle backward by `<dist>` units. |
| `lt <deg>` | `left` | `degrees` | Rotate the turtle counter-clockwise by `<deg>` degrees. |
| `rt <deg>` | `right` | `degrees` | Rotate the turtle clockwise by `<deg>` degrees. |
| `pu` | `penup` | — | Lift the pen so movement does not leave strokes. |
| `pd` | `pendown` | — | Lower the pen so movement draws SDF strokes. |
| `home` | — | — | Return the turtle to `(0, 0)` facing North (`0°`). |
| `goto <x>, <y>` | `setxy` | `x, y` | Move from current position to `(x, y)` (draws if pen is down). |
| `move <x>, <y>` | — | `x, y` | Teleport to `(x, y)` without drawing a stroke. |
| `seth <deg>` | `setheading` | `degrees` | Set absolute heading (`0` = North/+Y, `90` = East/+X). |
| `arc <radius>, <deg>` | — | `radius, degrees` | Sweep a smooth circular arc of `<radius>` and `<deg>` degrees. |
| `circle <radius>` | — | `radius` | Draw a circle of `<radius>` centered at the turtle's current position. |
| `dot <radius>` | — | `radius` | Stamp a glowing circular dot at the turtle's position. |
| `polygon <sides>, <r>` | `poly` | `sides, radius, [filled]` | Draw a regular polygon (filled by default). |
| `star <pts>, <rOut>, <rIn>` | — | `points, outerR, innerR` | Draw a luminous filled star polygon. |
| `beginfill` / `endfill` | — | — | Record turtle vertices and fill the enclosed polygon with a glowing gradient. |

---

## 2. Procedural Metal Brushes & HDR Effects

TurtleToy renders every stroke as an analytical Signed Distance Field (SDF) capsule in `RGBA16Float` HDR space with a multi-pass Gaussian bloom pyramid.

```
brush "electric"
glow 2.2
width 4.5
color #00F5D4
```

### Available Brushes (`brush "<name>"`)
- `"neon"` — Intense white-hot inner core with a saturated HDR plasma aura.
- `"laser"` — Razor-sharp coherent beam with subtle chromatic dispersion on the fringes.
- `"watercolor"` — Organic FBM paper-edge bleed and coffee-ring pigment pooling.
- `"calligraphy"` — Chisel-nib thickness modulation based on stroke angle + brush bristle texture.
- `"rainbow"` — Continuous spectral prism shift along cumulative path distance and time `t`.
- `"electric"` — Animated dual-strand high-voltage jagged lightning arcs between segment endpoints.
- `"stardust"` — Twinkling 4-point star glints and constellation beads along the path.
- `"ribbon"` — 3D cylindrical satin shading with specular highlights and iridescent rim.

### Available Backdrops (`backdrop "<name>"`)
- `"void"` — Deep cosmic space with procedural twinkling starfield.
- `"synthwave"` — Outrun horizon glow and perspective cyber grid.
- `"parchment"` — Warm tactile watercolor paper grain.
- `"ocean"` — Bioluminescent deep sea with animated caustic light rays.
- `"nebula"` — Swirling aurora magenta and teal cosmic clouds.
- `"blueprint"` — Architect drafting grid.

### Color & Symmetry Commands
- `color #FF00AA` or `color "cyan"` or `color r, g, b, [a]`
- `hsl <hue 0..360>, <sat 0..100>, <light 0..100>, [alpha 0..1]`
- `palette "<name>", <t>` — Cosine color palettes: `"cyberpunk"`, `"sakura"`, `"sunset"`, `"ocean"`, `"aurora"`.
- `symmetry <n>, [mirror]` — Replicate every stroke with `<n>`-fold rotational symmetry.
- `kaleidoscope <n>, [mirror]` — Enable `<n>`-fold rotational + mirror reflection symmetry.
- `sparkle <count>, [size], [speed]` — Emit a burst of GPU particles from the turtle pen!
- `ripple <radius>` — Trigger an expanding energy ripple across the backdrop shader.

---

## 3. Live Sliders (`@param`) & Inline Number Scrubbing

Add `@param` anywhere in your program to automatically generate live interactive sliders or color pickers in the IDE:

```
@param petals 12 4 24 1 "Symmetry Fold"
@param radius 210 60 320 1 "Petal Radius"
@param core_color #00F5D4 "Inner Core Color"
```

> **Pro Tip — Option-Drag Number Scrubbing**: Hold **`Option (⌥)`** and drag left/right on **any number literal** directly inside the code editor to scrub its value live at 120fps! Hold **`Option + Shift`** for fine decimal scrubbing.

---

## 4. Control Flow, Procedures, `branch`, `spawn`, and `lsystem`

### Loops & Conditionals
```
repeat 12 {
    fd 60
    rt 30
}

for i in 1..36 {
    let ratio = i / 36
    palette "cyberpunk", ratio
    fd i * 3
    rt 89
}
```

### Recursive Procedures & `branch { ... }`
`branch { ... }` pushes the turtle's position, heading, color, width, and brush onto a stack and restores it automatically at `}` — making fractal trees effortless:
```
to tree(len, level) {
    if level <= 0 {
        dot 5
        return
    }
    fd len
    branch {
        lt 28
        tree(len * 0.72, level - 1)
    }
    branch {
        rt 28
        tree(len * 0.72, level - 1)
    }
}
```

### Declarative L-Systems (`lsystem { ... }`)
Built-in string rewriting grammar where `F`/`G` move forward, `+`/`-` turn right/left, `[`/`]` push/pop turtle state, `@` stamps a glowing blossom dot, and `draw "<symbol>" { ... }` lets you customize how any symbol renders:
```
lsystem {
    axiom: "X"
    generations: 5
    angle: 22.5
    size: 9.5
    rule "X" -> "F-[[X]+X@]+F[+FX@]-X"
    rule "F" -> "FF"
    draw "F" {
        palette "ocean", progress + t * 0.05
        fd 9.5
    }
}
```
