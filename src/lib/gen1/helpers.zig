const std = @import("std");

const common = @import("../common/data.zig");
const optional = @import("../common/optional.zig");
const options = @import("../common/options.zig");
const protocol = @import("../common/protocol.zig");
const rational = @import("../common/rational.zig");
const rng = @import("../common/rng.zig");

const calc = @import("calc.zig");
const chance = @import("chance.zig");
const data = @import("data.zig");

const assert = std.debug.assert;

const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const Choice = common.Choice;
const Player = common.Player;

const Optional = optional.Optional;

const showdown = options.showdown;

const PSRNG = rng.PSRNG;

const DVs = data.DVs;
const Move = data.Move;
const MoveSlot = data.MoveSlot;
const Species = data.Species;
const Stats = data.Stats;
const Status = data.Status;

/// Configuration options controlling the domain of valid Pokémon that can be generated by the
/// random generator helpers.
pub const Options = struct {
    /// Whether to generate Pokémon adhering to "Cleric Clause".
    cleric: bool = showdown,
    /// Whether to generate Pokémon with moves that contain bugs on Pokémon Showdown that are
    /// unimplementable in the engine.
    block: bool = showdown,
};

/// Helpers to simplify initialization of a Generation I battle.
pub const Battle = struct {
    /// Initializes a Generation I battle with the teams specified by `p1` and `p2`
    /// and an RNG whose seed is derived from `seed`.
    pub fn init(
        seed: u64,
        p1: []const Pokemon,
        p2: []const Pokemon,
    ) data.Battle(data.PRNG) {
        var rand = PSRNG.init(seed);
        return .{
            .rng = prng(&rand),
            .sides = .{ Side.init(p1), Side.init(p2) },
        };
    }

    /// Initializes a Generation I battle with the teams specified by `p1` and `p2`
    /// and a FixedRNG that returns the provided `rolls`.
    pub fn fixed(
        comptime rolls: anytype,
        p1: []const Pokemon,
        p2: []const Pokemon,
    ) data.Battle(rng.FixedRNG(1, rolls.len)) {
        return .{
            .rng = .{ .rolls = rolls },
            .sides = .{ Side.init(p1), Side.init(p2) },
        };
    }

    /// Returns a Generation I battle that is randomly generated based on the `rand` and `opts`.
    pub fn random(rand: *PSRNG, opts: Options) data.Battle(data.PRNG) {
        return .{
            .rng = prng(rand),
            .turn = 0,
            .last_damage = 0,
            .sides = .{ Side.random(rand, opts), Side.random(rand, opts) },
        };
    }
};

fn prng(rand: *PSRNG) data.PRNG {
    // GLITCH: initial bytes in seed can only range from 0-252, not 0-255
    const max: u8 = 253;
    return .{
        .src = .{
            .seed = if (showdown)
                rand.newSeed()
            else
                .{
                    rand.range(u8, 0, max), rand.range(u8, 0, max),
                    rand.range(u8, 0, max), rand.range(u8, 0, max),
                    rand.range(u8, 0, max), rand.range(u8, 0, max),
                    rand.range(u8, 0, max), rand.range(u8, 0, max),
                    rand.range(u8, 0, max), rand.range(u8, 0, max),
                },
        },
    };
}

/// Helpers to simplify initialization of a Generation I side.
pub const Side = struct {
    /// Initializes a Generation I side with the team specified by `ps`.
    pub fn init(ps: []const Pokemon) data.Side {
        assert(ps.len > 0 and ps.len <= 6);
        var side = data.Side{};

        for (0..ps.len) |i| {
            side.pokemon[i] = Pokemon.init(ps[i]);
            side.order[i] = @intCast(u4, i) + 1;
        }
        return side;
    }

    /// Returns a Generation I side that is randomly generated based on the `rand` and `opts`.
    pub fn random(rand: *PSRNG, opts: Options) data.Side {
        const n = if (rand.chance(u8, 1, 100)) rand.range(u4, 1, 5 + 1) else 6;
        var side = data.Side{};

        for (0..n) |i| {
            side.pokemon[i] = Pokemon.random(rand, opts);
            side.order[i] = @intCast(u4, i) + 1;
        }

        return side;
    }
};

