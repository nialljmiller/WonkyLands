extends RefCounted
## Memory — a short-term map of things an agent has perceived.
##
## update() is called every tick with the latest scan from Perception.
## Each percept id gets its freshness renewed; old entries decay and
## eventually fall out.
##
## The memory exposes query helpers so the brain can ask things like
## "what's the most salient tree you remember?" without re-scanning.

var _items: Dictionary = {}                 # id -> {kind, position, salience, age, sense}
var forget_after_seconds: float = 20.0      # entry drops when age exceeds this

func update(delta: float, new_percepts: Array) -> void:
	# Age existing entries. Dictionary iteration yields keys directly —
	# no `.keys()` copy needed.
	for id in _items:
		_items[id].age += delta
	# Fold in fresh observations
	for p in new_percepts:
		var id: String = p.id
		if _items.has(id):
			var existing: Dictionary = _items[id]
			existing.age = 0.0
			existing.position = p.position
			existing.salience = maxf(existing.salience, p.salience)
			existing.sense = p.sense
		else:
			_items[id] = {
				"kind": p.kind,
				"position": p.position,
				"salience": p.salience,
				"age": 0.0,
				"sense": p.sense,
			}
	# Drop forgotten items — collect first (can't erase during iteration).
	var expired: Array = []
	for id in _items:
		if _items[id].age > forget_after_seconds:
			expired.append(id)
	for id in expired:
		_items.erase(id)

# ---------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------
func has_kind(kind: int) -> bool:
	for id in _items:
		if _items[id].kind == kind:
			return true
	return false

func most_salient(kind: int = -1) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = -1.0
	var inv_forget: float = 1.0 / forget_after_seconds
	for id in _items:
		var item: Dictionary = _items[id]
		if kind >= 0 and item.kind != kind:
			continue
		var fresh: float = 1.0 - item.age * inv_forget
		var score: float = item.salience * fresh
		if score > best_score:
			best_score = score
			best = item
	return best

func count() -> int:
	return _items.size()

# Drop one remembered thing right away (e.g. a fish that was just caught).
func forget(id: String) -> void:
	_items.erase(id)

# Read-only reference to the internal map. Callers must NOT mutate it.
# (Previously returned a duplicate; the OBSESSED brain state calls this
# every tick — the copy was wasted.)
func all_items() -> Dictionary:
	return _items
