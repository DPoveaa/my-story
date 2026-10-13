shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

/// Kept for optional plugin Transvoxel debugging. Hybrid path uses terrain_hybrid.gdshader.
/// Fragment NORMAL stays view-space; world normals only via varyings / MODEL_NORMAL_MATRIX.

uniform sampler2DArray u_texture_array : source_color, filter_linear_mipmap, repeat_enable;
uniform float u_uv_scale = 0.45;
uniform int u_transition_mask;
uniform float u_weight_sharpen = 2.8;
uniform float u_facet_strength = 0.92;

varying vec4 v_indices;
varying vec4 v_weights;
varying vec3 v_world_pos;
varying vec3 v_world_normal;

vec4 decode_8bit_vec4(float v) {
	uint i = floatBitsToUint(v);
	return vec4(
		float(i & uint(0xff)),
		float((i >> uint(8)) & uint(0xff)),
		float((i >> uint(16)) & uint(0xff)),
		float((i >> uint(24)) & uint(0xff))
	);
}

float get_transvoxel_secondary_factor(int idata) {
	int transition_mask = u_transition_mask & 0xff;
	int cell_border_mask = (idata >> 0) & 63;
	int vertex_border_mask = (idata >> 8) & 63;
	int m = transition_mask & cell_border_mask;
	float t = float(m != 0);
	t *= float((vertex_border_mask & ~transition_mask) == 0);
	return t;
}

vec3 get_transvoxel_position(vec3 vertex_pos, vec4 fdata) {
	int idata = floatBitsToInt(fdata.a);
	float secondary_factor = get_transvoxel_secondary_factor(idata);
	vec3 secondary_position = fdata.xyz;
	vec3 pos = mix(vertex_pos, secondary_position, secondary_factor);
	int itransition = (idata >> 16) & 0xff;
	float transition_cull = float(itransition == 0 || (itransition & u_transition_mask) != 0);
	pos *= transition_cull;
	return pos;
}

vec3 get_triplanar_blend(vec3 world_normal) {
	vec3 blending = abs(world_normal);
	blending = pow(max(blending, vec3(0.00001)), vec3(4.0));
	float b = blending.x + blending.y + blending.z;
	return blending / vec3(b);
}

vec4 texture_array_triplanar(sampler2DArray tex, vec3 world_pos, vec3 blend, float i) {
	vec4 xaxis = texture(tex, vec3(world_pos.yz, i));
	vec4 yaxis = texture(tex, vec3(world_pos.xz, i));
	vec4 zaxis = texture(tex, vec3(world_pos.xy, i));
	return xaxis * blend.x + yaxis * blend.y + zaxis * blend.z;
}

vec4 sharpen_s4_weights(vec4 w, float sharpen) {
	w = max(w - vec4(0.10), vec4(0.0));
	w = pow(max(w, vec4(1e-5)), vec4(sharpen));
	float s = max(dot(w, vec4(1.0)), 1e-4);
	return w / s;
}

void vertex() {
	VERTEX = get_transvoxel_position(VERTEX, CUSTOM0);
	v_indices = decode_8bit_vec4(CUSTOM1.x);
	v_weights = decode_8bit_vec4(CUSTOM1.y) / 255.0;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_NORMAL_MATRIX * NORMAL));
}

void fragment() {
	vec3 world_n = normalize(v_world_normal);
	vec3 blending = get_triplanar_blend(world_n);
	vec3 p = v_world_pos * u_uv_scale;

	vec4 w = sharpen_s4_weights(v_weights, u_weight_sharpen);
	vec3 col0 = texture_array_triplanar(u_texture_array, p, blending, v_indices.x).rgb;
	vec3 col1 = texture_array_triplanar(u_texture_array, p, blending, v_indices.y).rgb;
	vec3 col2 = texture_array_triplanar(u_texture_array, p, blending, v_indices.z).rgb;
	vec3 col3 = texture_array_triplanar(u_texture_array, p, blending, v_indices.w).rgb;
	ALBEDO = col0 * w.x + col1 * w.y + col2 * w.z + col3 * w.w;

	// View-space NORMAL only — never assign world_n directly.
	vec3 smooth_n = normalize(NORMAL);
	vec3 flat_n = normalize(cross(dFdy(VERTEX), dFdx(VERTEX)));
	float upness = world_n.y;
	float facet = 1.0 - smoothstep(0.30, 0.72, abs(upness));
	if (upness < -0.08) {
		facet = max(facet, 0.92);
	}
	facet *= u_facet_strength;
	NORMAL = normalize(mix(smooth_n, flat_n, facet));

	ROUGHNESS = mix(0.92, 0.84, facet);
	METALLIC = 0.0;
	SPECULAR = mix(0.12, 0.20, facet);
}
