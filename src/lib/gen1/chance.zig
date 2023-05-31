const builtin = @import("builtin");
const std = @import("std");

const expect = std.testing.expect;
const assert = std.debug.assert;

const DEBUG = @import("../common/debug.zig").print;
const options = @import("../common/options.zig");

const Player = @import("../common/data.zig").Player;
const Optional = @import("../common/optional.zig").Optional;

const Move = @import("data.zig").Move;
const MoveSlot = @import("data.zig").MoveSlot;

const enabled = options.chance;
const showdown = options.showdown;

/// Actions taken by a hypothetical "chance player" that convey information about which RNG events
/// were observed during a battle `update`. This can additionally be provided as input to the
/// `update` call to override the normal behavior of the RNG in order to force specific outcomes.
pub const Actions = extern struct {
    /// Information about the RNG activity for Player 1
    p1: Action = .{},
    /// Information about the RNG activity for Player 2
    p2: Action = .{},

    comptime {
        assert(@sizeOf(Actions) == 16);
    }

    /// Returns the `Action` for the given `player`.
    pub inline fn get(self: *Actions, player: Player) *Action {
        return if (player == .P1) &self.p1 else &self.p2;
    }
};

/// Information about the RNG that was observed during a battle `update` for a single player.
pub const Action = packed struct {
    /// Observed values of various durations. Does not influence future RNG calls.
    durations: Durations = .{},

    /// If not None, the Move to return for Rolls.metronome.
    metronome: Move = .None,
    /// If not 0, psywave - 1 should be returned as the damage roll for Rolls.psywave.
    psywave: u8 = 0,

    /// If not None, the Player to be returned by Rolls.speedTie.
    speed_tie: Optional(Player) = .None,
    /// If not 0, the roll 216 + damage represents the roll to be returned Rolls.damage.
    damage: u6 = 0,

    /// If not None, the value to return for Rolls.hit.
    hit: Optional(bool) = .None,
    /// If not 0, the move slot (1-4) to return in Rolls.moveSlot.
    move_slot: u3 = 0,
    /// If not 0, the value (2-5) to return for Rolls.distribution.
    distribution: u3 = 0,

    /// If not None, the value to be returned for
    /// Rolls.{confusionChance,secondaryChance,poisonChance}.
    secondary_chance: Optional(bool) = .None,
    /// If not 0, the value to be returned by
    /// Rolls.{sleepDuration,disableDuration,confusionDuration,attackingDuration}.
    duration: u4 = 0,
    /// If not None, the value to be returned by Rolls.criticalHit.
    critical_hit: Optional(bool) = .None,

    /// If not None, the value to return for Rolls.confused.
    confused: Optional(bool) = .None,
    /// If not None, the value to return for Rolls.paralyzed.
    paralyzed: Optional(bool) = .None,

    _: u4 = 0,

    comptime {
        assert(@sizeOf(Action) == 8);
    }

    pub fn format(
        self: Action,
        comptime fmt: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = opts;

        try writer.writeByte('<');
        var printed = false;
        inline for (@typeInfo(Action).Struct.fields) |field| {
            const val = @field(self, field.name);
            switch (@typeInfo(@TypeOf(val))) {
                .Struct => {}, // FIXME
                .Enum => if (val != .None) {
                    if (printed) try writer.writeAll(", ");
                    try writer.print("{s}:{s}", .{ field.name, @tagName(val) });
                    printed = true;
                },
                .Int => if (val != 0) {
                    if (printed) try writer.writeAll(", ");
                    try writer.print("{s}:{d}", .{ field.name, val });
                    printed = true;
                },
                else => unreachable,
            }
        }
        try writer.writeByte('>');
    }
};

/// Observed values for various durations that need to be tracked in order to properly
/// deduplicate transitions with a primary key.
pub const Durations = packed struct {
    /// The number of turns a Pokémon has been observed to be sleeping.
    sleep: u4 = 0,
    /// The number of turns a Pokémon has been observed to be disabled.
    disable: u4 = 0,
    /// The number of turns a Pokémon has been observed to be confused.
    confusion: u4 = 0,
    /// The number of turns a Pokémon has been observed to be attacking.
    attacking: u4 = 0,

    comptime {
        assert(@sizeOf(Durations) == 2);
    }
};

