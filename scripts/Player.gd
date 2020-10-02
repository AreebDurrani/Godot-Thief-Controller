extends KinematicBody

onready var camera = $Camera
onready var collider = $Collider
onready var light_indicator = $Camera/CanvasLayer/LightIndicator
onready var surface_detector = $SurfaceDetector
onready var sound_emitter = $SoundEmitter
onready var audio_player = $Audio

enum {
	WALKING,
	LEANING,
	CROUCHING,
	CLAMBERING_RISE,
	CLAMBERING_LEDGE
}

var state = WALKING

export var speed : float = 1.0
export var gravity : float = 60.0
export var jump_force : float = 10.0
export var drag : float = 0.2
export(float, -45.0, -8.0, 1.0) var max_lean = -10.0
export var mouse_sens : float = 0.5
export var lock_mouse : bool = true
export var head_bob_enabled : bool = true

var light_level : float = 0.0

var velocity : Vector3 = Vector3.ZERO

var bob_reset : float = 0.0

var camera_pos_normal : Vector3 = Vector3.ZERO
var collider_normal_radius : float = 0.0
var collider_normal_height : float = 0.0
var collision_normal_offset : float = 0.0

#Replace the placeholder with the full path of the folder where the specific sound files are stored
#Don't include res://
const TEXTURE_SOUND_LIB = {
	"checkerboard" : {
		"amplifier" : 5.0,
		"sfx_folder" : "sfx/footsteps"
	}
}

func _ready() -> void:
	bob_reset = camera.global_transform.origin.y
	
	collider_normal_radius = collider.shape.radius
	collider_normal_height = collider.shape.height
	collision_normal_offset = collider.global_transform.origin.y
	
	load_footstep_sounds("sfx/breathe", 1)
	load_footstep_sounds("sfx/landing", 2)
	
	if lock_mouse:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
var current_sound_dir : String = ""
	
var footstep_sounds : Array = []
var landing_sounds : Array = []
var clamber_sounds : Dictionary = {
	"in" : [],
	"out" : []
}

#1, footsteps - 2, breathing (clambering) - 3, landing
func load_footstep_sounds(sound_dir, type : int) -> void:
	if sound_dir == "":
		return
		
	if current_sound_dir == sound_dir:
		return
		
	current_sound_dir = sound_dir
	
	if sound_dir.ends_with("/"):
		sound_dir.erase(sound_dir.length() - 1, 1)
		
	if not "res://" in sound_dir:
		sound_dir = "res://" + sound_dir
	
	var snd_dir = Directory.new()
	snd_dir.open(sound_dir)
	snd_dir.list_dir_begin(true)
	
	var sound = snd_dir.get_next()
	while sound != "":
		if not sound.ends_with(".import"):
			if type == 0:
				footstep_sounds.append(load(sound_dir + "/" + sound))
			elif type == 1:
				if "in" in sound:
					clamber_sounds["in"].append(load(sound_dir + "/" + sound))
				elif "out" in sound:
					clamber_sounds["out"].append(load(sound_dir + "/" + sound))
			elif type == 2:
				landing_sounds.append(load(sound_dir + "/" + sound))
		sound = snd_dir.get_next()
	
func get_surface_texture() -> Dictionary:
	if surface_detector.get_collider():
		var mesh = null
		for node in surface_detector.get_collider().get_children():
			if node is MeshInstance:
				if node.mesh != null:
					mesh = node
		
		if !mesh:
			return {}
		
		if mesh.get_surface_material(0) != null:
				var path = mesh.get_surface_material(0).albedo_texture.resource_path.split("/")
				var n = path[path.size() - 1].split(".")[0]
				if TEXTURE_SOUND_LIB.has(n):
					return TEXTURE_SOUND_LIB[n]
					
	return {}
		
func handle_player_sound_emission() -> void:
	var result = get_surface_texture()
	
	if result.size() == 0:
		return
	
	sound_emitter.radius = result["amplifier"]
	
	if result.sfx_folder != "":
		load_footstep_sounds(result.sfx_folder, 0)
		
func _input(event) -> void:
	if event is InputEventMouseMotion:
		rotation_degrees.y -= event.relative.x * mouse_sens
		camera.rotation_degrees.x -= event.relative.y * mouse_sens
		camera.rotation_degrees.x = clamp(camera.rotation_degrees.x, -90, 90)

