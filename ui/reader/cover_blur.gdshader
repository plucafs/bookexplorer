shader_type canvas_item;
// Reader cover: sharp at the top, blur increasing toward the bottom (mip-LOD).

uniform float blur_start : hint_range(0.0, 1.0) = 0.15; // where the fade starts
uniform float max_lod : hint_range(0.0, 10.0) = 6.0;    // max blur at the bottom

void fragment() {
	float t = smoothstep(blur_start, 1.0, SCREEN_UV.y);
	COLOR = textureLod(TEXTURE, UV, max_lod * t);
}