/// TODO
pub fn Chance(comptime Rational: type) type {
    return struct {
        const Self = @This();

        /// The probability of the actions taken by a hypothetical "chance player" occuring.
        probability: Rational,
        /// The actions taken by a hypothetical "chance player" that convey information about which
        /// RNG events were observed during a battle `update`.
        actions: Actions = .{},

        // In many cases on both the cartridge and on Pokémon Showdown rolls are made even though
        // later checks render their result irrelevant (missing when the target is actually immune,
        // rolling for damage when the move is later revealed to have missed, etc). We can't reorder
        // the logic to ensure we only ever make rolls when required due to our desire to maintain
        // RNG frame accuracy, so instead we save these "pending" updates to the probability and
        // only commit them once we know they are relevant (a naive solution would be to instead
        // update the probability eagerly and later "undo" the update by multiplying by the inverse
        // but this would be more costly and also error prone in the presence of
        // overflow/normalization).
        //
        // This design deliberately make use of the fact that recursive moves on the cartridge may
        // overwrite critical hit information multiple times as only the last update actually
        // matters for the purposes of the logical results.
        //
        // Finally, because each player's actions are processed sequentially we only need a single
        // shared structure to track this information (though it needs to be cleared appropriately)
        pending: if (showdown) struct {
            hit: bool = false,
            hit_probablity: u8 = 0,
        } else struct {
            crit: bool = false,
            crit_probablity: u8 = 0,
            damage_roll: u6 = 0,
            hit: bool = false,
            hit_probablity: u8 = 0,
        } = .{},

        /// Possible error returned by operations tracking chance probability.
        pub const Error = Rational.Error;

        pub fn reset(self: *Self) void {
            self.probability.reset();
            // FIXME: don't clear durations
            self.actions = .{};
            self.pending = .{};
        }

        pub fn commit(self: *Self, player: Player, ok: bool) Error!void {
            var action = self.actions.get(player);
            // Always commit the hit result if we make it here (commit won't be called at all if the
            // target is immune/behind a sub/etc)
            if (self.pending.hit_probablity != 0) {
                try self.probability.update(self.pending.hit_probablity, 256);
                action.hit = if (self.pending.hit) .true else .false;
            }

            if (showdown) return;

            // If the move actually lands we can commit any past critical hit / damage rolls. We
            // avoid updating anything if there wasn't a damage roll as any "critical hit" not tied
            // to a damage roll is actually a no-op
            if (ok and self.pending.damage_roll > 0) {
                assert(!self.pending.crit or self.pending.crit_probablity > 0);

                if (self.pending.crit_probablity != 0) {
                    try self.probability.update(self.pending.crit_probablity, 256);
                    action.critical_hit = if (self.pending.crit) .true else .false;
                }

                try self.probability.update(1, 39);
                action.damage = self.pending.damage_roll;
            }
        }

        pub fn clear(self: *Self) void {
            if (!enabled) return;

            self.pending = .{};
        }

        pub fn speedTie(self: *Self, p1: bool) Error!void {
            if (!enabled) return;

            try self.probability.update(1, 2);
            self.actions.p1.speed_tie = if (p1) .P1 else .P2;
            self.actions.p2.speed_tie = self.actions.p1.speed_tie;
        }

        pub fn criticalHit(self: *Self, player: Player, crit: bool, rate: u8) Error!void {
            if (!enabled) return;

            const n = if (crit) rate else @intCast(u8, 256 - @as(u9, rate));
            if (showdown) {
                try self.probability.update(n, 256);
                self.actions.get(player).critical_hit = if (crit) .true else .false;
            } else {
                self.pending.crit = crit;
                self.pending.crit_probablity = n;
            }
        }

        pub fn damage(self: *Self, player: Player, roll: u8) Error!void {
            if (!enabled) return;

            if (showdown) {
                try self.probability.update(1, 39);
                self.actions.get(player).damage = @intCast(u6, roll - 216);
            } else {
                self.pending.damage_roll = @intCast(u6, roll - 216);
            }
        }

        pub fn hit(self: *Self, ok: bool, accuracy: u8) void {
            if (!enabled) return;

            const p = if (ok) accuracy else @intCast(u8, 256 - @as(u9, accuracy));
            self.pending.hit = ok;
            self.pending.hit_probablity = p;
        }

        pub fn confused(self: *Self, player: Player, cfz: bool) Error!void {
            if (!enabled) return;

            try self.probability.update(1, 2);
            self.actions.get(player).confused = if (cfz) .true else .false;
        }

        pub fn paralyzed(self: *Self, player: Player, par: bool) Error!void {
            if (!enabled) return;

            try self.probability.update(@as(u8, if (par) 1 else 3), 4);
            self.actions.get(player).paralyzed = if (par) .true else .false;
        }

        pub fn secondaryChance(self: *Self, player: Player, proc: bool, rate: u8) Error!void {
            if (!enabled) return;

            const n = if (proc) rate else @intCast(u8, 256 - @as(u9, rate));
            try self.probability.update(n, 256);
            self.actions.get(player).secondary_chance = if (proc) .true else .false;
        }

        pub fn metronome(self: *Self, player: Player, move: Move) Error!void {
            if (!enabled) return;

            try self.probability.update(1, Move.size - 2);
            self.actions.get(player).metronome = move;
        }

        pub fn psywave(self: *Self, player: Player, power: u8, max: u8) Error!void {
            if (!enabled) return;

            try self.probability.update(1, max);
            self.actions.get(player).psywave = power + 1;
        }

        pub fn distribution(self: *Self, player: Player, n: u3) Error!void {
            if (!enabled) return;

            try self.probability.update(@as(u8, if (n > 3) 1 else 3), 8);
            self.actions.get(player).distribution = n;
        }

        pub fn moveSlot(self: *Self, player: Player, slot: u4, ms: []MoveSlot, n: u4) Error!void {
            if (!enabled) return;

            const denominator = if (n != 0) n else denominator: {
                var i: usize = ms.len;
                while (i > 0) {
                    i -= 1;
                    if (ms[i].id != .None) break :denominator i + 1;
                }
                unreachable;
            };

            try self.probability.update(1, denominator);
            self.actions.get(player).move_slot = @intCast(u3, slot);
        }
    };
}

