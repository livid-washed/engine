const std = @import("std");
const build_options = @import("build_options");

const common = @import("../common/data.zig");
const protocol = @import("../common/protocol.zig");
const rng = @import("../common/rng.zig");

const data = @import("data.zig");

const assert = std.debug.assert;

const expectEqual = std.testing.expectEqual;

const showdown = build_options.showdown;

const Choice = common.Choice;
const ID = common.ID;
const Player = common.Player;
const Result = common.Result;

const Damage = protocol.Damage;

const Gen12 = rng.Gen12;

const ActivePokemon = data.ActivePokemon;
const Move = data.Move;
const MoveSlot = data.MoveSlot;
const Side = data.Side;
const Species = data.Species;
const Stats = data.Stats;
const Status = data.Status;

// zig fmt: off
const BOOSTS = &[_][2]u8{
    .{ 25, 100 }, // -6
    .{ 28, 100 }, // -5
    .{ 33, 100 }, // -4
    .{ 40, 100 }, // -3
    .{ 50, 100 }, // -2
    .{ 66, 100 }, // -1
    .{   1,  1 }, //  0
    .{ 15,  10 }, // +1
    .{  2,   1 }, // +2
    .{ 25,  10 }, // +3
    .{  3,   1 }, // +4
    .{ 35,  10 }, // +5
    .{  4,   1 }, // +6
};
// zig fmt: on

const MAX_STAT_VALUE = 999;

pub fn update(battle: anytype, c1: Choice, c2: Choice, log: anytype) !Result {
    if (battle.turn == 0) return start(battle, log);

    const l1 = selectMove(battle, .P1, c1, c2);
    const l2 = selectMove(battle, .P2, c2, c1);

    if (turnOrder(battle, c1, c2) == .P1) {
        if (try doTurn(battle, .P1, c1, l1, .P2, c2, l2, log)) |r| return r;
    } else {
        if (try doTurn(battle, .P2, c2, l2, .P1, c1, l1, log)) |r| return r;
    }

    var p1 = battle.side(.P1);
    if (p1.active.volatiles.attacks == 0) {
        p1.active.volatiles.Trapping = false;
    }
    var p2 = battle.side(.P2);
    if (p2.active.volatiles.attacks == 0) {
        p2.active.volatiles.Trapping = false;
    }

    return endTurn(battle, log, @as(u2, @boolToInt(l1)) + @as(u2, @boolToInt(l2)));
}

fn start(battle: anytype, log: anytype) !Result {
    const p1 = battle.side(.P1);
    const p2 = battle.side(.P2);

    var slot = findFirstAlive(p1);
    if (slot == 0) return if (findFirstAlive(p2) == 0) Result.Tie else Result.Lose;
    try switchIn(battle, .P1, slot, true, log);

    slot = findFirstAlive(p2);
    if (slot == 0) return Result.Win;
    try switchIn(battle, .P2, slot, true, log);

    return endTurn(battle, log, 0);
}

fn findFirstAlive(side: *const Side) u8 {
    for (side.pokemon) |pokemon, i| if (pokemon.hp > 0) return side.order[i];
    return 0;
}

fn selectMove(battle: anytype, player: Player, choice: Choice, foe_choice: Choice) bool {
    var side = battle.side(player);
    var volatiles = &side.active.volatiles;
    const stored = side.stored();

    // pre-battle menu
    if (volatiles.Recharging or volatiles.Rage) return true;
    volatiles.Flinch = false;
    if (volatiles.Thrashing or volatiles.Charging) return true;

    // battle menu
    if (choice.type == .Switch) return false;

    // pre-move select
    if (Status.is(stored.status, .FRZ) or Status.is(stored.status, .SLP)) return true;
    if (volatiles.Bide) return true;
    if (volatiles.Trapping) {
        // GLITCH: https://glitchcity.wiki/Partial_trapping_move_Mirror_Move_link_battle_glitch
        if (foe_choice.type == .Switch) {
            // BUG: need to reset side.last_selected_move if originally Metronome
        }
        return true;
    }

    if (battle.foe(player).active.volatiles.Trapping) {
        side.last_selected_move = .SKIP_TURN;
        return true;
    }

    // move select
    if (choice.data == 0) {
        const struggle = ok: {
            for (side.active.moves) |move, i| {
                if (move.pp > 0 and volatiles.disabled.move != i + 1) break :ok false;
            }
            break :ok true;
        };

        assert(struggle);
        side.last_selected_move = .Struggle;
    } else {
        assert(choice.data <= 4);
        const move = side.active.moves[choice.data - 1];

        assert(move.pp != 0); // FIXME: wrap underflow?
        assert(side.active.volatiles.disabled.move != choice.data);
        side.last_selected_move = move.id;
    }

    // SHOWDOWN: getRandomTarget arbitrarily advances the RNG
    if (showdown) battle.rng.advance(side.last_selected_move.frames());
    return false;
}

fn switchIn(battle: anytype, player: Player, slot: u8, initial: bool, log: anytype) !void {
    var side = battle.side(player);
    var foe = battle.foe(player);
    var active = &side.active;
    const incoming = side.get(slot);

    assert(incoming.hp != 0);
    assert(slot != 1 or initial);

    const out = side.order[0];
    side.order[0] = side.order[slot - 1];
    side.order[slot - 1] = out;

    side.last_used_move = .None;
    foe.last_used_move = .None;

    active.stats = incoming.stats;
    active.species = incoming.species;
    active.types = incoming.types;
    active.boosts = .{};
    active.volatiles = .{};
    active.moves = incoming.moves;

    statusModify(incoming.status, &active.stats);

    foe.active.volatiles.Trapping = false;

    try log.switched(battle.active(player), incoming);
}

fn turnOrder(battle: anytype, c1: Choice, c2: Choice) Player {
    if ((c1.type == .Switch) != (c2.type == .Switch)) return if (c1.type == .Switch) .P1 else .P2;

    const m1 = battle.side(.P1).last_selected_move;
    const m2 = battle.side(.P2).last_selected_move;

    if ((m1 == .QuickAttack) != (m2 == .QuickAttack)) return if (m1 == .QuickAttack) .P1 else .P2;
    if ((m1 == .Counter) != (m2 == .Counter)) return if (m1 == .Counter) .P2 else .P1;

    // SHOWDOWN: https://www.smogon.com/forums/threads/adv-switch-priority.3622189/
    // > In Gen 1 it's irrelevant [which player switches first] because switches happen instantly on
    // > your own screen without waiting for the other player's choice (and their choice will appear
    // > to happen first for them too, unless they attacked in which case your switch happens first)
    // A cartridge-compatible implemention must not advance the RNG so we simply default to P1
    if (!showdown and c1.type == .Switch and c2.type == .Switch) return .P1;

    const spe1 = battle.side(.P1).active.stats.spe;
    const spe2 = battle.side(.P2).active.stats.spe;
    if (spe1 == spe2) {
        const p1 = if (showdown)
            battle.rng.range(u8, 0, 2) == 0
        else
            battle.rng.next() < Gen12.percent(50) + 1;
        return if (p1) .P1 else .P2;
    }

    return if (spe1 > spe2) .P1 else .P2;
}

fn doTurn(
    battle: anytype,
    player: Player,
    player_choice: Choice,
    player_locked: bool,
    foe_player: Player,
    foe_choice: Choice,
    foe_locked: bool,
    log: anytype,
) !?Result {
    if (try executeMove(battle, player, player_choice, player_locked, log)) |r| return r;
    if (try checkFaint(battle, foe_player, foe_locked, player_locked, log)) |r| return r;
    try handleResidual(battle, player, log);
    if (try checkFaint(battle, player, player_locked, foe_locked, log)) |r| return r;

    if (try executeMove(battle, foe_player, foe_choice, foe_locked, log)) |r| return r;
    if (try checkFaint(battle, player, player_locked, foe_locked, log)) |r| return r;
    try handleResidual(battle, foe_player, log);
    if (try checkFaint(battle, foe_player, foe_locked, player_locked, log)) |r| return r;

    return null;
}

fn executeMove(battle: anytype, player: Player, choice: Choice, locked: bool, log: anytype) !?Result {
    var side = battle.side(player);

    if (side.last_selected_move == .SKIP_TURN) return null;

    if (choice.type == .Switch) {
        try switchIn(battle, player, choice.data, false, log);
        return null;
    }

    var skip_can = false;
    var skip_pp = false;
    switch (try beforeMove(battle, player, choice.data, log)) {
        .done => return null,
        .skip_can => skip_can = true,
        .skip_pp => skip_pp = true,
        .ok => {},
        .err => return @as(?Result, Result.Error),
    }

    const from: ?Move = if (locked) side.last_selected_move else null;
    if (!skip_can and !try canMove(battle, player, choice, skip_pp, false, from, log)) return null;

    return doMove(battle, player, choice, false, log);
}

