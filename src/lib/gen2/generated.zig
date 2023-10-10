//! Code generated by `tools/generate` - manual edits will be overwritten.

const std = @import("std");

const common = @import("../common/data.zig");

const data = @import("data.zig");
const mechanics = @import("mechanics.zig");

const assert = std.debug.assert;

const Player = common.Player;
const Result = common.Result;

const Effectiveness = data.Effectiveness;
const Move = data.Move;

const Effects = mechanics.Effects;
const State = mechanics.State;

const canMove = mechanics.canMove;
const canCharge = mechanics.canCharge;
const decrementPP = mechanics.decrementPP;
const doMove = mechanics.doMove;
const checkHit = mechanics.checkHit;
const checkCriticalHit = mechanics.checkCriticalHit;
const calcDamage = mechanics.calcDamage;
const adjustDamage = mechanics.adjustDamage;
const randomizeDamage = mechanics.randomizeDamage;
const applyDamage = mechanics.applyDamage;
const reportOutcome = mechanics.reportOutcome;
const effectChance = mechanics.effectChance;
const afterMove = mechanics.afterMove;
const buildRage = mechanics.buildRage;
const kingsRock = mechanics.kingsRock;
const destinyBond = mechanics.destinyBond;

const SECONDARY = true;
const KINGS = true;