/// The maximum stat experience possible in Generation I.
pub const EXP = 0xFFFF;

/// Helpers to simplify initialization of a Generation I Pokémon.
pub const Pokemon = struct {
    /// The Pokémon's species.
    species: Species,
    /// The Pokémon's moves (assumed to all have the max possible PP).
    moves: []const Move,
    /// The Pokémon's current HP (defaults to 100% if not specified).
    hp: ?u16 = null,
    /// The Pokémon's current status.
    status: u8 = 0,
    /// The Pokémon's level.
    level: u8 = 100,
    /// The Pokémon's DVs.
    dvs: DVs = .{},
    /// The Pokémon's stat experience.
    stats: Stats(u16) = .{ .hp = EXP, .atk = EXP, .def = EXP, .spe = EXP, .spc = EXP },

    /// Initializes a Generation I Pokémon based on the information in `p`.
    pub fn init(p: Pokemon) data.Pokemon {
        var pokemon = data.Pokemon{};
        pokemon.species = p.species;
        const species = Species.get(p.species);
        inline for (@typeInfo(@TypeOf(pokemon.stats)).Struct.fields) |field| {
            const hp = comptime std.mem.eql(u8, field.name, "hp");
            const spc =
                comptime std.mem.eql(u8, field.name, "spa") or std.mem.eql(u8, field.name, "spd");
            @field(pokemon.stats, field.name) = Stats(u16).calc(
                field.name,
                @field(species.stats, field.name),
                if (hp) p.dvs.hp() else if (spc) p.dvs.spc else @field(p.dvs, field.name),
                @field(p.stats, field.name),
                p.level,
            );
        }
        assert(p.moves.len > 0 and p.moves.len <= 4);
        for (p.moves, 0..) |m, j| {
            pokemon.moves[j].id = m;
            // NB: PP can be at most 61 legally (though can overflow to 63)
            pokemon.moves[j].pp = @intCast(u8, @min(Move.pp(m) / 5 * 8, 61));
        }
        if (p.hp) |hp| {
            pokemon.hp = hp;
        } else {
            pokemon.hp = pokemon.stats.hp;
        }
        pokemon.status = p.status;
        pokemon.types = species.types;
        pokemon.level = p.level;
        return pokemon;
    }

    /// Returns a Generation I Pokémon that is randomly generated based on the `rand` and `opts`.
    pub fn random(rand: *PSRNG, opt: Options) data.Pokemon {
        const s = @enumFromInt(Species, rand.range(u8, 1, Species.size + 1));
        const species = Species.get(s);
        const lvl = if (rand.chance(u8, 1, 20)) rand.range(u8, 1, 99 + 1) else 100;
        var stats: Stats(u16) = .{};
        const dvs = DVs.random(rand);
        inline for (@typeInfo(@TypeOf(stats)).Struct.fields) |field| {
            @field(stats, field.name) = Stats(u16).calc(
                field.name,
                @field(species.stats, field.name),
                if (comptime std.mem.eql(u8, field.name, "hp"))
                    dvs.hp()
                else
                    @field(dvs, field.name),
                if (rand.chance(u8, 1, 20)) rand.range(u16, 0, EXP + 1) else EXP,
                lvl,
            );
        }

        var ms = [_]MoveSlot{.{}} ** 4;
        const n = if (rand.chance(u8, 1, 100)) rand.range(u4, 1, 3 + 1) else 4;
        for (0..n) |i| {
            var m: Move = .None;
            sample: while (true) {
                m = @enumFromInt(Move, rand.range(u8, 1, Move.size - 1 + 1));
                if (opt.block and blocked(m)) continue :sample;
                for (0..i) |j| if (ms[j].id == m) continue :sample;
                break;
            }
            const pp_ups =
                if (!opt.cleric and rand.chance(u8, 1, 10)) rand.range(u2, 0, 2 + 1) else 3;
            // NB: PP can be at most 61 legally (though can overflow to 63)
            const max_pp = @intCast(u8, Move.pp(m) + @as(u8, pp_ups) * @min(Move.pp(m) / 5, 7));
            ms[i] = .{
                .id = m,
                .pp = if (opt.cleric) max_pp else rand.range(u8, 0, max_pp + 1),
            };
        }

        return .{
            .species = s,
            .types = species.types,
            .level = lvl,
            .stats = stats,
            .hp = if (opt.cleric) stats.hp else rand.range(u16, 0, stats.hp + 1),
            .status = if (!opt.cleric and rand.chance(u8, 1, 6 + 1))
                0 | (@as(u8, 1) << rand.range(u3, 1, 6 + 1))
            else
                0,
            .moves = ms,
        };
    }
};