const BeforeMove = union(enum) { done, skip_can, skip_pp, ok, err };

fn beforeMove(battle: anytype, player: Player, mslot: u8, log: anytype) !BeforeMove {
    var side = battle.side(player);
    const foe = battle.foe(player);
    var active = &side.active;
    var stored = side.stored();
    const ident = battle.active(player);
    var volatiles = &active.volatiles;

    assert(active.move(mslot).id != .None);

    if (Status.is(stored.status, .SLP)) {
        // Even if the SLF bit is set this will still correctly modify the sleep duration
        stored.status -= 1;
        if (Status.duration(stored.status) == 0) {
            stored.status = 0; // clears SLF if present
            try log.cant(ident, .Sleep);
        }
        side.last_used_move = .None;
        return .done;
    }

    if (Status.is(stored.status, .FRZ)) {
        try log.cant(ident, .Freeze);
        side.last_used_move = .None;
        return .done;
    }

    if (foe.active.volatiles.Trapping) {
        try log.cant(ident, .Trapped);
        return .done;
    }

    if (volatiles.Flinch) {
        volatiles.Flinch = false;
        try log.cant(ident, .Flinch);
        return .done;
    }

    if (volatiles.Recharging) {
        volatiles.Recharging = false;
        try log.cant(ident, .Recharge);
        return .done;
    }

    if (volatiles.disabled.duration > 0) {
        volatiles.disabled.duration -= 1;
        if (volatiles.disabled.duration == 0) {
            volatiles.disabled.move = 0;
            try log.end(ident, .Disable);
        }
    }

    if (volatiles.Confusion) {
        assert(volatiles.confusion > 0);

        volatiles.confusion -= 1;
        if (volatiles.confusion == 0) {
            volatiles.Confusion = false;
            try log.end(ident, .Confusion);
        } else {
            try log.activate(ident, .Confusion);

            const confused = if (showdown)
                !battle.rng.chance(u8, 128, 256)
            else
                battle.rng.next() >= Gen12.percent(50) + 1;

            if (confused) {
                volatiles.Bide = false;
                volatiles.Thrashing = false;
                volatiles.MultiHit = false;
                volatiles.Flinch = false;
                volatiles.Charging = false;
                volatiles.Trapping = false;
                volatiles.Invulnerable = false;

                // calcDamage just needs a 40 BP physical move, its not actually Pound
                const move = Move.get(.Pound);
                if (!calcDamage(battle, player, player, move, false)) return .err;
                // Skipping adjustDamage / randomizeDamage / checkHit
                _ = try applyDamage(battle, player, player.foe(), log);

                return .done;
            }
        }
    }

    if (volatiles.disabled.move == mslot) {
        try log.disabled(ident, active.move(volatiles.disabled.move).id);
        return .done;
    }

    if (Status.is(stored.status, .PAR)) {
        const paralyzed = if (showdown)
            battle.rng.chance(u8, 63, 256)
        else
            battle.rng.next() < Gen12.percent(25);

        if (paralyzed) {
            volatiles.Bide = false;
            volatiles.Thrashing = false;
            volatiles.Charging = false;
            volatiles.Trapping = false;
            // GLITCH: Invulnerable is not cleared, resulting in the Fly/Dig glitch
            try log.cant(ident, .Paralysis);
            return .done;
        }
    }

    if (volatiles.Bide) {
        volatiles.state +%= battle.last_damage;
        try log.activate(ident, .Bide);

        assert(volatiles.attacks > 0);

        volatiles.attacks -= 1;
        if (volatiles.attacks != 0) return .done;

        volatiles.Bide = false;
        try log.end(ident, .Bide);

        battle.last_damage = volatiles.state *% 2;
        volatiles.state = 0;

        if (battle.last_damage == 0) {
            try log.fail(ident, .None);
            return .done;
        }

        // Skip Decrement PP / calcDamage / checkHit
        _ = try applyDamage(battle, player.foe(), player.foe(), log);
        return .done;
    }

    if (volatiles.Thrashing) {
        assert(volatiles.attacks > 0);

        volatiles.attacks -= 1;
        if (volatiles.attacks == 0) {
            volatiles.Thrashing = false;
            volatiles.Confusion = true;
            // SHOWDOWN: these values will diverge
            volatiles.confusion = @truncate(u3, if (showdown)
                battle.rng.range(u8, 3, 5)
            else
                (battle.rng.next() & 3) + 2);
            try log.start(ident, .ConfusionSilent);
        }
        return .skip_can;
    }

    if (volatiles.Trapping) {
        assert(volatiles.attacks > 0);
        volatiles.attacks -= 1;

        // Skip Decrement PP / calcDamage / checkHit
        _ = try applyDamage(battle, player.foe(), player.foe(), log);
        return .done;
    }

    return if (volatiles.Rage) .skip_pp else .ok;
}

fn canMove(
    battle: anytype,
    player: Player,
    choice: Choice,
    skip_pp: bool,
    miss: bool,
    from: ?Move,
    log: anytype,
) !bool {
    var side = battle.side(player);
    const player_ident = battle.active(player);
    const move = Move.get(side.last_selected_move);

    if (side.active.volatiles.Charging) {
        side.active.volatiles.Charging = false;
        side.active.volatiles.Invulnerable = false;
    } else if (move.effect == .Charge) {
        try log.move(player_ident, side.last_selected_move, .{}, from);
        try Effects.charge(battle, player, log);
        return false;
    }

    // SHOWDOWN: getting a "locked" move advances the RNG
    const special = if (from) |m| (m == .Metronome or m == .MirrorMove) else false;
    const locked = from != null and !special;
    if (showdown and locked) battle.rng.advance(1);

    side.last_used_move = side.last_selected_move;
    if (!skip_pp) decrementPP(side, choice);

    // SHOWDOWN: Metronome / Mirror Move call getRandomTarget if the move they're using targets
    if (showdown and special) {
        battle.rng.advance(if (side.last_selected_move.frames() > 0) 1 else 0);
    }

    const target_ident = battle.active(player.foe());
    try log.move(player_ident, side.last_selected_move, target_ident, from);

    if (move.effect.onBegin()) {
        try moveEffect(battle, player, move, choice.data, miss, log);
        return false;
    }

    if (move.effect == .Thrashing) {
        Effects.thrashing(battle, player);
    } else if (move.effect == .Trapping) {
        Effects.trapping(battle, player);
    }

    return true;
}

fn decrementPP(side: *Side, choice: Choice) void {
    assert(choice.type == .Move);
    assert(choice.data <= 4);

    if (choice.data == 0) return; // Struggle

    var active = &side.active;
    const volatiles = &active.volatiles;

    assert(!volatiles.Rage and !volatiles.Thrashing);
    if (volatiles.Bide or volatiles.MultiHit) return;

    active.move(choice.data).pp -%= 1;
    if (volatiles.Transform) return;

    side.stored().move(choice.data).pp -%= 1;
    assert(active.move(choice.data).pp == side.stored().move(choice.data).pp);
}

