extends RefCounted
## Needs — Uiop's internal drives. Values rise over time (decay away
## from "satisfied"); various actions reduce them.
##
## Each need is on [0, 1] where 0 = fully satisfied, 1 = critical.
## is_pressing_*() goes true above its threshold → the brain starts
## prioritizing addressing it over normal wandering.
##
## Tracked here as plain scalars rather than fancy curves — easy to
## read, easy to serialize if we ever want to persist Uiop's state
## across sessions, easy to feed into an LLM context later.

var hunger: float = 0.3
var tiredness: float = 0.0
var curiosity: float = 0.4

# Rates per second.
var hunger_rate: float = 0.006         # about 2.8 minutes to critical from empty
var tiredness_base_rate: float = 0.003 # at rest; scales with activity
var curiosity_rate: float = 0.012

# Thresholds past which the brain should start responding.
var hunger_threshold: float = 0.6
var tiredness_threshold: float = 0.75
var curiosity_threshold: float = 0.65

func tick(delta: float, movement_factor: float = 0.0) -> void:
	hunger = clampf(hunger + hunger_rate * delta, 0.0, 1.0)
	# Tiredness grows faster when moving (opossum isn't a long-distance runner)
	var tired_rate: float = tiredness_base_rate + 0.012 * clampf(movement_factor, 0.0, 1.0)
	tiredness = clampf(tiredness + tired_rate * delta, 0.0, 1.0)
	curiosity = clampf(curiosity + curiosity_rate * delta, 0.0, 1.0)

# Action results — call these when Uiop does something satisfying.
func eat(amount: float = 0.45) -> void:
	hunger = maxf(0.0, hunger - amount)

func sleep(delta: float, rate: float = 0.08) -> void:
	tiredness = maxf(0.0, tiredness - rate * delta)

func investigate(amount: float = 0.1) -> void:
	curiosity = maxf(0.0, curiosity - amount)

# Simple is_pressing helpers.
func is_hungry() -> bool:  return hunger >= hunger_threshold
func is_tired() -> bool:   return tiredness >= tiredness_threshold
func is_curious() -> bool: return curiosity >= curiosity_threshold

# Which need is "most urgent" (ratio-over-threshold). Returns "" if
# nothing is pressing yet.
func most_pressing() -> String:
	var ratios: Dictionary = {
		"hunger":    hunger / maxf(hunger_threshold, 0.001),
		"tiredness": tiredness / maxf(tiredness_threshold, 0.001),
	}
	var best: String = ""
	var best_ratio: float = 1.0
	for k in ratios.keys():
		if ratios[k] > best_ratio:
			best_ratio = ratios[k]
			best = k
	return best

# For debug / LLM context.
func summary() -> String:
	return "hunger=%.2f tired=%.2f curious=%.2f" % [hunger, tiredness, curiosity]