fn blocked(m: Move) bool {
    // Binding moves are borked but only via Mirror Move / Metronome which are already blocked
    return switch (m) {
        .Mimic, .Metronome, .MirrorMove, .Transform => true,
        else => false,
    };
}

/// Convenience helper to create a move-type choice for the provided move slot.
pub fn move(slot: u4) Choice {
    return .{ .type = .Move, .data = slot };
}

/// Convenience helper to create a switch-type choice for the provided team slot.
pub fn swtch(slot: u4) Choice {
    return .{ .type = .Switch, .data = slot };
}

const NONE = @intFromEnum(Optional(bool).None);
const FALSE = @intFromEnum(Optional(bool).false);
const TRUE = @intFromEnum(Optional(bool).true);

/// Helper functions that efficiently return valid ranges for various RNG events based on the
/// state of an `Action` and other events to be used to construct a "transitions" function.
pub const Rolls = struct {
    const PLAYER_NONE = [_]Optional(Player){.None};
    const PLAYERS = [_]Optional(Player){ .P1, .P2 };

    /// Returns a slice with the correct range of values for speed ties given the `action` state.
    pub inline fn speedTie(action: chance.Action) []const Optional(Player) {
        return if (@field(action, "speed_tie") == .None) &PLAYER_NONE else &PLAYERS;
    }

    const BOOL_NONE = [_]Optional(bool){.None};
    const BOOLS = [_]Optional(bool){ .false, .true };

    /// Returns a slice with the correct range of values for hits given the `action` state
    /// and the state of the `parent` (whether the player's Pokémon was fully paralyzed).
    pub inline fn hit(action: chance.Action, parent: Optional(bool)) []const Optional(bool) {
        if (parent == .true) return &BOOL_NONE;
        return if (@field(action, "hit") == .None) &BOOL_NONE else &BOOLS;
    }

    /// Returns a slice with the correct range of values for critical hits given the `action` state
    /// and the state of the `parent` (whether the player's Pokémon's move hit).
    pub inline fn criticalHit(
        action: chance.Action,
        parent: Optional(bool),
    ) []const Optional(bool) {
        if (parent == .false) return &BOOL_NONE;
        return if (@field(action, "critical_hit") == .None) &BOOL_NONE else &BOOLS;
    }

    /// Returns a slice with the correct range of values for secondary chances hits given the
    /// `action` state and the state of the `parent` (whether the player's Pokémon's move hit).
    pub inline fn secondaryChance(
        action: chance.Action,
        parent: Optional(bool),
    ) []const Optional(bool) {
        if (parent == .false) return &BOOL_NONE;
        return if (@field(action, "secondary_chance") == .None) &BOOL_NONE else &BOOLS;
    }

    /// The min and max bounds on iteration over damage rolls.
    pub const Range = struct { min: u9, max: u9 };

    /// Returns the range bounding damage rolls given the `action` state and the state of
    /// the `parent` (whether the player's Pokémon's move hit).
    pub inline fn damage(action: chance.Action, parent: Optional(bool)) Range {
        return if (parent == .false or @field(action, "damage") == 0)
            .{ .min = 0, .max = 1 }
        else
            .{ .min = 217, .max = 256 };
    }

    /// Returns the max damage roll which will produce the same damage as `roll`
    /// given the base damage in `summaries`.
    pub inline fn coalesce(player: Player, roll: u8, summaries: *calc.Summaries, cap: bool) !u8 {
        if (roll == 0) return roll;

        const dmg = summaries.get(player.foe()).damage;
        if (dmg.base == 0 or (cap and dmg.capped)) return 255;

        // Closed form solution for max damage roll provided by Orion Taylor (taylorott)
        return @min(255, roll + ((254 - ((@as(u32, dmg.base) * roll) % 255)) / dmg.base));
    }

    /// Returns a slice with the correct range of values for confused given the `action` state
    /// and the state of the `parent` (the player's Pokémon's remaining confusion turns).
    pub inline fn confused(action: chance.Action, parent: u4) []const Optional(bool) {
        return if (parent == 0 or @field(action, "confused") == .None) &BOOL_NONE else &BOOLS;
    }

    /// Returns a slice with the correct range of values for paralysis given the `action` state
    /// and the state of the `parent` (whether the player's Pokémon was confused).
    pub inline fn paralyzed(action: chance.Action, parent: Optional(bool)) []const Optional(bool) {
        if (parent == .true) return &BOOL_NONE;
        return if (@field(action, "paralyzed") == .None) &BOOL_NONE else &BOOLS;
    }

    const DURATION_NONE = [_]u1{0};
    const DURATION = [_]u1{ 0, 1 };

    /// Returns a slice with a range of values for duration given the `action` state
    /// and the state of the `parent` (whether the player's Pokémon's move hit).
    pub inline fn duration(action: chance.Action, parent: Optional(bool)) []const u1 {
        if (parent == .false) return &DURATION_NONE;
        return if (@field(action, "duration") == 0) &DURATION_NONE else &DURATION;
    }

    const MODIFY_NONE = [_]u3{NONE};
    const MODIFY_FORCED = [_]u3{TRUE};
    const MODIFY = [_]u3{ FALSE, TRUE };

    /// Returns a slice with a range of values for sleep given the `action` state.
    pub inline fn sleep(action: chance.Action) []const u3 {
        const turns = @field(action, "sleep");
        return if (turns < 1 or turns >= 7) &MODIFY_NONE else &MODIFY;
    }

    const DISABLE_NONE = [_]u4{NONE};
    const DISABLE = [_]u4{ FALSE, TRUE };

    /// Returns a slice with a range of values for disable given the `action` state
    /// and the state of the `parent` (the player's Pokémon's remaining sleep turns).
    pub inline fn disable(action: chance.Action, parent: u4) []const u4 {
        const turns = @field(action, "disable");
        return if (parent > 0 or turns < 1 or turns >= 8) &DISABLE_NONE else &DISABLE;
    }

    /// Returns a slice with a range of values for confusion given the `action` state
    /// and the state of the `parent` (the player's remaining sleep turns).
    pub inline fn confusion(action: chance.Action, parent: u4) []const u3 {
        const turns = @field(action, "confusion");
        if (parent > 0 or turns < 1 or turns >= 5) return &MODIFY_NONE;
        return if (turns < 2) &MODIFY_FORCED else &MODIFY;
    }

    /// Returns a slice with a range of values for attacking given the `action` state
    /// and the state of the `parent` (whether the player's Pokémon was fully paralyzed).
    pub inline fn attacking(action: chance.Action, parent: Optional(bool)) []const u3 {
        const turns = @field(action, "attacking");
        if (parent == .true or turns < 1 or turns >= 3) return &MODIFY_NONE;
        return if (turns < 2) &MODIFY_FORCED else &MODIFY;
    }

    /// Returns a slice with a range of values for binding given the `action` state
    /// and the state of the `parent` (whether the player's Pokémon was fully paralyzed).
    pub inline fn binding(action: chance.Action, parent: Optional(bool)) []const u3 {
        const turns = @field(action, "binding");
        return if (parent == .true or turns < 1 or turns >= 4) &MODIFY_NONE else &MODIFY;
    }

    const SLOT_NONE = [_]u4{0};
    const SLOT = [_]u4{ 1, 2, 3, 4 };

    /// Returns a slice with a range of values for move slots given the `action` state
    /// and the state of the `parent` (whether the player's Pokémon's move hit).
    ///
    /// These slots may or **may not be valid** as slots may be unset / have 0 PP.
    pub inline fn moveSlot(action: chance.Action, parent: Optional(bool)) []const u4 {
        if (parent == .false) return &SLOT_NONE;
        return if (@field(action, "move_slot") == 0) &SLOT_NONE else &SLOT;
    }

    const MULTI_NONE = [_]u4{0};
    const MULTI = [_]u4{ 2, 3, 4, 5 };

    /// Returns a slice with the correct range of values for multi hit given the `action` state
    /// and the state of the `parent` (whether the player's Pokémon's move hit).
    pub inline fn multiHit(action: chance.Action, parent: Optional(bool)) []const u4 {
        if (parent == .false) return &MULTI_NONE;
        return if (@field(action, "multi_hit") == 0) &MULTI_NONE else &MULTI;
    }

    const PSYWAVE_NONE = [_]u8{0};
    const PSYWAVE = init: {
        var rolls: [150]u8 = undefined;
        for (0..150) |i| rolls[i] = i + 1;
        break :init rolls;
    };

    /// Returns a slice with the correct range of values for psywave given the `action` state,
    /// the `side`, and the state of the `parent` (whether the player's Pokémon's move hit).
    pub inline fn psywave(
        action: chance.Action,
        side: *data.Side,
        parent: Optional(bool),
    ) []const u8 {
        if (parent == .false) return &PSYWAVE_NONE;
        return if (@field(action, "psywave") == 0)
            &PSYWAVE_NONE
        else
            PSYWAVE[0 .. @as(u16, side.stored().level) * 3 / 2];
    }

    const MOVE_NONE = [_]Move{.None};
    const MOVES = init: {
        var moves: [Move.size - 2]Move = undefined;
        var i: usize = 0;
        for (@typeInfo(Move).Enum.fields) |f| {
            if (!(std.mem.eql(u8, f.name, "None") or
                std.mem.eql(u8, f.name, "Metronome") or
                std.mem.eql(u8, f.name, "Struggle") or
                std.mem.eql(u8, f.name, "SKIP_TURN")))
            {
                moves[i] = @field(Move, f.name);
                i += 1;
            }
        }
        break :init moves;
    };

    /// Returns a slice with the correct range of values for metronome given the `action` state.
    pub inline fn metronome(action: chance.Action) []const Move {
        return if (@field(action, "metronome") == .None) &MOVE_NONE else &MOVES;
    }
};