fn doMove(battle: anytype, player: Player, choice: Choice, missed: bool, log: anytype) !?Result {
    var side = battle.side(player);
    const foe = battle.foe(player);

    var move = Move.get(side.last_selected_move);

    // The cartridge handles set damage moves in applyDamage but we short circuit to simplify things
    if (move.effect == .SuperFang or move.effect == .SpecialDamage) {
        return specialDamage(battle, player, move, missed, log);
    }

    // Runs even for moves that can't crit (onEnd Status or moves like Counter/set damage/Metronome)
    const crit = checkCriticalHit(battle, player, move);

    // SHOWDOWN: showdown resets last_damage before counter instead of after
    if (showdown) battle.last_damage = 0;

    if (side.last_selected_move == .Counter) return counterDamage(battle, player, move, log);

    var ohko = false;
    var immune = false;
    battle.last_damage = 0;

    // Disassembly does a check to allow 0 BP MultiHit moves but this isn't possible in practice
    assert(move.effect != .MultiHit or move.bp > 0);
    if (move.bp != 0) {
        if (move.effect == .OHKO) {
            ohko = side.active.stats.spe >= foe.active.stats.spe;
            // This can overflow after adjustDamage, but will still be sufficient to OHKO
            battle.last_damage = if (ohko) 65535 else 0;
        } else if (!calcDamage(battle, player, player.foe(), move, crit)) {
            return @as(?Result, Result.Error);
        }
        immune = adjustDamage(battle, player);
        randomizeDamage(battle);
    }

    var miss = moveHit(battle, player, move) or battle.last_damage == 0 or missed;
    assert(miss or battle.last_damage > 0);
    assert(!(ohko and immune));
    assert(!immune or miss);

    if (move.effect == .MirrorMove) {
        return mirrorMove(battle, player, choice, miss, log);
    } else if (move.effect == .Metronome) {
        return metronome(battle, player, choice, miss, log);
    }

    if (move.effect.onEnd()) {
        try moveEffect(battle, player, move, choice.data, miss, log);
        return null;
    }

    if (miss) {
        const foe_ident = battle.active(player.foe());
        if (immune) {
            try log.immune(foe_ident, if (move.effect == .OHKO) .OHKO else .None);
        } else {
            try log.lastmiss();
            try log.miss(battle.active(player), foe_ident);
        }
        // SHOWDOWN: Pokémon Showdown does not inflict crash damage when attacking a Ghost
        if (move.effect == .JumpKick and !(showdown and immune)) {
            // GLITCH: Recoil is supposed to be damage/8 but damage will always be 0 here
            assert(battle.last_damage == 0);
            battle.last_damage = 1;
            _ = try applyDamage(battle, player, player.foe(), log);
        } else if (move.effect == .Explode) {
            try Effects.explode(battle, player);
            // SHOWDOWN: Pokémon Showdown does not build Rage after missing Self-Destruct/Explosion
            if (foe.stored().hp == 0 or showdown) return null;
            if (foe.active.volatiles.Rage and foe.active.boosts.atk < 6) {
                try Effects.boost(battle, player.foe(), Move.get(.Rage), log);
            }
        }
        return null;
    }

    if (move.effect.onEnd()) {
        try moveEffect(battle, player, move, choice.data, miss, log);
        return null;
    }

    // On the cartridge MultiHit doesn't get set up until after damage has been applied
    // for the first time but its more convenient and efficient to set it up here
    var max: u4 = 1;
    if (move.effect.isMulti()) {
        Effects.multiHit(battle, player, move);
        max = side.active.volatiles.attacks;
    }

    var nullified = false;
    var hits: u4 = 0;
    while (hits < max) : (hits += 1) {
        nullified = try applyDamage(battle, player.foe(), player.foe(), log);
        if (foe.active.volatiles.Rage and foe.active.boosts.atk < 6) {
            try Effects.boost(battle, player.foe(), Move.get(.Rage), log);
        }
        if (hits == 0) {
            if (crit) try log.crit(battle.active(player));
            if (ohko) try log.ohko();
        }
        // If the substitute breaks during a multi-hit attack, the attack ends
        if (nullified or foe.stored().hp == 0) break;
    }

    if (side.active.volatiles.MultiHit) {
        side.active.volatiles.MultiHit = false;
        assert(nullified or side.active.volatiles.attacks + hits == max);
        side.active.volatiles.attacks = 0;
        try log.hitcount(battle.active(player), hits);
    }

    // Substitute being broken nullifies the move's effect completely so even
    // if an effect was intended to "always happen" it will still get skipped.
    if (nullified) return null;

    // On the cartridge, "always happen" effect handlers are called in the applyDamage loop above,
    // but this is only done to setup the MultiHit looping in the first place. Moving the MultiHit
    // setup before the loop means we can avoid having to waste time doing no-op handler searches
    if (move.effect.alwaysHappens()) {
        try moveEffect(battle, player, move, choice.data, miss, log);
    }

    if (foe.stored().hp == 0) return null;

    if (!move.effect.isSpecial()) {
        // On the catridge Rage is not considered to be "special" and thus gets executed for a
        // second time here (after being executed in the "always happens" block above) but that
        // doesn't matter since its idempotent. For Twineedle we change the data to that of one
        //  with PoisonChance1 given its MultiHit behavior is complete after the loop above.
        if (move.effect == .Twineedle) move = Move.get(.PoisonSting);
        try moveEffect(battle, player, move, choice.data, miss, log);
    }

    return null;
}

fn checkCriticalHit(battle: anytype, player: Player, move: Move.Data) bool {
    const side = battle.side(player);

    var chance = @as(u16, Species.chance(side.active.species));

    // GLITCH: Focus Energy reduces critical hit chance instead of increasing it
    chance = if (side.active.volatiles.FocusEnergy)
        chance / 2
    else
        @minimum(chance * 2, 255);

    chance = if (move.effect == .HighCritical)
        @minimum(chance * 4, 255)
    else
        chance / 2;

    // SHOWDOWN: these values will diverge (due to rotations)
    if (showdown) return battle.rng.chance(u8, @truncate(u8, chance), 256);
    return std.math.rotl(u8, battle.rng.next(), 3) < chance;
}

fn calcDamage(
    battle: anytype,
    player: Player,
    target_player: Player,
    move: Move.Data,
    crit: bool,
) bool {
    assert(move.bp != 0);

    const side = battle.side(player);
    const target = battle.side(target_player);

    const special = move.type.special();

    // zig fmt: off
    var atk =
        if (crit)
            if (special) side.stored().stats.spc
            else side.stored().stats.atk
        else
            if (special) side.active.stats.spc
            else side.active.stats.atk;

    var def =
        if (crit)
            if (special) target.stored().stats.spc
            else target.stored().stats.def
        else
            // GLITCH: not capped to MAX_STAT_VALUE, can be 999 * 2 = 1998
            if (special)
                target.active.stats.spc * @as(u2, if (target.active.volatiles.LightScreen) 2 else 1)
            else
                target.active.stats.def * @as(u2, if (target.active.volatiles.Reflect) 2 else 1);
    // zig fmt: on

    if (atk > 255 or def > 255) {
        atk = @maximum((atk / 4) & 255, 1);
        // GLITCH: not adjusted to be a min of 1 on cartridge (can lead to division-by-zero freeze)
        def = @maximum((def / 4) & 255, if (showdown) 1 else 0);
    }

    const lvl = @as(u16, side.stored().level * @as(u2, if (crit) 2 else 1));

    def = if (move.effect == .Explode) @maximum(def / 2, 1) else def;

    if (def == 0) return false;
    battle.last_damage = @minimum(997, ((lvl * 2 / 5) + 2) *% move.bp *% atk / def / 50) + 2;
    return true;
}

fn adjustDamage(battle: anytype, player: Player) bool {
    const side = battle.side(player);
    const foe = battle.foe(player);
    const move = Move.get(side.last_selected_move);

    var d = battle.last_damage;
    if (side.active.types.includes(move.type)) d *%= 2;

    const type1 = @enumToInt(move.type.effectiveness(foe.active.types.type1));
    const type2 = @enumToInt(move.type.effectiveness(foe.active.types.type2));

    d = d *% type1 / 10;
    d = d *% type2 / 10;

    battle.last_damage = d;

    return type1 == 0 or type2 == 0;
}

fn randomizeDamage(battle: anytype) void {
    if (battle.last_damage <= 1) return;

    // SHOWDOWN: these values will diverge
    const random = if (showdown)
        battle.rng.range(u8, 217, 256)
    else loop: {
        while (true) {
            const r = battle.rng.next();
            if (r >= 217) break :loop r;
        }
    };

    battle.last_damage = battle.last_damage *% random / 255;
}

fn specialDamage(
    battle: anytype,
    player: Player,
    move: Move.Data,
    miss: bool,
    log: anytype,
) !?Result {
    const side = battle.side(player);

    if (!try checkHit(battle, player, move, miss, log)) return null;

    battle.last_damage = switch (side.last_selected_move) {
        .SuperFang => @maximum(battle.foe(player).active.stats.hp / 2, 1),
        .SeismicToss, .NightShade => side.stored().level,
        .SonicBoom => 20,
        .DragonRage => 40,
        // GLITCH: if power = 0 then a desync occurs (or a miss on Pokémon Showdown)
        .Psywave => power: {
            const max = @truncate(u8, @as(u16, side.stored().level) * 3 / 2);
            // SHOWDOWN: these values will diverge
            if (showdown) {
                break :power battle.rng.range(u8, 0, max);
            } else {
                while (true) {
                    const r = battle.rng.next();
                    if (r < max) break :power r;
                }
            }
        },
        else => unreachable,
    };

    if (battle.last_damage == 0) {
        if (showdown) {
            try log.lastmiss();
            try log.miss(battle.active(player), battle.active(player.foe()));
            return null;
        } else {
            return Result.Error;
        }
    }

    _ = try applyDamage(battle, player.foe(), player.foe(), log);
    return null;
}

