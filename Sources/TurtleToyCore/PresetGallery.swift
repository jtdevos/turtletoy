import Foundation

public struct PresetProgram: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let badge: String
    public let iconName: String
    public let accentHex: String
    public let code: String

    public init(
        id: String,
        title: String,
        subtitle: String,
        badge: String,
        iconName: String,
        accentHex: String,
        code: String
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.iconName = iconName
        self.accentHex = accentHex
        self.code = code
    }
}

public enum PresetGallery {
    public static let all: [PresetProgram] = [
        PresetProgram(
            id: "neon_lotus_kaleidoscope",
            title: "Cyber Lotus Mandala",
            subtitle: "12-fold kaleidoscope with neon plasma & satin ribbon petals",
            badge: "HDR Kaleidoscope",
            iconName: "sparkles",
            accentHex: "#00F5D4",
            code: """
            // ✨ Cyber Lotus Mandala
            // Drag sliders below or Option-drag any number in the code!
            @param petals 12 4 24 1 "Symmetry Fold"
            @param radius 210 60 320 1 "Petal Radius"
            @param curl 108 30 175 1 "Spiral Curl"
            @param bloom_glow 1.25 0.2 3.0 0.1 "Neon Intensity"
            @param primary #00F5D4 "Inner Core Color"

            backdrop "void"
            kaleidoscope petals 1
            glow bloom_glow

            // Luminous inner star polygon
            color primary
            brush "neon"
            width 3.2
            star 6, radius * 0.28, radius * 0.12

            // Swirling outer ribbon arcs
            for i in 1..28 {
                let ratio = i / 28
                palette "cyberpunk", ratio + t * 0.08
                width lerp(5.0, 1.4, ratio)
                brush "ribbon"
                fd radius * 0.13
                rt curl + sin(i * 18 + t * 40) * 8
                arc radius * 0.26, 42
            }

            // Outer stardust halo
            brush "stardust"
            color #FFD166
            width 5
            arc radius * 0.52, 160
            sparkle 24, 9, 85
            """
        ),

        PresetProgram(
            id: "sakura_bonsai_tree",
            title: "Sakura Moonlit Bonsai",
            subtitle: "Recursive `branch` fractal tree with glowing cherry blossoms",
            badge: "Recursive Branches",
            iconName: "leaf.fill",
            accentHex: "#FF75B5",
            code: """
            // 🌸 Sakura Moonlit Bonsai
            // Uses `branch { ... }` to save & restore turtle state effortlessly!
            @param depth 8 4 10 1 "Branch Depth"
            @param trunk_len 95 50 140 1 "Trunk Length"
            @param spread 27 12 48 0.5 "Branch Spread"
            @param sway 6 0 20 0.5 "Wind Sway"
            @param blossom #FF6AC1 "Blossom Color"

            backdrop "nebula"
            seed 42

            to tree(len, level) {
                if level <= 0 {
                    // Glowing blossom cluster at branch tips
                    color blossom
                    glow 2.2
                    dot 6.5
                    color #FFF1F8
                    dot 3.0
                    return
                }

                // Smooth bark-to-blossom gradient
                let progress = 1.0 - (level / depth)
                hsl lerp(28, 330, progress), lerp(55, 90, progress), lerp(38, 72, progress)
                width max(1.2, level * 1.65)
                glow lerp(0.35, 1.6, progress)
                brush "calligraphy"

                fd len

                let wind = sin(t * 45 + level * 30) * sway

                branch {
                    lt spread + wind
                    tree(len * 0.74, level - 1)
                }
                branch {
                    rt spread * 0.88 - wind
                    tree(len * 0.71, level - 1)
                }
                if level > 3 {
                    branch {
                        rt (spread * 0.25)
                        tree(len * 0.54, level - 2)
                    }
                }
            }

            move 0, -230
            seth 0
            tree(trunk_len, depth)
            """
        ),

        PresetProgram(
            id: "electric_plasma_coil",
            title: "Tesla Plasma Coil",
            subtitle: "High-voltage jagged lightning arcs with multi-turtle discharge",
            badge: "Electric Shader",
            iconName: "bolt.fill",
            accentHex: "#5CE1E6",
            code: """
            // ⚡️ Tesla Plasma Coil
            // Showcases the procedural `electric` lightning brush & `spawn`
            @param bolts 9 3 18 1 "Lightning Tendrils"
            @param reach 220 100 320 5 "Arc Reach"
            @param chaos 34 5 75 1 "Arc Zigzag"
            @param voltage 2.4 0.5 4.0 0.1 "Plasma Glow"

            backdrop "synthwave"
            brush "electric"
            glow voltage
            seed 108

            // Central high-voltage containment rings
            color #7B2CBF
            width 6
            circle 36
            color #00F5D4
            width 3.5
            circle 20

            // Spawn lightning tendrils radiating from the core
            for b in 1..bolts {
                spawn {
                    seth (b * (360 / bolts)) + t * 25
                    let steps = 14
                    for s in 1..steps {
                        let p = s / steps
                        hsl lerp(185, 290, p), 95, lerp(78, 55, p)
                        width lerp(5.5, 1.4, p)
                        rt sin(s * 55 + b * 40 + t * 90) * chaos
                        fd reach / steps
                    }
                    sparkle 14, 7, 70
                    ripple 45
                }
            }
            """
        ),

        PresetProgram(
            id: "bioluminescent_lsystem_reef",
            title: "Bioluminescent Coral L-System",
            subtitle: "Declarative `lsystem` grammar with organic ocean currents",
            badge: "L-System Engine",
            iconName: "water.waves",
            accentHex: "#38F9D7",
            code: """
            // 🪸 Bioluminescent Coral L-System
            // Native L-System rewriting engine with custom symbol actions!
            @param generations 5 2 6 1 "Growth Generations"
            @param angle 22.5 10 40 0.5 "Branch Angle"
            @param step_len 9.5 4 18 0.5 "Segment Size"

            backdrop "ocean"
            brush "neon"
            glow 1.6

            move 0, -240
            seth 0
            width 2.8

            lsystem {
                axiom: "X"
                generations: generations
                angle: angle + sin(t * 30) * 2.5
                size: step_len
                rule "X" -> "F-[[X]+X@]+F[+FX@]-X"
                rule "F" -> "FF"
                draw "F" {
                    palette "ocean", progress + t * 0.05
                    width lerp(3.8, 1.2, progress)
                    fd step_len
                }
            }
            """
        ),

        PresetProgram(
            id: "watercolor_botanical_mandala",
            title: "Aquarelle Botanical Rose",
            subtitle: "Organic pigment-bleed watercolor shader on warm parchment",
            badge: "Watercolor Brush",
            iconName: "paintbrush.pointed.fill",
            accentHex: "#F77F00",
            code: """
            // 🎨 Aquarelle Botanical Rose
            // Uses the procedural `watercolor` brush with translucent polygon fills
            @param layers 7 3 12 1 "Petal Rings"
            @param folds 8 5 16 1 "Petal Count"
            @param scale 155 70 230 5 "Bloom Scale"

            backdrop "parchment"
            symmetry folds, 1
            brush "watercolor"
            glow 0.25

            for ring in 1..layers {
                let p = ring / layers
                let r = scale * p
                branch {
                    hsl lerp(340, 38, p), 82, lerp(48, 62, p), 0.72
                    width lerp(10.0, 4.0, p)

                    beginfill
                    fd r * 0.35
                    lt 32
                    arc r * 0.48, 78
                    rt 64
                    arc r * 0.48, 78
                    endfill
                }
            }

            // Golden stamen center
            symmetry 1, 0
            color #D62828
            width 5
            circle 18
            """
        ),

        PresetProgram(
            id: "neon_dragon_curve",
            title: "Laser Dragon Curve Fractal",
            subtitle: "Classic recursive Heighway Dragon rendered with coherent laser prism",
            badge: "Classic Fractal",
            iconName: "aqi.medium",
            accentHex: "#FFBE0B",
            code: """
            // 🐉 Laser Dragon Curve Fractal
            @param order 11 4 13 1 "Fractal Order"
            @param total_span 290 150 420 5 "Curve Span"
            @param turn_ang 90 60 115 0.5 "Fold Angle"

            backdrop "void"
            brush "rainbow"
            glow 1.5
            width 2.6

            let seg = total_span / pow(1.4142, order)

            to dragon(level, dir) {
                if level <= 0 {
                    fd seg
                    return
                }
                lt (turn_ang * 0.5 * dir)
                dragon(level - 1, 1)
                rt (turn_ang * dir)
                dragon(level - 1, -1)
                lt (turn_ang * 0.5 * dir)
            }

            move -total_span * 0.35, -total_span * 0.15
            seth 90
            dragon(order, 1)
            """
        ),

        PresetProgram(
            id: "harmonic_spirograph_symphony",
            title: "Harmonic Laser Spirograph",
            subtitle: "Hypotrochoid orbital resonances with coherent laser beams",
            badge: "Parametric Orbit",
            iconName: "gyroscope",
            accentHex: "#9B5DE5",
            code: """
            // 🪐 Harmonic Laser Spirograph
            @param steps 180 60 400 5 "Orbit Steps"
            @param chord 260 100 380 5 "Step Chord"
            @param angle 144.8 90 179 0.1 "Resonance Angle"
            @param drift 0.65 0 3 0.05 "Harmonic Drift"

            backdrop "blueprint"
            brush "laser"
            glow 0.85
            width 2.0

            move -chord * 0.48, -55
            seth 18

            for i in 1..steps {
                let ratio = i / steps
                palette "sunset", ratio * 2.0 + t * 0.1
                fd chord + sin(i * 7 + t * 30) * 42
                rt angle + sin(i * drift) * 1.4
            }
            """
        ),

        PresetProgram(
            id: "celestial_constellation_weaver",
            title: "Celestial Star Weaver",
            subtitle: "Stardust trails, sacred geometry, and particle supernovas",
            badge: "Stardust & Particles",
            iconName: "moon.stars.fill",
            accentHex: "#F15BB5",
            code: """
            // 🌌 Celestial Star Weaver
            @param points 7 5 12 1 "Star Points"
            @param orbit 180 80 260 5 "Constellation Orbit"
            @param spin 15 0 90 1 "Orbital Twist"

            backdrop "void"
            symmetry points, 0

            // Sacred geometry guide rings
            brush "laser"
            color #3A86FF
            alpha 0.45
            width 1.5
            glow 1.1
            circle orbit
            circle orbit * 0.52

            // Stardust constellation paths
            brush "stardust"
            alpha 1.0
            color #FFBE0B
            width 6.0
            glow 2.1

            branch {
                rt spin + t * 12
                fd orbit
                dot 9
                sparkle 16, 8, 60
                rt 135
                brush "neon"
                color #FF006E
                width 2.5
                fd orbit * 1.15
            }
            """
        )
    ]
}
