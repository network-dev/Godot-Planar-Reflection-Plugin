@tool
extends MeshInstance3D

const SHOW_NODES_IN_EDITOR = false

enum FitMode {
	FIT_AREA, # Fits reflection on the whole area
	FIT_VIEW # Fits reflection in view.
}

# Exported variables
## The resolution of the reflection.
var resolution := 512: set = set_resolution
## How the reflection fits in the area.
var fit_mode : int = FitMode.FIT_AREA
## How much normal maps distort the reflection.
var perturb_scale := 0.7
## How much geometry beyond the plane will be rendered.
## Can be used along with perturb scale to make sure there're no seams in the reflection. 
var clip_bias := 0.1
## Whether to render the sky in the reflection.
## Disabling this allows you to mix planar reflection, with other sources of reflections,
## such as reflection probes.
var render_sky := true: set = set_render_sky
## What geometry gets rendered into the reflection.
var cull_mask := 0xfffff: set = set_cull_mask
## Custom environment to render the reflection with.
var environment : Environment: set = set_environment

# Internal variables
var reflect_mesh : MeshInstance3D
var reflect_viewport : SubViewport
var reflect_texture : ViewportTexture
var viewport_rect := Rect2(0, 0, 1, 1)

var main_cam : Camera3D
var reflect_camera : Camera3D

func _set(property : StringName, value) -> bool:
	match property:
		"mesh":
			set_mesh_c(value)
		"material_override":
			set_material_override_c(value)
			print("[PlanarReflections] Updating reflection material")
		"cast_shadow":
			set_cast_shadow_c(value)
		"layers":
			set_layers_c(value)
		_:
			if property.begins_with("material/"):
				property.erase(0, "material/".length())
				set_surface_override_material_c(int(property), value)
			else:
				return false
	return true

func _get_property_list() -> Array:
	var props := []
	
	props += [{"name": "PlanarReflector", "type": TYPE_NIL, "usage": PROPERTY_USAGE_CATEGORY}]
	props += [{"name": "environment", "type": TYPE_OBJECT, "hint": PROPERTY_HINT_RESOURCE_TYPE, "hint_string": "Environment"}]
	props += [{"name": "resolution", "type": TYPE_INT}]
	props += [{"name": "fit_mode", "type": TYPE_INT, "hint": PROPERTY_HINT_ENUM, "hint_string": "Fit Area3D, Fit View"}]
	props += [{"name": "perturb_scale", "type": TYPE_FLOAT}]
	props += [{"name": "clip_bias", "type": TYPE_FLOAT, "hint": PROPERTY_HINT_RANGE, "hint_string": "0, 1, 0.01, or_greater"}]
	props += [{"name": "render_sky", "type": TYPE_BOOL}]
	props += [{"name": "cull_mask", "type": TYPE_INT, "hint": PROPERTY_HINT_LAYERS_3D_RENDER}]
	
	return props

func _ready() -> void:
	if SHOW_NODES_IN_EDITOR:
		for node in get_children():
			node.queue_free()
	
	# Create mirror surface
	reflect_mesh = MeshInstance3D.new()
	reflect_mesh.layers = layers
	reflect_mesh.cast_shadow = cast_shadow
	reflect_mesh.mesh = mesh
	add_child(reflect_mesh)
	
	if not mesh:
		self.mesh = QuadMesh.new()
	
	# Create reflection viewport
	reflect_viewport = SubViewport.new()
	reflect_viewport.transparent_bg = not render_sky 
	reflect_viewport.use_hdr_2d = true  
	reflect_viewport.msaa_3d = SubViewport.MSAA_4X 
	reflect_viewport.positional_shadow_atlas_size = 512
	add_child(reflect_viewport)
	
	# Add a mirror camera
	reflect_camera = Camera3D.new()
	reflect_camera.cull_mask = cull_mask
	reflect_camera.environment = environment
	reflect_camera.name = "reflect_cam"
	reflect_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	reflect_camera.current = true
	reflect_viewport.add_child(reflect_camera)
	
	await get_tree().process_frame 
	
	# Create reflection texture
	reflect_texture = reflect_viewport.get_texture() 
	
	if Engine.is_editor_hint(): #fixme
		reflect_texture.viewport_path = NodePath("/root/" + str(get_node("/root").get_path_to(reflect_viewport)))
	
	self.material_override = material_override
	for mat in get_surface_override_material_count():
		set_surface_override_material(mat, get_surface_override_material(mat))
	
	if SHOW_NODES_IN_EDITOR:
		for i in get_children():
			i.owner = get_tree().edited_scene_root