// FIXME: Counter selected vs used Desync
fn counterDamage(battle: anytype, player: Player, move: Move.Data, log: anytype) !?Result {
    const foe = battle.foe(player);
    const foe_last_move = Move.get(foe.last_selected_move);
    const miss = foe_last_move.bp == 0 or
        foe.last_selected_move == .Counter or
        foe_last_move.type != .Normal or
        foe_last_move.type != .Fighting or
        battle.last_damage == 0;

    if (miss) {
        try log.fail(battle.active(player), .None);
        return null;
    }

    battle.last_damage = if (battle.last_damage > 0x7FFF) 0xFFFF else battle.last_damage * 2;

    if (!try checkHit(battle, player, move, false, log)) return null;

    _ = try applyDamage(battle, player.foe(), player.foe(), log);
    return null;
}

fn applyDamage(battle: anytype, target_player: Player, sub_player: Player, log: anytype) !bool {
    assert(battle.last_damage != 0);

    var target = battle.side(target_player);
    // GLITCH: Substitute + Confusion glitch
    // We check if the target has a Substitute but then apply damage to the "sub player" which
    // isn't guaranteed to be the same (eg. crash or confusion damage) or to even have a Substitute
    if (target.active.volatiles.Substitute) {
        var subbed = battle.side(sub_player);
        assert(subbed.active.volatiles.Substitute or subbed.active.volatiles.substitute == 0);
        if (battle.last_damage >= subbed.active.volatiles.substitute) {
            subbed.active.volatiles.substitute = 0;
            subbed.active.volatiles.Substitute = false;
            // GLITCH: battle.last_damage is not updated with the amount of HP the Substitute had
            try log.end(battle.active(sub_player), .Substitute);
            return true;
        } else {
            // Safe to truncate since less than subbed.volatiles.substitute which is a u8
            subbed.active.volatiles.substitute -= @truncate(u8, battle.last_damage);
            try log.activate(battle.active(sub_player), .Substitute);
        }
    } else {
        if (battle.last_damage > target.stored().hp) battle.last_damage = target.stored().hp;
        target.stored().hp -= battle.last_damage;
        try log.damage(battle.active(target_player), target.stored(), .None);
    }
    return false;
}

fn mirrorMove(battle: anytype, player: Player, choice: Choice, miss: bool, log: anytype) !?Result {
    var side = battle.side(player);
    const foe = battle.foe(player);

    if (foe.last_used_move == .None or foe.last_used_move == .MirrorMove) {
        try log.lastmiss();
        try log.miss(battle.active(player), battle.active(player.foe()));
        return null;
    }

    side.last_selected_move = foe.last_used_move;

    if (!try canMove(battle, player, choice, true, miss, .MirrorMove, log)) return null;
    return doMove(battle, player, choice, miss, log);
}

fn metronome(battle: anytype, player: Player, choice: Choice, miss: bool, log: anytype) !?Result {
    var side = battle.side(player);

    // SHOWDOWN: these values will diverge
    side.last_selected_move = if (showdown) blk: {
        const r = battle.rng.range(u8, 0, @enumToInt(Move.Struggle) - 1);
        break :blk @intToEnum(Move, r + @as(u2, (if (r < @enumToInt(Move.Metronome)) 1 else 2)));
    } else loop: {
        while (true) {
            const r = battle.rng.next();
            if (r == 0 or r == @enumToInt(Move.Metronome)) continue;
            if (r >= @enumToInt(Move.Struggle)) continue;
            break :loop @intToEnum(Move, r);
        }
    };

    if (!try canMove(battle, player, choice, true, miss, .Metronome, log)) return null;
    return doMove(battle, player, choice, miss, log);
}

fn checkHit(battle: anytype, player: Player, move: Move.Data, missed: bool, log: anytype) !bool {
    const miss = moveHit(battle, player, move) or missed;
    if (miss) {
        try log.lastmiss();
        try log.miss(battle.active(player), battle.active(player.foe()));
    }
    return miss;
}

fn moveHit(battle: anytype, player: Player, move: Move.Data) bool {
    var side = battle.side(player);
    const foe = battle.foe(player);

    const miss = miss: {
        assert(!side.active.volatiles.Bide);

        if (move.effect == .DreamEater and !Status.is(foe.stored().status, .SLP)) break :miss true;
        if (move.effect == .Swift) break :miss false;
        if (foe.active.volatiles.Invulnerable) break :miss true;

        // Conversion / Haze / Light Screen / Reflect qualify but do not call moveHit
        if (foe.active.volatiles.Mist and move.effect.isStatDown()) break :miss true;

        // GLITCH: Thrash / Petal Dance / Rage get their accuracy overwritten on subsequent hits
        const overwritten = side.active.volatiles.state > 0;
        assert(!overwritten or (move.effect == .Thrashing or move.effect == .Rage));
        var accuracy = if (!showdown and overwritten)
            side.active.volatiles.state
        else
            @as(u16, Gen12.percent(move.accuracy()));
        var boost = BOOSTS[@intCast(u4, side.active.boosts.accuracy + 6)];
        accuracy = accuracy * boost[0] / boost[1];
        boost = BOOSTS[@intCast(u4, -foe.active.boosts.evasion + 6)];
        accuracy = accuracy * boost[0] / boost[1];
        accuracy = @minimum(255, @maximum(1, accuracy));

        side.active.volatiles.state = accuracy;

        // GLITCH: max accuracy is 255 so 1/256 chance of miss
        break :miss if (showdown)
            !battle.rng.chance(u8, @truncate(u8, accuracy), 256)
        else
            battle.rng.next() >= accuracy;
    };

    if (miss) {
        battle.last_damage = 0;
        side.active.volatiles.Trapping = false;
    }

    return !miss;
}

fn checkFaint(
    battle: anytype,
    player: Player,
    player_locked: bool,
    foe_locked: bool,
    log: anytype,
) @TypeOf(log).Error!?Result {
    var side = battle.side(player);
    if (side.stored().hp > 0) return null;

    var foe = battle.foe(player);
    var foe_fainted = foe.stored().hp == 0;
    if (try faint(battle, player, log, !foe_fainted)) |r| return r;
    if (foe_fainted) if (try faint(battle, player.foe(), log, true)) |r| return r;

    const player_out = findFirstAlive(side) == 0;
    const foe_out = findFirstAlive(foe) == 0;
    if (player_out and foe_out) return Result.Tie;
    if (player_out) return if (player == .P1) Result.Lose else Result.Win;
    if (foe_out) return if (player == .P1) Result.Win else Result.Lose;

    // SHOWDOWN: emitting |request| for sides will advance the RNG by 2 for each "locked" move
    const locked = @as(u2, @boolToInt(player_locked)) +
        @as(u2, (if (foe_fainted) @boolToInt(foe_locked) else 0));
    if (showdown) battle.rng.advance(locked * 2);

    const foe_choice: Choice.Type = if (foe_fainted) .Switch else .Pass;
    if (player == .P1) return Result{ .p1 = .Switch, .p2 = foe_choice };
    return Result{ .p1 = foe_choice, .p2 = .Switch };
}

fn faint(battle: anytype, player: Player, log: anytype, done: bool) !?Result {
    var side = battle.side(player);
    var foe = battle.foe(player);
    assert(side.stored().hp == 0);

    var foe_volatiles = &foe.active.volatiles;
    foe_volatiles.MultiHit = false;
    if (foe_volatiles.Bide) {
        foe_volatiles.state = if (showdown) 0 else foe_volatiles.state & 255;
        if (foe_volatiles.state != 0) return Result.Error;
    }

    side.active.volatiles = .{};
    side.last_used_move = .None;
    try log.faint(battle.active(player), done);
    return null;
}

fn handleResidual(battle: anytype, player: Player, log: anytype) !void {
    var side = battle.side(player);
    var stored = side.stored();
    const ident = battle.active(player);
    var volatiles = &side.active.volatiles;

    const brn = Status.is(stored.status, .BRN);
    if (brn or Status.is(stored.status, .PSN)) {
        var damage = @maximum(stored.stats.hp / 16, 1);

        if (volatiles.Toxic) {
            volatiles.toxic += 1;
            damage *= volatiles.toxic;
        }

        stored.hp -= @minimum(damage, stored.hp);
        // Pokémon Showdown uses damageOf here but its not relevant in Generation I
        try log.damage(ident, stored, if (brn) Damage.Burn else Damage.Poison);
    }

    if (volatiles.LeechSeed) {
        var damage = @maximum(stored.stats.hp / 16, 1);

        // GLITCH: Leech Seed + Toxic glitch
        if (volatiles.Toxic) {
            volatiles.toxic += 1;
            damage *= volatiles.toxic;
        }

        stored.hp -= @minimum(damage, stored.hp);

        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = battle.active(player.foe());

        try log.damageOf(ident, stored, .LeechSeedOf, foe_ident);

        // GLITCH: uncapped damage is added back to the foe
        foe_stored.hp = @minimum(foe_stored.hp + damage, foe_stored.stats.hp);
        try log.drain(foe_ident, foe_stored, ident);
    }
}