pub fn runMove(battle: anytype, player: Player, state: *State, options: anytype) !void {
    var log = options.log;

    var side = battle.side(player);
    var volatiles = &side.active.volatiles;

    const ident = battle.active(player);
    const foe_ident = battle.active(player.foe());

    const effect = Move.get(state.move).effect;
    switch (effect) {
        .AlwaysHit, .HighCritical, .Priority, .JumpKick, .None => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(!SECONDARY, battle, player, state, options)) return;
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .DoubleHit, .MultiHit => {
            if (!try canMove(battle, player, state, options)) return;
            // TODO startloop
            try checkHit(battle, player, state, options);
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (state.miss) state.damage = 0;

            try applyDamage(battle, player, state, options);
            // TODO critsupereffectivelooptext
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            // TODO endloop
            try kingsRock(battle, player, state, options);
        },
        .PayDay => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(!SECONDARY, battle, player, state, options)) return;
            try Effects.payDay(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .BurnChance => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.burnChance(battle, player, state, options);
        },
        .FreezeChance => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.freezeChance(battle, player, state, options);
        },
        .ParalyzeChance => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.paralyzeChance(battle, player, state, options);
        },
        .OHKO => {
            if (!try canMove(battle, player, state, options)) return;
            try adjustDamage(battle, player, state, options);
            try Effects.ohko(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(!KINGS, battle, player, state, options);
        },
        .Gust => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (battle.foe(player).active.volatiles.Flying) state.damage *|= 2;

            try checkHit(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(!KINGS, battle, player, state, options);
        },
        .ForceSwitch => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.forceSwitch(battle, player, state, options);
        },
        .RazorWind, .SolarBeam, .FlyDig => {
            if (!try canCharge(battle, player, state, options)) return;
            if (!try doMove(!SECONDARY, battle, player, state, options)) return;
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Binding => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (state.miss) state.damage = 0;

            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.binding(battle, player, state, options);
        },
        .Stomp => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (battle.foe(player).active.volatiles.minimized) state.damage *|= 2;

            try checkHit(battle, player, state, options);
            try effectChance(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.flinchChance(battle, player, state, options);
        },
        .FlinchChance => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.flinchChance(battle, player, state, options);
        },
        .Recoil => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(!SECONDARY, battle, player, state, options)) return;
            try Effects.recoil(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Thrashing => {
            // TODO checkrampage
            // doturn
            const charging = false; // TODO
            const skip_pp = charging or state.move == .Struggle or
                (volatiles.BeatUp or volatiles.Thrashing or volatiles.Bide);
            if (!skip_pp) _ = decrementPP(side, state.move, state.mslot); // TODO if no pp return
            // TODO rampage
            // usedmovetext
            try log.move(ident, state.move, foe_ident); // FIXME self? from?
            try checkHit(battle, player, state, options);
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (state.miss) state.damage = 0;

            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .PoisonChance => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.poisonChance(battle, player, state, options);
        },
        .Twineedle => {
            if (!try canMove(battle, player, state, options)) return;
            // TODO startloop
            try checkHit(battle, player, state, options);
            try effectChance(battle, player, state, options);
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (state.miss) state.damage = 0;

            try applyDamage(battle, player, state, options);
            // TODO critsupereffectivelooptext
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            // TODO endloop
            try kingsRock(battle, player, state, options);
            try Effects.poisonChance(battle, player, state, options);
        },
        .Sleep => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            // TODO checksafeguard
            try Effects.sleep(battle, player, state, options);
        },
        .Confusion => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            // TODO checksafeguard
            try Effects.confusion(battle, player, state, options);
        },
        .SuperFang, .LevelDamage, .Psywave, .FixedDamage => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.fixedDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);

            if (state.immune()) {
                state.damage = 0;
                state.miss = true;
            }
            state.effectiveness = Effectiveness.neutral;

            try applyDamage(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Disable => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.disable(battle, player, state, options);
        },
        .Mist => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.mist(battle, player, state, options);
        },
        .ConfusionChance => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.confusionChance(battle, player, state, options);
        },
        .HyperBeam => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(!SECONDARY, battle, player, state, options)) return;
            try Effects.hyperBeam(battle, player, state, options);
            _ = try afterMove(!KINGS, battle, player, state, options);
        },
        .Counter => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.counter(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .DreamEater, .DrainHP => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(!SECONDARY, battle, player, state, options)) return;
            try Effects.drainHP(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .LeechSeed => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.leechSeed(battle, player, state, options);
        },
        .Toxic, .Poison => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            // TODO checksafeguard
            try Effects.poison(battle, player, state, options);
        },
        .Paralyze => {
            if (!try canMove(battle, player, state, options)) return;
            try adjustDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);
            // TODO checksafeguard
            try Effects.paralyze(battle, player, state, options);
        },
        .Thunder => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            // TODO thunderaccuracy
            try checkHit(battle, player, state, options);
            try effectChance(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.paralyzeChance(battle, player, state, options);
        },
        .Earthquake => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (battle.foe(player).active.volatiles.Underground) state.damage *|= 2;

            try checkHit(battle, player, state, options);
            try effectChance(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(!KINGS, battle, player, state, options);
        },
        .Rage => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);

            assert(volatiles.Rage);
            state.damage *|= (volatiles.rage +| 1);

            try randomizeDamage(battle, player, state, options);
            // TODO failuretext
            try Effects.rage(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Teleport => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.teleport(battle, player, state, options);
        },
        .Mimic => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.mimic(battle, player, state, options);
        },
        .Heal => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.heal(battle, player, state, options);
        },
        .Haze => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.haze(battle, player, state, options);
        },
        .LightScreen, .Reflect => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.screens(battle, player, state, options);
        },
        .FocusEnergy => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.focusEnergy(battle, player, state, options);
        },
        .Bide => {
            // TODO storeenergy
            // doturn
            const charging = false; // TODO
            const skip_pp = charging or state.move == .Struggle or
                (volatiles.BeatUp or volatiles.Thrashing or volatiles.Bide);
            if (!skip_pp) _ = decrementPP(side, state.move, state.mslot); // TODO if no pp return
            // usedmovetext
            try log.move(ident, state.move, foe_ident); // FIXME self? from?
            // TODO unleashenergy

            if (state.immune()) {
                state.damage = 0;
                state.miss = true;
            }
            state.effectiveness = Effectiveness.neutral;

            try checkHit(battle, player, state, options);
            // TODO bidefailtext
            try applyDamage(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Metronome => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.metronome(battle, player, state, options);
        },
        .MirrorMove => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.mirrorMove(battle, player, state, options);
        },
        .Explode => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);
            try Effects.explode(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .SkullBash => {
            if (!try canCharge(battle, player, state, options)) return;
            if (!try doMove(!SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(KINGS, battle, player, state, options)) return;
            // TODO endturn
            try Effects.boost(battle, player, state, options);
        },
        .SkyAttack => {
            if (!try canCharge(battle, player, state, options)) return;
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.flinchChance(battle, player, state, options);
            try kingsRock(battle, player, state, options);
        },
        .Transform => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.transform(battle, player, state, options);
        },
        .Splash => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.splash(battle, player, state, options);
        },
        .Conversion => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.conversion(battle, player, state, options);
        },
        .TriAttack => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(!SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.triAttack(battle, player, state, options);
        },
        .Substitute => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.substitute(battle, player, state, options);
        },
        .Sketch => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.sketch(battle, player, state, options);
        },
        .TripleKick => {
            if (!try canMove(battle, player, state, options)) return;
            // TODO startloop
            try checkHit(battle, player, state, options);
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try Effects.tripleKick(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (state.miss) state.damage = 0;

            try applyDamage(battle, player, state, options);
            // TODO critsupereffectivelooptext
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            // TODO kickcounter
            // TODO endloop
            try kingsRock(battle, player, state, options);
        },
        .Thief => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            try Effects.thief(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .MeanLook => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.meanLook(battle, player, state, options);
        },
        .LockOn => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.lockOn(battle, player, state, options);
        },
        .Nightmare => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.nightmare(battle, player, state, options);
        },
        .Snore => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);
            try effectChance(battle, player, state, options);
            try Effects.snore(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.flinchChance(battle, player, state, options);
            try kingsRock(battle, player, state, options);
        },
        .Curse => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.curse(battle, player, state, options);
        },
        .Reversal => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.reversal(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            // TODO reversalsupereffectivetext
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Conversion2 => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.conversion2(battle, player, state, options);
        },
        .Spite => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.spite(battle, player, state, options);
        },
        .Endure, .Protect => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.protect(battle, player, state, options);
        },
        .BellyDrum => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.bellyDrum(battle, player, state, options);
        },
        .Spikes => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.spikes(battle, player, state, options);
        },
        .Foresight => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.foresight(battle, player, state, options);
        },
        .DestinyBond => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.destinyBond(battle, player, state, options);
        },
        .PerishSong => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.perishSong(battle, player, state, options);
        },
        .Sandstorm => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.sandstorm(battle, player, state, options);
        },
        .Rollout => {
            // TODO checkcurl
            // doturn
            const charging = false; // TODO
            const skip_pp = charging or state.move == .Struggle or
                (volatiles.BeatUp or volatiles.Thrashing or volatiles.Bide);
            if (!skip_pp) _ = decrementPP(side, state.move, state.mslot); // TODO if no pp return
            // usedmovetext
            try log.move(ident, state.move, foe_ident); // FIXME self? from?
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);
            // TODO rolloutpower
            try randomizeDamage(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .FalseSwipe => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);
            try Effects.falseSwipe(battle, player, state, options);
            try checkHit(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Swagger => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            // TODO switchturn
            // TODO attackup2
            // TODO switchturn
            // TODO failuretext
            // TODO switchturn
            // TODO switchturn
            try Effects.confusionChance(battle, player, state, options);
        },
        .FuryCutter => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);
            try Effects.furyCutter(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Attract => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.attract(battle, player, state, options);
        },
        .SleepTalk => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.sleepTalk(battle, player, state, options);
        },
        .HealBell => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.healBell(battle, player, state, options);
        },
        .Frustration, .Return => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try Effects.happiness(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Present => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try checkCriticalHit(battle, player, state, options);
            try Effects.present(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (state.miss) state.damage = 0;

            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Safeguard => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.safeguard(battle, player, state, options);
        },
        .PainSplit => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.painSplit(battle, player, state, options);
        },
        .FlameWheel, .SacredFire => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            try Effects.defrost(battle, player, state, options);
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.burnChance(battle, player, state, options);
        },
        .Magnitude => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            // TODO getmagnitude
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);

            if (battle.foe(player).active.volatiles.Underground) state.damage *|= 2;

            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .BatonPass => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.batonPass(battle, player, state, options);
        },
        .Encore => {
            if (!try canMove(battle, player, state, options)) return;
            try checkHit(battle, player, state, options);
            try Effects.encore(battle, player, state, options);
        },
        .Pursuit => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);
            try Effects.pursuit(battle, player, state, options);
            try checkHit(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .RapidSpin => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(!SECONDARY, battle, player, state, options)) return;
            try Effects.rapidSpin(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .MorningSun, .Synthesis, .Moonlight => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.weatherHeal(battle, player, state, options);
        },
        .HiddenPower => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try Effects.hiddenPower(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .Twister => {
            if (!try canMove(battle, player, state, options)) return;
            try checkCriticalHit(battle, player, state, options);
            try calcDamage(battle, player, state, options);
            try adjustDamage(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (battle.foe(player).active.volatiles.Flying) state.damage *|= 2;

            try checkHit(battle, player, state, options);
            try effectChance(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.flinchChance(battle, player, state, options);
        },
        .RainDance => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.rainDance(battle, player, state, options);
        },
        .SunnyDay => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.sunnyDay(battle, player, state, options);
        },
        .MirrorCoat => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.mirrorCoat(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            _ = try afterMove(KINGS, battle, player, state, options);
        },
        .PsychUp => {
            if (!try canMove(battle, player, state, options)) return;
            try Effects.psychUp(battle, player, state, options);
        },
        .AllStatUpChance => {
            if (!try canMove(battle, player, state, options)) return;
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.allStatUpChance(battle, player, state, options);
        },
        .FutureSight => {
            // TODO checkfuturesight
            if (!try canMove(battle, player, state, options)) return;
            try calcDamage(battle, player, state, options);
            try Effects.futureSight(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);
            try checkHit(battle, player, state, options);
            try applyDamage(battle, player, state, options);
            _ = try afterMove(!KINGS, battle, player, state, options);
        },
        .BeatUp => {
            if (!try canMove(battle, player, state, options)) return;
            // TODO startloop
            try checkHit(battle, player, state, options);
            try checkCriticalHit(battle, player, state, options);
            try Effects.beatUp(battle, player, state, options);
            try randomizeDamage(battle, player, state, options);

            if (state.miss) state.damage = 0;

            try applyDamage(battle, player, state, options);
            try reportOutcome(battle, player, state, options);
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            // TODO endloop
            // TODO beatupfailtext
            try kingsRock(battle, player, state, options);
        },
        // zig fmt: off
        .AttackUp1, .AttackUp2, .DefenseCurl, .DefenseUp1, .DefenseUp2,
        .EvasionUp1, .SpAtkUp1, .SpDefUp2, .SpeedUp2 => {
        // zig fmt: on
            _ = try canMove(battle, player, state, options);
            try Effects.boost(battle, player, state, options);
            if (effect == .DefenseCurl) try Effects.defenseCurl(battle, player, state, options);
        },
        .AttackUpChance, .DefenseUpChance => {
            _ = try canMove(battle, player, state, options);
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            try Effects.boost(battle, player, state, options);
        },
        // zig fmt: off
        .AccuracyDown1, .AttackDown1, .AttackDown2, .DefenseDown1,
        .DefenseDown2, .EvasionDown1, .SpeedDown1, .SpeedDown2 => {
        // zig fmt: on
            _ = try canMove(battle, player, state, options);
            try checkHit(battle, player, state, options);
            try Effects.unboost(battle, player, state, options);
        },
        // zig fmt: off
        .AccuracyDownChance, .AttackDownChance, .DefenseDownChance,
        .SpDefDownChance, .SpeedDownChance => {
        // zig fmt: on
            _ = try canMove(battle, player, state, options);
            if (!try doMove(SECONDARY, battle, player, state, options)) return;
            if (!try afterMove(!KINGS, battle, player, state, options)) return;
            // GLITCH: moves that lower Defense can do so after breaking a Substitute
            if (effect == .DefenseDownChance) try effectChance(battle, player, state, options);
            try Effects.unboost(battle, player, state, options);
        },
    }
}