func _physics_process(delta) -> void:
	if Input.is_action_just_released("ui_cancel"):
		get_tree().quit()
		
	camera_pos_normal = global_transform.origin + Vector3.UP * bob_reset	
	
	light_indicator.value = light_level
	
	match state:
		WALKING:
			if Input.is_action_pressed("lean"):
				state = LEANING
				return
				
			if Input.is_action_pressed("crouch"):
				state = CROUCHING
				return
			
			if Input.is_action_pressed("sneak"):
				walk(delta, 0.75)
				return
			
			walk(delta)
		
		CROUCHING:
			crouch()
			walk(delta, 0.75)
			
		LEANING:
			lean()
			
		CLAMBERING_RISE:
			var pos = global_transform.origin
			var target = Vector3(pos.x, clamber_destination.y, pos.z)
			global_transform.origin = lerp(pos, target, 0.1)
			crouch()
			
			var from = camera.rotation_degrees.x
			var to = pos.angle_to(target)
			camera.rotation_degrees.x = lerp(from, to, 0.1)
			
			var d = pos - target
			if d.length() < 0.1:
				state = CLAMBERING_LEDGE
				return
		
		CLAMBERING_LEDGE:
			if !audio_player.playing:
				clamber_sounds["out"].shuffle()
				audio_player.stream = clamber_sounds["out"].front()
				audio_player.play()
			
			global_transform.origin = lerp(global_transform.origin, clamber_destination, 0.1)
			crouch()
			
			var from = camera.rotation_degrees.x
			var to = global_transform.origin.angle_to(clamber_destination)
			camera.rotation_degrees.x = lerp(from, to, 0.1)
			
			var d = global_transform.origin - clamber_destination
			if d.length() < 0.1:
				global_transform.origin = clamber_destination
				state = CROUCHING
				return
		
var jumping = false
			
#Needs some refining
func walk(delta, speed_mod : float = 1.0) -> void:
	var move_dir = Vector3()
	move_dir.x = (Input.get_action_strength("right") - Input.get_action_strength("left"))
	move_dir.z = (Input.get_action_strength("back") - Input.get_action_strength("forward"))
	move_dir = move_dir.normalized()	
	move_dir = move_dir.rotated(Vector3.UP, rotation.y)
	
	var y_velo = velocity.y
	
	velocity += speed * move_dir - velocity * Vector3(drag, 0, drag) + Vector3.DOWN * gravity * delta
	
	velocity = move_and_slide((velocity * speed_mod) + get_floor_velocity(), Vector3.UP, true, 4, PI, false)
	
	var grounded = is_on_floor()
	
	if !grounded and y_velo < velocity.y:
		velocity.y = y_velo
		
	if grounded:
		velocity.y = -0.01
		
		if jumping:
			landing_sounds.shuffle()
			audio_player.stream = landing_sounds.front()
			audio_player.play()
		
		jumping = false
	if grounded and Input.is_action_just_pressed("clamber") and state == WALKING:
		# Check for clamber
		if clamber():
			if not audio_player.stream in clamber_sounds["in"]:
				clamber_sounds["in"].shuffle()
				audio_player.stream = clamber_sounds["in"].front()
				audio_player.play()
			return
			
		# If no clamber, jump
		velocity.y = jump_force
		jumping = true
		return
		
	handle_player_sound_emission()
	
	if head_bob_enabled and grounded and state == WALKING:
		head_bob(delta)
		
	if velocity.length() > 0.1 and grounded and not audio_player.playing and is_on_floor():
		play_footstep_audio()

var time = 0.0
		
func head_bob(delta : float) -> void:
	if velocity.length() == 0.0:
		camera.global_transform.origin = global_transform.origin + Vector3.UP * bob_reset

	time += delta
	var y_bob = sin(time * (4 * PI)) * velocity.length() * (speed / 1000.0)
	var z_bob = sin(time * (2 * PI)) * velocity.length() * 0.2
	camera.global_transform.origin.y += y_bob
	camera.rotation_degrees.z = z_bob

func play_footstep_audio() -> void:
	if footstep_sounds.size() > 0:
		footstep_sounds.shuffle()
		audio_player.stream = footstep_sounds.front()
		audio_player.play()
	
func crouch() -> void:
	var from = collider.shape.height
	var to = collider_normal_height * 0.5
	collider.shape.height = lerp(from, to, 0.1)
	from = collider.shape.radius
	to = collider_normal_radius * 0.5
	collider.shape.radius = lerp(from, to, 0.1)
	collider.rotation_degrees.x = 0
	
	from = camera.global_transform.origin
	to = camera_pos_normal + (Vector3.DOWN * bob_reset * 0.4)
	camera.global_transform.origin = lerp(from, to, 0.1)
	
	if !Input.is_action_pressed("crouch") and state == CROUCHING:
		var pos = global_transform.origin
		var space = get_world().direct_space_state
		if !space.intersect_ray(pos, pos + Vector3.UP * bob_reset + Vector3.UP * 0.2, [self]):
			state = WALKING
			camera.global_transform.origin = pos + Vector3.UP * bob_reset
			collider.shape.height = collider_normal_height
			collider.shape.radius = collider_normal_radius
			collider.rotation_degrees.x = 90
			return
		