fn endTurn(battle: anytype, log: anytype, locked: u8) @TypeOf(log).Error!Result {
    if (showdown and checkEBC(battle)) {
        try log.tie();
        return Result.Tie;
    }

    battle.turn += 1;
    try log.turn(battle.turn);
    // SHOWDOWN: emitting |request| for sides will advance the RNG by 2 for each "locked" move
    if (showdown) battle.rng.advance(locked * 2);

    if (showdown) {
        if (battle.turn < 1000) return Result.Default;
        try log.tie();
        return Result.Tie;
    } else {
        return if (battle.turn >= 65535) Result.Error else Result.Default;
    }
}

fn checkEBC(battle: anytype) bool {
    ebc: for (battle.sides) |side, i| {
        var foe_all_ghosts = true;
        var foe_all_transform = true;

        for (battle.sides[~@truncate(u1, i)].pokemon) |pokemon| {
            if (pokemon.species == .None) continue;

            const ghost = pokemon.hp == 0 or pokemon.types.includes(.Ghost);
            foe_all_ghosts = foe_all_ghosts and ghost;
            foe_all_transform = foe_all_transform and pokemon.hp == 0 or transform: {
                for (pokemon.moves) |m| {
                    if (m.id == .None) break :transform true;
                    if (m.id != .Transform) break :transform false;
                }
                break :transform true;
            };
        }

        for (side.pokemon) |pokemon| {
            if (pokemon.hp == 0 or Status.is(pokemon.status, .FRZ)) continue;
            const transform = foe_all_transform and transform: {
                for (pokemon.moves) |m| {
                    if (m.id == .None) break :transform true;
                    if (m.id != .Transform) break :transform false;
                }
                break :transform true;
            };
            if (transform) continue;
            const no_pp = foe_all_ghosts and no_pp: {
                for (pokemon.moves) |m| {
                    if (m.pp != 0) break :no_pp false;
                }
                break :no_pp true;
            };
            if (no_pp) continue;

            continue :ebc;
        }

        return true;
    }

    return false;
}

fn moveEffect(
    battle: anytype,
    player: Player,
    move: Move.Data,
    mslot: u8,
    miss: bool,
    log: anytype,
) !void {
    return switch (move.effect) {
        .Bide => Effects.bide(battle, player, log),
        .BurnChance1, .BurnChance2 => Effects.burnChance(battle, player, move, log),
        .Confusion, .ConfusionChance => Effects.confusion(battle, player, move, miss, log),
        .Conversion => Effects.conversion(battle, player, log),
        .Disable => Effects.disable(battle, player, move, miss, log),
        .DrainHP, .DreamEater => Effects.drainHP(battle, player, log),
        .Explode => Effects.explode(battle, player),
        .FlinchChance1, .FlinchChance2 => Effects.flinchChance(battle, player, move),
        .FocusEnergy => Effects.focusEnergy(battle, player, log),
        .FreezeChance => Effects.freezeChance(battle, player, move, log),
        .Haze => Effects.haze(battle, player, log),
        .Heal => Effects.heal(battle, player, log),
        .HyperBeam => Effects.hyperBeam(battle, player),
        .LeechSeed => Effects.leechSeed(battle, player, move, miss, log),
        .LightScreen => Effects.lightScreen(battle, player, log),
        .Mimic => Effects.mimic(battle, player, move, mslot, miss, log),
        .Mist => Effects.mist(battle, player, log),
        .MultiHit, .DoubleHit, .Twineedle => Effects.multiHit(battle, player, move),
        .Paralyze => Effects.paralyze(battle, player, move, miss, log),
        .ParalyzeChance1, .ParalyzeChance2 => Effects.paralyzeChance(battle, player, move, log),
        .PayDay => Effects.payDay(log),
        .Poison, .PoisonChance1, .PoisonChance2 => Effects.poison(battle, player, move, miss, log),
        .Rage => Effects.rage(battle, player),
        .Recoil => Effects.recoil(battle, player, log),
        .Reflect => Effects.reflect(battle, player, log),
        .Sleep => Effects.sleep(battle, player, move, miss, log),
        .Splash => Effects.splash(battle, player, log),
        .Substitute => Effects.substitute(battle, player, log),
        .Transform => Effects.transform(battle, player, log),
        // zig fmt: off
        .AttackUp1, .AttackUp2, .DefenseUp1, .DefenseUp2,
        .EvasionUp1, .SpecialUp1, .SpecialUp2, .SpeedUp2 =>
            Effects.boost(battle, player, move, log),
        .AccuracyDown1, .AttackDown1, .DefenseDown1, .DefenseDown2, .SpeedDown1,
        .AttackDownChance, .DefenseDownChance, .SpecialDownChance, .SpeedDownChance =>
            Effects.unboost(battle, player, move, miss, log),
        // zig fmt: on
        else => {},
    };
}