func _process(delta : float) -> void:
	if not reflect_camera or not reflect_viewport or not get_extents().length():
		print("[PlanarReflections] Failed to initialize variables")
		return
	
	update_viewport()

	# Get main camera and viewport
	var main_viewport : Viewport = get_viewport() as Viewport 
	
	if not Engine.is_editor_hint():  
		main_cam = get_viewport().get_camera_3d() 
	else:
		#https://github.com/godotengine/godot/issues/73525
		var editor_viewport = (EditorPlugin as Variant).new().get_editor_interface().get_editor_viewport_3d();
		main_cam = editor_viewport.get_camera_3d()
		main_viewport = editor_viewport as Viewport
	
	# Compute reflection plane and its global transform  (origin in the middle, 
	#  X and Y axis properly aligned with the viewport, -Z is the mirror's forward direction) 
	var reflection_transform := global_transform
	var plane_origin := reflection_transform.origin
	var plane_normal := reflection_transform.basis.z.normalized()
	var reflection_plane := Plane(plane_normal, plane_origin.dot(plane_normal))
	
	# Main camera position
	var cam_pos := main_cam.global_transform.origin 
	
	# Calculate the area the viewport texture will fit into.
	var rect : Rect2
	if fit_mode == FitMode.FIT_VIEW:
		if main_viewport == null:
			print("[PlanarReflections] Missing reflection viewport")
			return
		
		# Area of the plane that's visible
		for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
			var ray := main_cam.project_ray_normal(corner * Vector2(main_viewport.size))
			var intersection = reflection_plane.intersects_ray(cam_pos, ray)
			if not intersection:
				intersection = reflection_plane.project(cam_pos + ray * main_cam.far)
			intersection = (intersection) * reflection_transform
			intersection = Vector2(intersection.x, intersection.y)
			
			if not rect:
				rect = Rect2(intersection, Vector2())
			else:
				rect = rect.expand(intersection)
		rect = Rect2(-get_extents() / 2.0, get_extents()).intersection(rect)
		
		# Aspect ratio of our extents must also be enforced.
		var aspect = rect.size.aspect()
		if aspect > get_extents().aspect():
			rect = scale_rect(rect, Vector2(1.0, aspect / get_extents().aspect()))
		else:
			rect = scale_rect(rect, Vector2(get_extents().aspect() / aspect, 1.0))
	else:
		# Area of the whole plane
		rect = Rect2(-get_extents() / 2.0, get_extents())
	
	viewport_rect = rect
	
	var rect_center := rect.position + rect.size / 2.0
	reflection_transform.origin += reflection_transform.basis.x * rect_center.x
	reflection_transform.origin += reflection_transform.basis.y * rect_center.y
 
	# The projected point of main camera's position onto the reflection plane
	var proj_pos := reflection_plane.project(cam_pos)
	
	# Main camera position reflected over the mirror's plane
	var mirrored_pos := cam_pos + (proj_pos - cam_pos) * 2.0
	
	# Compute mirror camera transform
	# - origin at the mirrored position
	# - looking perpedicularly into the relfection plane (this way the near clip plane will be 
	#      parallel to the reflection plane) 
	var t := Transform3D(Basis(), mirrored_pos)  
	t = t.looking_at(proj_pos, reflection_transform.basis.y.normalized()) 
	# flip horizontally
	t = t.scaled_local(Vector3(-1, 1, 1)) 
	reflect_camera.set_global_transform(t)
	
	# Compute the tilting offset for the frustum (the X and Y coordinates of the mirrored camera position
	# when expressed in the reflection plane coordinate system) 
	var offset = (cam_pos) * reflection_transform
	offset = Vector2(offset.x, offset.y)
	
	# Set mirror camera frustum
	# - size 	-> mirror's width (camera is set to KEEP_WIDTH)
	# - offset 	-> previously computed tilting offset
	# - z_near 	-> distance between the mirror camera and the reflection plane (this ensures we won't
	#               be reflecting anything behind the mirror)
	# - z_far	-> large arbitrary value (render distance limit form th mirror camera position)
	var z_near := proj_pos.distance_to(cam_pos)
	var clip_factor = (z_near - clip_bias) / z_near
	if rect.size.y * clip_factor > 0:
		reflect_camera.set_frustum(rect.size.y * clip_factor, -offset * clip_factor, z_near * clip_factor, main_cam.far)

func update_viewport() -> void:
	reflect_viewport.transparent_bg = not render_sky
	var new_size : Vector2 = Vector2(get_extents().aspect(), 1.0) * resolution
	if new_size.x > new_size.y:
		new_size = new_size / new_size.x * resolution
	
	var new_size_round = Vector2i(new_size.floor())
	if new_size_round != reflect_viewport.size:
		reflect_viewport.size = new_size

func get_extents() -> Vector2:
	if mesh:
		return Vector2(mesh.get_aabb().size.x, mesh.get_aabb().size.y)
	else:
		return Vector2()

# Scale rect2 relative to its center
static func scale_rect(rect : Rect2, scale : Vector2) -> Rect2:
	var center = rect.position + rect.size / 2.0;
	rect.position -= center
	rect.size *= scale
	rect.position *= scale
	rect.position += center
	
	return rect

# Setters 
func set_resolution(value : int) -> void:
	resolution = max(value, 1)

func set_render_sky(value : bool) -> void:
	render_sky = value
	if reflect_viewport:
		reflect_viewport.transparent_bg = not render_sky

func set_cull_mask(value : int) -> void:
	cull_mask = value
	if reflect_camera:
		reflect_camera.cull_mask = cull_mask

func set_environment(value : Environment) -> void:
	environment = value
	if reflect_camera:
		reflect_camera.environment = environment

func set_mesh_c(value : Mesh) -> void:
	mesh = value
	reflect_mesh.mesh = mesh

func set_material_override_c(value : Material) -> void:
	if material_override and material_override != value:
		ReflectMaterialManager.remove_material(material_override, self)
	 
	RenderingServer.instance_geometry_set_material_override(get_instance(), preload("discard.material").get_rid())
		
	material_override = value
	reflect_mesh.material_override = ReflectMaterialManager.add_material(value, self)

func set_surface_override_material_c(index : int, value : Material) -> void:
	var material = get_surface_override_material(index)
	if material and material != value:
		ReflectMaterialManager.remove_material(material, self)

	super.set_surface_override_material(index, value)
	reflect_mesh.set_surface_override_material(index, ReflectMaterialManager.add_material(value, self))

func set_cast_shadow_c(value : int) -> void:
	cast_shadow = value
	reflect_mesh.cast_shadow = value

func set_layers_c(value : int) -> void:
	layers = value
	reflect_mesh.layers = value