test "Rolls.speedTie" {
    const actions = chance.Actions{ .p1 = .{ .speed_tie = .P2 } };
    try expectEqualSlices(Optional(Player), &.{ .P1, .P2 }, Rolls.speedTie(actions.p1));
    try expectEqualSlices(Optional(Player), &.{.None}, Rolls.speedTie(actions.p2));
}

test "Rolls.damage" {
    const actions = chance.Actions{ .p2 = .{ .damage = 221 } };
    try expectEqual(Rolls.Range{ .min = 0, .max = 1 }, Rolls.damage(actions.p1, .None));
    try expectEqual(Rolls.Range{ .min = 217, .max = 256 }, Rolls.damage(actions.p2, .None));
    try expectEqual(Rolls.Range{ .min = 0, .max = 1 }, Rolls.damage(actions.p2, .false));
}

test "Rolls.coalesce" {
    var summaries =
        calc.Summaries{ .p1 = .{ .damage = .{ .base = 74, .final = 69, .capped = true } } };
    try expectEqual(@as(u8, 0), try Rolls.coalesce(.P2, 0, &summaries, false));
    try expectEqual(@as(u8, 241), try Rolls.coalesce(.P2, 238, &summaries, false));
    try expectEqual(@as(u8, 255), try Rolls.coalesce(.P2, 238, &summaries, true));
    summaries.p1.damage.final = 74;
    try expectEqual(@as(u8, 217), try Rolls.coalesce(.P2, 217, &summaries, false));
    try expectEqual(@as(u8, 255), try Rolls.coalesce(.P2, 217, &summaries, true));
}