pub const Effects = struct {
    fn bide(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);

        side.active.volatiles.Bide = true;
        side.active.volatiles.state = 0;
        // SHOWDOWN: these values will diverge
        side.active.volatiles.attacks = @truncate(u3, if (showdown)
            // SHOWDOWN: this will (incorrectly) always return 2
            battle.rng.range(u4, 3, 4) - 1
        else
            (battle.rng.next() & 1) + 2);

        try log.start(battle.active(player), .Bide);
    }

    fn burnChance(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();

        if (Status.is(foe_stored.status, .FRZ)) {
            assert(move.type == .Fire);
            foe_stored.status = 0;
        }

        const cant = foe.active.volatiles.Substitute or Status.any(foe_stored.status);
        if (cant) return log.fail(battle.active(player.foe()), .Burn);

        const chance = !foe.active.types.includes(move.type) and if (showdown)
            battle.rng.chance(u8, @as(u8, if (move.effect == .BurnChance1) 26 else 77), 256)
        else
            battle.rng.next() < 1 + (if (move.effect == .BurnChance1)
                Gen12.percent(10)
            else
                Gen12.percent(30));
        if (!chance) return;

        foe_stored.status = Status.init(.BRN);
        foe.active.stats.atk = @maximum(foe.active.stats.atk / 2, 1);

        try log.status(battle.active(player.foe()), foe_stored.status, .None);
    }

    fn charge(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        var volatiles = &side.active.volatiles;

        volatiles.Charging = true;
        const move = side.last_selected_move;
        if (move == .Fly or move == .Dig) volatiles.Invulnerable = true;
        try log.prepare(battle.active(player), move);
    }

    fn confusion(
        battle: anytype,
        player: Player,
        move: Move.Data,
        miss: bool,
        log: anytype,
    ) !void {
        var foe = battle.foe(player);

        if (move.effect == .ConfusionChance) {
            const chance = if (showdown)
                // SHOWDOWN: this diverges because Pokémon Showdown uses 26 instead of 25
                battle.rng.chance(u8, 26, 256)
            else
                battle.rng.next() < Gen12.percent(10);
            if (!chance) return;
        } else if (foe.active.volatiles.Substitute or
            !try checkHit(battle, player, move, miss, log)) return;

        if (foe.active.volatiles.Confusion) return;
        foe.active.volatiles.Confusion = true;

        // SHOWDOWN: these values will diverge
        foe.active.volatiles.confusion = @truncate(u3, if (showdown)
            battle.rng.range(u8, 2, 6)
        else
            (battle.rng.next() & 3) + 2);

        try log.start(battle.active(player.foe()), .Confusion);
    }

    fn conversion(battle: anytype, player: Player, log: anytype) !void {
        const foe = battle.foe(player);

        if (foe.active.volatiles.Invulnerable) {
            return log.miss(battle.active(player), battle.active(player.foe()));
        }

        battle.side(player).active.types = foe.active.types;
        return log.typechange(battle.active(player), foe.active.types);
    }

    fn disable(battle: anytype, player: Player, move: Move.Data, miss: bool, log: anytype) !void {
        var foe = battle.foe(player);
        var volatiles = &foe.active.volatiles;
        const foe_ident = battle.active(player.foe());

        if (!moveHit(battle, player, move) or miss or volatiles.disabled.move != 0) {
            try log.lastmiss();
            return log.miss(battle.active(player), foe_ident);
        }

        const moves = &foe.active.moves;
        volatiles.disabled.move = randomMoveSlot(&battle.rng, moves);

        // SHOWDOWN: these values will diverge
        volatiles.disabled.duration = @truncate(u4, if (showdown)
            battle.rng.range(u8, 1, 7) + 1 // FIXME: 2-7, not 2-9 or 1-8
        else
            (battle.rng.next() & 7) + 1);

        try log.startEffect(foe_ident, .Disable, moves[volatiles.disabled.move].id);
    }

    fn drainHP(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        var stored = side.stored();

        const drain = @maximum(battle.last_damage / 2, 1);
        battle.last_damage = drain;
        stored.hp = @minimum(stored.stats.hp, stored.hp + drain);

        try log.drain(battle.active(player), stored, battle.active(player.foe()));
    }

    fn explode(battle: anytype, player: Player) !void {
        var side = battle.side(player);
        var stored = side.stored();

        stored.hp = 0;
        stored.status = 0;
        side.active.volatiles.LeechSeed = false;
    }

    fn flinchChance(battle: anytype, player: Player, move: Move.Data) void {
        var volatiles = &battle.foe(player).active.volatiles;

        if (volatiles.Substitute) return;

        const chance = if (showdown)
            battle.rng.chance(u8, @as(u8, if (move.effect == .FlinchChance1) 26 else 77), 256)
        else
            battle.rng.next() < 1 + (if (move.effect == .FlinchChance1)
                Gen12.percent(10)
            else
                Gen12.percent(30));
        if (!chance) return;

        volatiles.Flinch = true;
        volatiles.Recharging = false;
    }

    fn focusEnergy(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);

        if (side.active.volatiles.FocusEnergy) return;
        side.active.volatiles.FocusEnergy = true;

        try log.start(battle.active(player), .FocusEnergy);
    }

    fn freezeChance(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = battle.active(player.foe());

        const cant = foe.active.volatiles.Substitute or Status.any(foe_stored.status);
        if (cant) return log.fail(foe_ident, .Freeze);

        const chance = !foe.active.types.includes(move.type) and if (showdown)
            battle.rng.chance(u8, 26, 256)
        else
            battle.rng.next() < 1 + Gen12.percent(10);
        if (!chance) return;

        // SHOWDOWN: Freeze Clause Mod
        if (showdown) {
            for (foe.pokemon) |p| {
                if (Status.is(p.status, .FRZ)) return log.fail(foe_ident, .Freeze);
            }
        }

        foe_stored.status = Status.init(.FRZ);
        // GLITCH: Hyper Beam recharging status is not cleared

        try log.status(foe_ident, foe_stored.status, .None);
    }

    // FIXME: handle showdown bugginess...
    fn haze(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        var foe = battle.foe(player);

        var side_stored = side.stored();
        var foe_stored = foe.stored();

        const player_ident = battle.active(player);
        const foe_ident = battle.active(player.foe());

        side.active.boosts = .{};
        foe.active.boosts = .{};

        side.active.stats = side_stored.stats;
        foe.active.stats = foe_stored.stats;

        try log.activate(player_ident, .Haze);
        try log.clearallboost();

        if (Status.any(foe_stored.status)) {
            if (Status.is(foe_stored.status, .FRZ) or Status.is(foe_stored.status, .SLP)) {
                foe.last_selected_move = .SKIP_TURN;
            }

            try log.curestatus(foe_ident, foe_stored.status, .Silent);
            foe_stored.status = 0;
        }

        try clearVolatiles(&side.active, player_ident, log);
        try clearVolatiles(&foe.active, foe_ident, log);
    }

    fn heal(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        var stored = side.stored();
        const ident = battle.active(player);

        // GLITCH: HP recovery move failure glitches
        const delta = stored.stats.hp - stored.hp;
        if (delta == 0 or delta & 255 == 255) return;

        if (side.last_selected_move == .Rest) {
            stored.status = Status.slf(2);
            try log.statusFrom(ident, stored.status, Move.Rest);
            stored.hp = stored.stats.hp;
        } else {
            stored.hp = @maximum(stored.stats.hp, stored.hp + (stored.stats.hp / 2));
        }
        try log.heal(ident, stored, .None);
    }

    fn hyperBeam(battle: anytype, player: Player) !void {
        battle.side(player).active.volatiles.Recharging = true;
    }

    fn leechSeed(
        battle: anytype,
        player: Player,
        move: Move.Data,
        miss: bool,
        log: anytype,
    ) !void {
        var foe = battle.foe(player);

        if (!try checkHit(battle, player, move, miss, log)) return;
        if (foe.active.types.includes(.Grass) or foe.active.volatiles.LeechSeed) {
            return log.immune(battle.active(player.foe()), .None);
        }
        foe.active.volatiles.LeechSeed = true;

        try log.start(battle.active(player.foe()), .LeechSeed);
    }

    fn lightScreen(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);

        if (side.active.volatiles.LightScreen) return log.fail(battle.active(player), .None);
        side.active.volatiles.LightScreen = true;

        try log.start(battle.active(player), .LightScreen);
    }

    fn mimic(
        battle: anytype,
        player: Player,
        move: Move.Data,
        mslot: u8,
        miss: bool,
        log: anytype,
    ) !void {
        var side = battle.side(player);
        var foe = battle.foe(player);

        // SHOWDOWN: Pokémon Showdown requires the user has Mimic (but not necessarily at mslot)
        const ok = !showdown or has_mimic: {
            for (side.active.moves) |m| {
                if (m.id == .Mimic) break :has_mimic true;
            }
            break :has_mimic false;
        };

        // In reality, Mimic can also be called via Metronome or Mirror Move
        assert(showdown or side.active.moves[mslot].id == .Mimic or
            side.active.moves[mslot].id == .Metronome or
            side.active.moves[mslot].id == .MirrorMove);

        if (!try checkHit(battle, player, move, miss, log) or !ok) return;

        const moves = &foe.active.moves;
        const rslot = randomMoveSlot(&battle.rng, moves);

        side.active.moves[mslot].id = moves[rslot].id;

        try log.startEffect(battle.active(player), .Mimic, moves[rslot].id);
    }

    fn mist(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);

        if (side.active.volatiles.Mist) return;
        side.active.volatiles.Mist = true;

        try log.start(battle.active(player), .Mist);
    }

    fn multiHit(battle: anytype, player: Player, move: Move.Data) void {
        var side = battle.side(player);

        assert(!side.active.volatiles.MultiHit);
        side.active.volatiles.MultiHit = true;

        side.active.volatiles.attacks = if (move.effect == .MultiHit) distribution(battle) else 2;
    }

    fn paralyze(battle: anytype, player: Player, move: Move.Data, miss: bool, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = battle.active(player.foe());

        if (Status.any(foe_stored.status)) return log.fail(foe_ident, .Paralysis);
        if (foe.active.types.immune(move.type)) return log.immune(foe_ident, .None);
        if (!try checkHit(battle, player, move, miss, log)) return;

        foe_stored.status = Status.init(.PAR);
        foe.active.stats.spe = @maximum(foe.active.stats.spe / 4, 1);

        try log.status(foe_ident, foe_stored.status, .None);
    }

    fn paralyzeChance(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();

        const cant = foe.active.volatiles.Substitute or Status.any(foe_stored.status);
        if (cant) return log.fail(battle.active(player.foe()), .Paralysis);

        // Body Slam can't paralyze a Normal type Pokémon
        const chance = !foe.active.types.includes(move.type) and if (showdown)
            battle.rng.chance(u8, @as(u8, if (move.effect == .ParalyzeChance1) 26 else 77), 256)
        else
            battle.rng.next() < 1 + (if (move.effect == .ParalyzeChance1)
                Gen12.percent(10)
            else
                Gen12.percent(30));
        if (!chance) return;

        foe_stored.status = Status.init(.PAR);
        foe.active.stats.spe = @maximum(foe.active.stats.spe / 4, 1);

        try log.status(battle.active(player.foe()), foe_stored.status, .None);
    }

    fn payDay(log: anytype) !void {
        try log.fieldactivate();
    }

    fn poison(battle: anytype, player: Player, move: Move.Data, miss: bool, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = battle.active(player.foe());

        const cant = foe.active.volatiles.Substitute or
            Status.any(foe_stored.status) or
            foe.active.types.includes(.Poison);

        if (cant) return log.fail(foe_ident, .Poison);

        if (move.effect == .Poison) {
            if (!try checkHit(battle, player, move, miss, log)) return;
        } else {
            const chance = if (showdown)
                battle.rng.chance(u8, @as(u8, if (move.effect == .PoisonChance1) 52 else 103), 256)
            else
                battle.rng.next() < 1 + (if (move.effect == .PoisonChance1)
                    Gen12.percent(20)
                else
                    Gen12.percent(40));
            if (!chance) return;
        }

        foe_stored.status = Status.init(.PSN);
        if (foe.last_selected_move == .Toxic) {
            foe.active.volatiles.Toxic = true;
            foe.active.volatiles.toxic = 0;
        }

        try log.status(foe_ident, foe_stored.status, .None);
    }

    fn rage(battle: anytype, player: Player) !void {
        battle.side(player).active.volatiles.Rage = true;
    }

    fn recoil(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        var stored = side.stored();

        const damage = battle.last_damage /
            @as(u8, if (side.last_selected_move == .Struggle) 2 else 4);
        stored.hp = @maximum(stored.hp - damage, 0);

        try log.damageOf(battle.active(player), stored, .RecoilOf, battle.active(player.foe()));
    }

    fn reflect(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);

        if (side.active.volatiles.Reflect) return log.fail(battle.active(player), .None);
        side.active.volatiles.Reflect = true;

        try log.start(battle.active(player), .Reflect);
    }

    fn sleep(battle: anytype, player: Player, move: Move.Data, miss: bool, log: anytype) !void {
        var foe = battle.foe(player);
        var foe_stored = foe.stored();
        const foe_ident = battle.active(player.foe());

        if (foe.active.volatiles.Recharging) {
            foe.active.volatiles.Recharging = false;
            // Hit test not applied if the target is recharging (bypass)
        } else {
            if (Status.any(foe_stored.status)) return log.fail(foe_ident, .Sleep);
            if (!try checkHit(battle, player, move, miss, log)) return;
        }

        // SHOWDOWN: these values will diverge
        const duration = @truncate(u3, if (showdown)
            battle.rng.range(u8, 1, 8)
        else loop: {
            while (true) {
                const r = battle.rng.next() & 7;
                if (r != 0) break :loop r;
            }
        });

        // SHOWDOWN: Sleep Clause Mod
        if (showdown) {
            for (foe.pokemon) |p| {
                if (Status.is(p.status, .SLP) and !Status.is(p.status, .SLF)) {
                    return log.fail(foe_ident, .Sleep);
                }
            }
        }

        foe_stored.status = Status.slp(duration);
        try log.statusFrom(foe_ident, foe_stored.status, battle.side(player).last_selected_move);
    }

    fn splash(battle: anytype, player: Player, log: anytype) !void {
        try log.activate(battle.active(player), .Splash);
    }

    fn substitute(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        if (side.active.volatiles.Substitute) {
            try log.fail(battle.active(player), .Substitute);
            return;
        }

        assert(side.stored().stats.hp <= 1023);
        // Will be 0 if HP is <= 3 meaning that the user gets a 1 HP Substitute for "free"
        const hp = @truncate(u8, side.stored().stats.hp / 4);
        if (side.stored().hp < hp) {
            try log.fail(battle.active(player), .Weak);
            return;
        }

        // GLITCH: can leave the user with 0 HP (faints later) because didn't check '<=' above
        side.stored().hp -= hp;
        side.active.volatiles.substitute = hp + 1;
        side.active.volatiles.Substitute = true;
        try log.start(battle.active(player), .Substitute);
    }

    fn thrashing(battle: anytype, player: Player) void {
        var volatiles = &battle.side(player).active.volatiles;

        volatiles.Thrashing = true;
        // SHOWDOWN: these values will diverge
        volatiles.attacks = @truncate(u3, if (showdown)
            battle.rng.range(u8, 2, 4)
        else
            (battle.rng.next() & 1) + 2);
    }

    fn transform(battle: anytype, player: Player, log: anytype) !void {
        var side = battle.side(player);
        const foe = battle.foe(player);
        const foe_ident = battle.active(player.foe());

        if (foe.active.volatiles.Invulnerable) return;

        side.active.volatiles.Transform = true;
        // foe could themselves be transformed
        side.active.volatiles.transform = if (foe.active.volatiles.transform != 0)
            foe.active.volatiles.transform
        else
            foe_ident.int();

        // HP is not copied by Transform
        side.active.stats.atk = foe.active.stats.atk;
        side.active.stats.def = foe.active.stats.def;
        side.active.stats.spe = foe.active.stats.spe;
        side.active.stats.spc = foe.active.stats.spc;

        side.active.species = foe.active.species;
        side.active.types = foe.active.types;
        side.active.boosts = foe.active.boosts;
        for (foe.active.moves) |m, i| {
            side.active.moves[i].id = m.id;
            side.active.moves[i].pp = if (m.id != .None) 5 else 0;
        }

        try log.transform(battle.active(player), foe_ident);
    }

    fn trapping(battle: anytype, player: Player) void {
        var side = battle.side(player);
        var foe = battle.foe(player);

        if (side.active.volatiles.Trapping) return;
        side.active.volatiles.Trapping = true;
        // Recharging is cleared even if the trapping move misses
        foe.active.volatiles.Recharging = false;

        side.active.volatiles.attacks = distribution(battle);
    }

    fn boost(battle: anytype, player: Player, move: Move.Data, log: anytype) !void {
        var side = battle.side(player);
        const ident = battle.active(player);

        var stats = &side.active.stats;
        var boosts = &side.active.boosts;

        switch (move.effect) {
            .AttackUp1, .AttackUp2, .Rage => {
                assert(boosts.atk >= -6 and boosts.atk <= 6);
                const n: u2 = if (move.effect == .AttackUp2) 2 else 1;
                boosts.atk = @minimum(6, boosts.atk + n);
                var mod = BOOSTS[@intCast(u4, boosts.atk + 6)];
                const stat = unmodifiedStats(battle, player).atk;
                stats.atk = @minimum(MAX_STAT_VALUE, stat * mod[0] / mod[1]);
                try log.boost(ident, if (move.effect == .Rage) .Rage else .Attack, n);
            },
            .DefenseUp1, .DefenseUp2 => {
                assert(boosts.def >= -6 and boosts.def <= 6);
                const n: u2 = if (move.effect == .DefenseUp2) 2 else 1;
                boosts.def = @minimum(6, boosts.def + n);
                var mod = BOOSTS[@intCast(u4, boosts.def + 6)];
                const stat = unmodifiedStats(battle, player).def;
                stats.def = @minimum(MAX_STAT_VALUE, stat * mod[0] / mod[1]);
                try log.boost(ident, .Defense, n);
            },
            .SpeedUp2 => {
                assert(boosts.spe >= -6 and boosts.spe <= 6);
                boosts.spe = @minimum(6, boosts.spe + 1);
                var mod = BOOSTS[@intCast(u4, boosts.spe + 6)];
                const stat = unmodifiedStats(battle, player).spe;
                stats.spe = @minimum(MAX_STAT_VALUE, stat * mod[0] / mod[1]);
                try log.boost(ident, .Speed, 1);
            },
            .SpecialUp1, .SpecialUp2 => {
                assert(boosts.spc >= -6 and boosts.spc <= 6);
                const n: u2 = if (move.effect == .SpecialUp2) 2 else 1;
                boosts.spc = @minimum(6, boosts.spc + n);
                var mod = BOOSTS[@intCast(u4, boosts.spc + 6)];
                const stat = unmodifiedStats(battle, player).spc;
                stats.spc = @minimum(MAX_STAT_VALUE, stat * mod[0] / mod[1]);
                try log.boost(ident, .SpecialAttack, n);
                try log.boost(ident, .SpecialDefense, n);
            },
            .EvasionUp1 => {
                assert(boosts.evasion >= -6 and boosts.evasion <= 6);
                boosts.evasion = @minimum(6, boosts.evasion + 1);
                try log.boost(ident, .Evasion, 1);
            },
            else => unreachable,
        }

        // GLITCH: Stat modification errors glitch
        statusModify(battle.foe(player).stored().status, stats);
    }

    fn unboost(battle: anytype, player: Player, move: Move.Data, miss: bool, log: anytype) !void {
        var foe = battle.foe(player);
        const foe_ident = battle.active(player.foe());

        if (foe.active.volatiles.Substitute) return;

        if (move.effect.isStatDownChance()) {
            const chance = if (showdown)
                battle.rng.chance(u8, 85, 256)
            else
                battle.rng.next() < Gen12.percent(33) + 1;
            if (chance or foe.active.volatiles.Invulnerable) return;
        } else if (!try checkHit(battle, player, move, miss, log)) {
            return; // checkHit already checks for Invulnerable
        }

        var stats = &foe.active.stats;
        var boosts = &foe.active.boosts;

        switch (move.effect) {
            .AttackDown1, .AttackDownChance => {
                assert(boosts.atk >= -6 and boosts.atk <= 6);
                boosts.atk = @maximum(-6, boosts.atk - 1);
                var mod = BOOSTS[@intCast(u4, boosts.atk + 6)];
                const stat = unmodifiedStats(battle, player.foe()).atk;
                stats.atk = @maximum(1, @minimum(MAX_STAT_VALUE, stat * mod[0] / mod[1]));
                try log.unboost(foe_ident, .Attack, 1);
            },
            .DefenseDown1, .DefenseDown2, .DefenseDownChance => {
                assert(boosts.atk >= -6 and boosts.atk <= 6);
                const n: u2 = if (move.effect == .DefenseDown2) 2 else 1;
                boosts.def = @maximum(-6, boosts.def - n);
                var mod = BOOSTS[@intCast(u4, boosts.def + 6)];
                const stat = unmodifiedStats(battle, player.foe()).def;
                stats.def = @maximum(1, @minimum(MAX_STAT_VALUE, stat * mod[0] / mod[1]));
                try log.unboost(foe_ident, .Defense, n);
            },
            .SpeedDown1, .SpeedDownChance => {
                assert(boosts.spe >= -6 and boosts.spe <= 6);
                boosts.spe = @maximum(-6, boosts.spe - 1);
                var mod = BOOSTS[@intCast(u4, boosts.spe + 6)];
                const stat = unmodifiedStats(battle, player.foe()).spe;
                stats.spe = @maximum(1, @minimum(MAX_STAT_VALUE, stat * mod[0] / mod[1]));
                try log.unboost(foe_ident, .Speed, 1);
                assert(boosts.spe >= -6);
            },
            .SpecialDownChance => {
                assert(boosts.spc >= -6 and boosts.spc <= 6);
                boosts.spc = @maximum(-6, boosts.spc - 1);
                var mod = BOOSTS[@intCast(u4, boosts.spc + 6)];
                const stat = unmodifiedStats(battle, player.foe()).spc;
                stats.spc = @maximum(1, @minimum(MAX_STAT_VALUE, stat * mod[0] / mod[1]));
                try log.unboost(foe_ident, .SpecialAttack, 1);
                try log.unboost(foe_ident, .SpecialDefense, 1);
            },
            .AccuracyDown1 => {
                assert(boosts.accuracy >= -6 and boosts.accuracy <= 6);
                boosts.accuracy = @maximum(-6, boosts.accuracy - 1);
                try log.unboost(foe_ident, .Accuracy, 1);
            },
            else => unreachable,
        }

        // GLITCH: Stat modification errors glitch
        statusModify(foe.stored().status, stats);
    }
};