pub const NULL = Null{};

const Null = struct {
    pub const Error = error{};

    pub fn commit(self: Null, player: Player, ok: bool) Error!void {
        _ = .{ self, player, ok };
    }

    pub fn clear(self: Null) void {
        _ = .{self};
    }

    pub fn speedTie(self: Null, p1: bool) Error!void {
        _ = .{ self, p1 };
    }

    pub fn criticalHit(self: Null, player: Player, crit: bool, rate: u8) Error!void {
        _ = .{ self, player, crit, rate };
    }

    pub fn damage(self: Null, player: Player, roll: u8) Error!void {
        _ = .{ self, player, roll };
    }

    pub fn hit(self: Null, ok: bool, accuracy: u8) void {
        _ = .{ self, ok, accuracy };
    }

    pub fn confused(self: Null, player: Player, ok: bool) Error!void {
        _ = .{ self, player, ok };
    }

    pub fn paralyzed(self: Null, player: Player, ok: bool) Error!void {
        _ = .{ self, player, ok };
    }

    pub fn secondaryChance(self: Null, player: Player, proc: bool, rate: u8) Error!void {
        _ = .{ self, player, proc, rate };
    }

    pub fn metronome(self: Null, player: Player, move: Move) Error!void {
        _ = .{ self, player, move };
    }

    pub fn psywave(self: Null, player: Player, power: u8, max: u8) Error!void {
        _ = .{ self, player, power, max };
    }

    pub fn distribution(self: Null, player: Player, n: u3) Error!void {
        _ = .{ self, player, n };
    }

    pub fn moveSlot(self: Null, player: Player, slot: u4, ms: []MoveSlot, n: u4) Error!void {
        _ = .{ self, player, slot, ms, n };
    }
};

fn TypeOf(comptime field: []const u8) type {
    for (@typeInfo(Action).Struct.fields) |f| if (std.mem.eql(u8, f.name, field)) return f.type;
    unreachable;
}