test "Rolls.hit" {
    const actions = chance.Actions{ .p2 = .{ .hit = .true } };
    try expectEqualSlices(Optional(bool), &.{.None}, Rolls.hit(actions.p1, .None));
    try expectEqualSlices(Optional(bool), &.{ .false, .true }, Rolls.hit(actions.p2, .None));
    try expectEqualSlices(Optional(bool), &.{.None}, Rolls.hit(actions.p2, .true));
    try expectEqualSlices(Optional(bool), &.{ .false, .true }, Rolls.hit(actions.p2, .false));
}

test "Rolls.secondaryChance" {
    const actions = chance.Actions{ .p1 = .{ .secondary_chance = .true } };
    try expectEqualSlices(
        Optional(bool),
        &.{ .false, .true },
        Rolls.secondaryChance(actions.p1, .None),
    );
    try expectEqualSlices(Optional(bool), &.{.None}, Rolls.secondaryChance(actions.p1, .false));
    try expectEqualSlices(Optional(bool), &.{.None}, Rolls.secondaryChance(actions.p2, .None));
}

test "Rolls.criticalHit" {
    const actions = chance.Actions{ .p1 = .{ .critical_hit = .true } };
    try expectEqualSlices(
        Optional(bool),
        &.{ .false, .true },
        Rolls.criticalHit(actions.p1, .None),
    );
    try expectEqualSlices(Optional(bool), &.{.None}, Rolls.criticalHit(actions.p1, .false));
    try expectEqualSlices(Optional(bool), &.{.None}, Rolls.criticalHit(actions.p2, .None));
}