fn unmodifiedStats(battle: anytype, who: Player) *Stats(u16) {
    const side = battle.side(who);
    if (!side.active.volatiles.Transform) return &side.active.stats;
    const id = ID.from(side.active.volatiles.transform);
    return &battle.side(id.player).pokemon[id.id].stats;
}

fn statusModify(status: u8, stats: *Stats(u16)) void {
    if (Status.is(status, .PAR)) {
        stats.spe = @maximum(stats.spe / 4, 1);
    } else if (Status.is(status, .BRN)) {
        stats.atk = @maximum(stats.atk / 2, 1);
    }
}

fn clearVolatiles(active: *ActivePokemon, ident: ID, log: anytype) !void {
    var volatiles = &active.volatiles;
    if (volatiles.disabled.move != 0) {
        volatiles.disabled = .{};
        try log.end(ident, .DisableSilent);
    }
    if (volatiles.Confusion) {
        // volatiles.confusion is left unchanged
        volatiles.Confusion = false;
        try log.end(ident, .ConfusionSilent);
    }
    if (volatiles.Mist) {
        volatiles.Mist = false;
        try log.end(ident, .Mist);
    }
    if (volatiles.FocusEnergy) {
        volatiles.FocusEnergy = false;
        try log.end(ident, .FocusEnergy);
    }
    if (volatiles.LeechSeed) {
        volatiles.LeechSeed = false;
        try log.end(ident, .LeechSeed);
    }
    if (volatiles.Toxic) {
        if (showdown) volatiles.toxic = 0;
        // volatiles.toxic is left unchanged
        volatiles.Toxic = false;
        try log.end(ident, .Toxic);
    }
    if (volatiles.LightScreen) {
        volatiles.LightScreen = false;
        try log.end(ident, .LightScreen);
    }
    if (volatiles.Reflect) {
        volatiles.Reflect = false;
        try log.end(ident, .Reflect);
    }
    if (!showdown) return;
    // FIXME: other volatiles
}