func lean() -> void:
	var axis = (Input.get_action_strength("right") - Input.get_action_strength("left"))
	
	var from = camera.global_transform.origin
	var to = camera_pos_normal + (camera.global_transform.basis.x * 0.2 * axis)
	camera.global_transform.origin = lerp(from, to, 0.1)
	
	from = camera.rotation_degrees.z
	to = max_lean * axis
	camera.rotation_degrees.z = lerp(from, to, 0.1)
	
	var diff = camera.global_transform.origin - camera_pos_normal
	if axis == 0 and diff.length() <= 0.01:
		state = WALKING
		return

#TODO: Get the best distance values
func clamber() -> bool:
	if camera.rotation_degrees.x < 20.0:
		return vent_clamber() or wall_clamber()
	elif camera.rotation_degrees.x > 20.0:
		return wall_clamber() or vent_clamber()
	return false
			
var clamber_destination : Vector3 = Vector3.ZERO
		
func wall_clamber() -> bool:
	var space = get_world().direct_space_state
	var pos = global_transform.origin
	var d1 = pos + Vector3.UP * 1.25
	var d2 = d1 -global_transform.basis.z.normalized()
	var d3 = d2 + Vector3.DOWN * 16
	
	if not space.intersect_ray(pos, d1):
		for i in range(5):
			if not space.intersect_ray(d1, d2 - global_transform.basis.z.normalized() * i):
				for j in range(5):
					d2 = d1 + -global_transform.basis.z.normalized() * (j + 1)
					var r = space.intersect_ray(d2, d3)
					if r:
						var ground_check = space.intersect_ray(pos, pos + Vector3.DOWN * 2)
				
						if ground_check.collider == r.collider:
							return false
				
						var offset = check_clamber_box(r.position)
						if offset == -Vector3.ONE:
							return false
				
						if r.position.y < pos.y:
							return false
				
						#Start clamber animation
						velocity = Vector3.ZERO
						clamber_destination = r.position + offset
						state = CLAMBERING_RISE
						return true		
				
	return false
	
func vent_clamber() -> bool:
	var space = get_world().direct_space_state
	var pos = global_transform.origin
	var d1 = camera.global_transform.origin - camera.global_transform.basis.z.normalized() * 0.4
	var d2 = d1 + Vector3.DOWN * 6
	
	if not space.intersect_ray(pos, d1, [self]):
		for i in range(5):
			var r = space.intersect_ray(d1 - camera.global_transform.basis.z.normalized() * 0.4 * i, d2, [self])
			if r:
				var ground_check = space.intersect_ray(pos, pos + Vector3.DOWN * 2)
			
				if ground_check and ground_check.collider == r.collider:
					return false
				
				var offset = check_clamber_box(r.position)
				if offset == -Vector3.ONE:
					return false
				
				if r.position.y < pos.y:
					return false
				
				velocity = Vector3.ZERO
				clamber_destination = r.position + offset
				state = CLAMBERING_RISE
				return true
		
	return false
	
#Nudging may need some refining
func check_clamber_box(pos : Vector3) -> Vector3:
	var state = get_world().direct_space_state
	var shape = BoxShape.new()
	shape.extents = Vector3.ONE * 0.15
	
	var params = PhysicsShapeQueryParameters.new()
	params.set_shape(shape)
	params.transform.origin = pos + Vector3.UP * 0.15
	var result = state.intersect_shape(params)
	
	for i in range(result.size() - 1):
		if result[i].collider == self:
			result.remove(i)	
	
	if result.size() == 1 and result[0].collider.global_transform.origin.y < pos.y:
		return Vector3.ZERO
	
	if result.size() == 0:
		return Vector3.ZERO
		
	if !check_gap(pos + Vector3.UP * 0.175):
		return -Vector3.ONE
	
	if !check_gap(pos + Vector3.UP * 0.175 + Vector3.FORWARD * 0.15):
		return -Vector3.ONE

	if !check_gap(pos + Vector3.UP * 0.175 + Vector3.BACK * 0.15):
		return -Vector3.ONE
		
	var offset = Vector3.ZERO
	var checkPos = Vector3.ZERO
	
	var dir = -camera.global_transform.basis.z.normalized()
	dir.y = 0
		
	for i in range(4):
		var j = (i + 1) * 0.4
		checkPos = pos + Vector3.UP * 0.175 + dir * j
		params.transform.origin = checkPos
		var r = state.intersect_shape(params)
		if r.size() == 0:
			offset = dir * j
			break
	
	if checkPos != Vector3.ZERO:
		if state.intersect_ray(checkPos, checkPos + Vector3.DOWN * 2):
			return offset
	
	return -Vector3.ONE
	
func check_gap(pos : Vector3) -> bool:
	var space = get_world().direct_space_state
	
	var c = 0
	
	for i in range(4):
		var r = i * 90
		var v = Vector3.UP.rotated(Vector3.FORWARD, deg2rad(r))
		var result = space.intersect_ray(pos, pos + v, [self])
		if result and (result.position - pos).length() < 0.2:
			c += 1
			
	if c >= 2:
		return false
	
	return true