test "Rolls.confused" {
    const actions = chance.Actions{ .p2 = .{ .confused = .true } };
    try expectEqualSlices(Optional(bool), &.{.None}, Rolls.confused(actions.p1, 1));
    try expectEqualSlices(Optional(bool), &.{ .false, .true }, Rolls.confused(actions.p2, 1));
    try expectEqualSlices(Optional(bool), &.{.None}, Rolls.confused(actions.p2, 0));
}

test "Rolls.paralyzed" {
    const actions = chance.Actions{ .p2 = .{ .paralyzed = .true } };
    try expectEqualSlices(Optional(bool), &.{.None}, Rolls.paralyzed(actions.p1, .None));
    try expectEqualSlices(Optional(bool), &.{ .false, .true }, Rolls.paralyzed(actions.p2, .None));
    try expectEqualSlices(Optional(bool), &.{ .false, .true }, Rolls.paralyzed(actions.p2, .false));
    try expectEqualSlices(Optional(bool), &.{.None}, Rolls.paralyzed(actions.p2, .true));
}

test "Rolls.duration" {
    const actions = chance.Actions{ .p2 = .{ .duration = 3 } };
    try expectEqualSlices(u1, &.{0}, Rolls.duration(actions.p1, .None));
    try expectEqualSlices(u1, &.{ 0, 1 }, Rolls.duration(actions.p2, .None));
    try expectEqualSlices(u1, &.{0}, Rolls.duration(actions.p2, .false));
}

test "Rolls.sleep" {
    try expectEqualSlices(u3, &.{0}, Rolls.sleep(.{ .sleep = 0 }));
    try expectEqualSlices(u3, &.{0}, Rolls.sleep(.{ .sleep = 7 }));
    try expectEqualSlices(u3, &.{ FALSE, TRUE }, Rolls.sleep(.{ .sleep = 4 }));
}

test "Rolls.disable" {
    try expectEqualSlices(u4, &.{0}, Rolls.disable(.{ .disable = 0 }, 0));
    try expectEqualSlices(u4, &.{0}, Rolls.disable(.{ .disable = 8 }, 0));
    try expectEqualSlices(u4, &.{0}, Rolls.disable(.{ .disable = 4 }, 1));
    try expectEqualSlices(u4, &.{ FALSE, TRUE }, Rolls.disable(.{ .disable = 4 }, 0));
}

