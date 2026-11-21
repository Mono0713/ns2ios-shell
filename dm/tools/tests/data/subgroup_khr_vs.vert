#version 450
#extension GL_KHR_shader_subgroup_ballot : require
#extension GL_KHR_shader_subgroup_arithmetic : require
#extension GL_KHR_shader_subgroup_shuffle : require
layout(location=0) in vec4 p;
layout(location=0) out vec4 o;
layout(binding=0) uniform U { uint k; float f; } u;
void main(){
  uint eq = gl_SubgroupEqMask[0];
  uint lt = gl_SubgroupLtMask.x;
  uvec4 b = subgroupBallot(p.x > 0.0);
  uint n = subgroupBallotBitCount(b);
  bool inv = subgroupInverseBallot(b);
  bool be = subgroupBallotBitExtract(b, u.k);
  uint lsb = subgroupBallotFindLSB(b);
  float s = subgroupAdd(p.y) + subgroupInclusiveMax(p.z);
  float sh = subgroupShuffle(p.w, gl_SubgroupInvocationID);
  o = vec4(float(eq + lt + n + lsb + gl_SubgroupSize), inv ? 1.0 : 0.0, be ? s : sh, 1.0);
  gl_Position = p;
}
