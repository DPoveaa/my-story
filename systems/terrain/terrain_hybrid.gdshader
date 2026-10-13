shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

/// Castle Story hybrid terrain: clean per-material albedo, correct normal spaces.
/// Walkable tops keep smooth interpolated normals; cliffs/undersides use flat face normals.
/// Godot 4 D3D12/Vulkan: screen-space derivative cross uses dFdy × dFdx (not OpenGL order).

uniform vec4 u_albedo : source_color = vec4(0.45, 0.42, 0.38, 1.0);
uniform float u_roughness = 0.9;
uniform float u_metallic = 0.0;
uniform float u_specular = 0.12;
/// 0 = always smooth, 1 = facet steep / downward faces.
uniform float u_facet_strength = 0.85;

varying vec3 v_world_normal;

void vertex() {
	// MODEL_NORMAL_MATRIX → world; do NOT write world normals into fragment NORMAL.
	v_world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	ALBEDO = u_albedo.rgb;
	ROUGHNESS = u_roughness;
	METALLIC = u_metallic;
	SPECULAR = u_specular;

	// NORMAL in fragment is view-space; keep interpolated OR replace with view-space flat.
	vec3 smooth_n = normalize(NORMAL);
	vec3 flat_n = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	float upness = normalize(v_world_normal).y;
	float facet = 1.0 - smoothstep(0.28, 0.75, abs(upness));
	if (upness < -0.05) {
		facet = max(facet, 0.90);
	}
	facet *= u_facet_strength;
	NORMAL = normalize(mix(smooth_n, flat_n, facet));
}