test "Rolls.confusion" {
    try expectEqualSlices(u3, &.{0}, Rolls.confusion(.{ .confusion = 0 }, 0));
    try expectEqualSlices(u3, &.{0}, Rolls.confusion(.{ .confusion = 5 }, 0));
    try expectEqualSlices(u3, &.{0}, Rolls.confusion(.{ .confusion = 3 }, 1));
    try expectEqualSlices(u3, &.{3}, Rolls.confusion(.{ .confusion = 1 }, 0));
    try expectEqualSlices(u3, &.{ FALSE, TRUE }, Rolls.confusion(.{ .confusion = 3 }, 0));
}

test "Rolls.attacking" {
    try expectEqualSlices(u3, &.{0}, Rolls.attacking(.{ .attacking = 0 }, .false));
    try expectEqualSlices(u3, &.{0}, Rolls.attacking(.{ .attacking = 3 }, .false));
    try expectEqualSlices(u3, &.{0}, Rolls.attacking(.{ .attacking = 2 }, .true));
    try expectEqualSlices(u3, &.{3}, Rolls.attacking(.{ .attacking = 1 }, .false));
    try expectEqualSlices(u3, &.{ FALSE, TRUE }, Rolls.attacking(.{ .attacking = 2 }, .false));
}

test "Rolls.binding" {
    try expectEqualSlices(u3, &.{0}, Rolls.binding(.{ .binding = 0 }, .false));
    try expectEqualSlices(u3, &.{0}, Rolls.binding(.{ .binding = 4 }, .false));
    try expectEqualSlices(u3, &.{0}, Rolls.binding(.{ .binding = 2 }, .true));
    try expectEqualSlices(u3, &.{ FALSE, TRUE }, Rolls.binding(.{ .binding = 2 }, .false));
}

test "Rolls.moveSlot" {
    const actions = chance.Actions{ .p2 = .{ .move_slot = 3 } };
    try expectEqualSlices(u4, &.{0}, Rolls.moveSlot(actions.p1, .None));
    try expectEqualSlices(u4, &.{ 1, 2, 3, 4 }, Rolls.moveSlot(actions.p2, .None));
    try expectEqualSlices(u4, &.{0}, Rolls.moveSlot(actions.p2, .false));
}

test "Rolls.multiHit" {
    const actions = chance.Actions{ .p2 = .{ .multi_hit = 3 } };
    try expectEqualSlices(u4, &.{0}, Rolls.multiHit(actions.p1, .None));
    try expectEqualSlices(u4, &.{ 2, 3, 4, 5 }, Rolls.multiHit(actions.p2, .None));
    try expectEqualSlices(u4, &.{0}, Rolls.multiHit(actions.p2, .false));
}

test "Rolls.metronome" {
    const actions = chance.Actions{ .p2 = .{ .metronome = .Surf } };
    try expectEqualSlices(Move, &.{.None}, Rolls.metronome(actions.p1));
    try expectEqual(@enumFromInt(Move, 24), Rolls.metronome(actions.p2)[23]);
}

test "Rolls.psywave" {
    const actions = chance.Actions{ .p2 = .{ .psywave = 79 } };
    var side = Side.init(&[_]Pokemon{.{
        .species = .Bulbasaur,
        .level = 100,
        .moves = &[_]Move{.Tackle},
    }});

    try expectEqualSlices(u8, &.{0}, Rolls.psywave(actions.p1, &side, .None));
    var rolls = Rolls.psywave(actions.p2, &side, .None);
    try expectEqual(@as(u8, 150), rolls[rolls.len - 1]);
    side.stored().level = 81;
    rolls = Rolls.psywave(actions.p2, &side, .None);
    try expectEqual(@as(u8, 121), rolls[rolls.len - 1]);
    try expectEqualSlices(u8, &.{0}, Rolls.psywave(actions.p2, &side, .false));
}