const DISTRIBUTION = [_]u3{ 2, 2, 2, 3, 3, 3, 4, 5 };

// SHOWDOWN: these values will diverge
fn distribution(battle: anytype) u3 {
    if (showdown) return DISTRIBUTION[battle.rng.range(u8, 0, DISTRIBUTION.len)];
    const r = (battle.rng.next() & 3);
    return @truncate(u3, (if (r < 2) r else battle.rng.next() & 3) + 2);
}

// SHOWDOWN: these values will diverge
fn randomMoveSlot(rand: anytype, moves: []MoveSlot) u4 {
    if (showdown) {
        var i: usize = moves.len;
        while (i > 0) {
            i -= 1;
            if (moves[i].id != .None) return rand.range(u4, 0, @truncate(u4, i));
        }
        unreachable;
    }

    while (true) {
        const r = @truncate(u4, rand.next() & 3);
        if (moves[r].id != .None) return r;
    }
}

test "RNG agreement" {
    var expected: [256]u8 = undefined;
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        expected[i] = @truncate(u8, i);
    }

    var spe1 = rng.FixedRNG(1, expected.len){ .rolls = expected };
    var spe2 = rng.FixedRNG(1, expected.len){ .rolls = expected };

    var cfz1 = rng.FixedRNG(1, expected.len){ .rolls = expected };
    var cfz2 = rng.FixedRNG(1, expected.len){ .rolls = expected };

    var par1 = rng.FixedRNG(1, expected.len){ .rolls = expected };
    var par2 = rng.FixedRNG(1, expected.len){ .rolls = expected };

    var brn1 = rng.FixedRNG(1, expected.len){ .rolls = expected };
    var brn2 = rng.FixedRNG(1, expected.len){ .rolls = expected };

    var eff1 = rng.FixedRNG(1, expected.len){ .rolls = expected };
    var eff2 = rng.FixedRNG(1, expected.len){ .rolls = expected };

    i = 0;
    while (i < expected.len) : (i += 1) {
        try expectEqual(spe1.range(u8, 0, 2) == 0, spe2.next() < Gen12.percent(50) + 1);
        try expectEqual(!cfz1.chance(u8, 128, 256), cfz2.next() >= Gen12.percent(50) + 1);
        try expectEqual(par1.chance(u8, 63, 256), par2.next() < Gen12.percent(25));
        try expectEqual(brn1.chance(u8, 26, 256), brn2.next() < Gen12.percent(10) + 1);
        try expectEqual(eff1.chance(u8, 85, 256), eff2.next() < Gen12.percent(33) + 1);
    }
}

pub fn choices(battle: anytype, player: Player, request: Choice.Type, out: []Choice) u8 {
    var n: u8 = 0;
    switch (request) {
        .Pass => {
            out[n] = .{};
            n += 1;
        },
        .Switch => {
            const side = battle.side(player);
            var slot: u4 = 2;
            while (slot <= 6) : (slot += 1) {
                const pokemon = side.get(slot);
                if (pokemon.hp == 0) continue;
                out[n] = .{ .type = .Switch, .data = slot };
                n += 1;
            }
            if (n == 0) {
                out[n] = .{};
                n += 1;
            }
        },
        .Move => {
            const side = battle.side(player);
            const foe = battle.foe(player);

            var active = side.active;

            // FIXME: handle locked move (charging/recharging/rage/bide/dig/etc)
            if (active.volatiles.Recharging) {
                out[n] = .{ .type = .Move, .data = 0 };
                n += 1;
                return n;
            }

            const trapped = foe.active.volatiles.Trapping;
            if (!trapped) {
                var slot: u4 = 2;
                while (slot <= 6) : (slot += 1) {
                    const pokemon = side.get(slot);
                    if (pokemon.hp == 0) continue;
                    out[n] = .{ .type = .Switch, .data = slot };
                    n += 1;
                }
            }

            const before = n;
            var slot: u4 = 1;
            while (slot <= 4) : (slot += 1) {
                const m = active.move(slot);
                if (m.id == .None) break;
                if (m.pp == 0 and !trapped) continue;
                if (active.volatiles.disabled.move == slot) continue;
                out[n] = .{ .type = .Move, .data = slot };
                n += 1;
            }
            if (n == before) {
                out[n] = .{ .type = .Move, .data = 0 }; // Struggle
                n += 1;
            }
        },
    }
    return n;
}
